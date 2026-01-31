///| Packfile parsing (deflate + delta)

///|
/// Parse a packfile into objects.
pub fn parse_packfile(data : Bytes) -> Array[PackObject] raise GitError {
  parse_packfile_with_bases(data, [])
}

///|
/// Parse a packfile with preloaded base objects (for thin packs).
pub fn parse_packfile_with_bases(
  data : Bytes,
  bases : Array[PackObject],
) -> Array[PackObject] raise GitError {
  let by_offset : Map[Int, Int] = {}
  let by_id : Map[String, PackObject] = {}
  for obj in bases {
    let id = hash_object_content(obj.obj_type, obj.data)
    by_id[id.to_hex()] = obj
  }
  parse_packfile_internal(data, by_offset, by_id)
}

///|
/// Parse a packfile and emit resolved objects (order not guaranteed).
pub fn parse_packfile_stream(
  data : Bytes,
  emit : (PackObject) -> Unit,
) -> Unit raise GitError {
  parse_packfile_stream_with_bases(data, [], emit)
}

///|
/// Parse a packfile with base objects and emit resolved objects.
pub fn parse_packfile_stream_with_bases(
  data : Bytes,
  bases : Array[PackObject],
  emit : (PackObject) -> Unit,
) -> Unit raise GitError {
  let by_offset : Map[Int, PackObject] = {}
  let by_id : Map[String, PackObject] = {}
  for obj in bases {
    let id = hash_object_content(obj.obj_type, obj.data)
    by_id[id.to_hex()] = obj
  }
  parse_packfile_stream_internal(data, by_offset, by_id, emit)
}

///|
priv enum DeltaBaseRef {
  Ofs(Int)
  Ref(String)
}

///|
priv struct PendingDelta {
  index : Int
  base : DeltaBaseRef
  delta : Bytes
}

///|
priv struct PendingDeltaStream {
  offset : Int
  base : DeltaBaseRef
  delta : Bytes
}

///|
fn parse_packfile_internal(
  data : Bytes,
  by_offset : Map[Int, Int],
  by_id : Map[String, PackObject],
) -> Array[PackObject] raise GitError {
  if data.length() < 32 {
    raise GitError::PackfileError("Packfile too short")
  }

  // Magic: "PACK"
  if not(
      data[0] == b'P' && data[1] == b'A' && data[2] == b'C' && data[3] == b'K',
    ) {
    raise GitError::PackfileError("Invalid packfile magic")
  }
  let version = read_u32_be(data, 4)
  if version != 2 {
    raise GitError::PackfileError("Unsupported packfile version: \{version}")
  }
  let count = read_u32_be(data, 8)
  let mut offset = 12
  let objects : Array[PackObject] = []
  let resolved : Array[Bool] = []
  let obj_offsets : Array[Int] = [] // Track offsets for CRC calculation
  let obj_ends : Array[Int] = [] // Track end positions for CRC calculation
  let pending : Array[PendingDelta] = []
  for _ in 0..<count {
    let obj_offset = offset
    let (type_id, size, next_offset) = decode_type_and_size_at(data, offset)
    offset = next_offset
    let (obj_type, content, after) = match type_id {
      1 | 2 | 3 | 4 => {
        let obj_type = packfile_type_to_object_type(type_id)
        let (content, after) = @zlib.zlib_decompress_at(data, offset) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if content.length() != size {
          raise GitError::PackfileError(
            "Object size mismatch: expected=\{size}, got=\{content.length()}",
          )
        }
        (obj_type, content, after)
      }
      6 => {
        let (back_offset, after_ref) = read_ofs_delta_offset(data, offset)
        let base_offset = obj_offset - back_offset
        if base_offset < 0 {
          raise GitError::PackfileError("Invalid OFS_DELTA base offset")
        }
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        // Compute CRC32 for this delta object
        let crc = crc32_range(data, obj_offset, after)
        let placeholder = PackObject::with_metadata(
          ObjectType::Blob,
          Bytes::from_array([]),
          ObjectId::zero(),
          obj_offset,
          crc,
        )
        objects.push(placeholder)
        resolved.push(false)
        obj_offsets.push(obj_offset)
        obj_ends.push(after)
        let idx = objects.length() - 1
        by_offset[obj_offset] = idx
        match by_offset.get(base_offset) {
          Some(base_index) =>
            if resolved[base_index] {
              let base = objects[base_index]
              let content = apply_delta(base.data, delta)
              let obj_id = hash_object_content(base.obj_type, content)
              let obj = PackObject::with_metadata(
                base.obj_type,
                content,
                obj_id,
                obj_offset,
                crc,
              )
              objects[idx] = obj
              resolved[idx] = true
              by_id[obj_id.to_hex()] = obj
            } else {
              pending.push({
                index: idx,
                base: DeltaBaseRef::Ofs(base_index),
                delta,
              })
            }
          None =>
            raise GitError::PackfileError("Missing base object for OFS_DELTA")
        }
        (ObjectType::Blob, Bytes::from_array([]), after)
      }
      7 => {
        let (base_id, after_ref) = read_ref_delta_id(data, offset)
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        // Compute CRC32 for this delta object
        let crc = crc32_range(data, obj_offset, after)
        let placeholder = PackObject::with_metadata(
          ObjectType::Blob,
          Bytes::from_array([]),
          ObjectId::zero(),
          obj_offset,
          crc,
        )
        objects.push(placeholder)
        resolved.push(false)
        obj_offsets.push(obj_offset)
        obj_ends.push(after)
        let idx = objects.length() - 1
        by_offset[obj_offset] = idx
        match by_id.get(base_id) {
          Some(base) => {
            let content = apply_delta(base.data, delta)
            let obj_id = hash_object_content(base.obj_type, content)
            let obj = PackObject::with_metadata(
              base.obj_type,
              content,
              obj_id,
              obj_offset,
              crc,
            )
            objects[idx] = obj
            resolved[idx] = true
            by_id[obj_id.to_hex()] = obj
          }
          None =>
            pending.push({ index: idx, base: DeltaBaseRef::Ref(base_id), delta })
        }
        (ObjectType::Blob, Bytes::from_array([]), after)
      }
      _ =>
        raise GitError::PackfileError(
          "Unknown packfile object type: \{type_id}",
        )
    }
    offset = after
    if type_id == 1 || type_id == 2 || type_id == 3 || type_id == 4 {
      // Compute CRC32 and hash for non-delta objects
      let crc = crc32_range(data, obj_offset, after)
      let obj_id = hash_object_content(obj_type, content)
      let obj = PackObject::with_metadata(
        obj_type, content, obj_id, obj_offset, crc,
      )
      objects.push(obj)
      resolved.push(true)
      obj_offsets.push(obj_offset)
      obj_ends.push(after)
      by_offset[obj_offset] = objects.length() - 1
      by_id[obj_id.to_hex()] = obj
    }
  }
  let mut progress = true
  let mut pending_list = pending
  while pending_list.length() > 0 && progress {
    progress = false
    let next_pending : Array[PendingDelta] = []
    for p in pending_list {
      match p.base {
        DeltaBaseRef::Ofs(base_index) =>
          if base_index >= 0 &&
            base_index < objects.length() &&
            resolved[base_index] {
            let base = objects[base_index]
            let content = apply_delta(base.data, p.delta)
            let obj_id = hash_object_content(base.obj_type, content)
            // Preserve offset and crc from placeholder
            let old = objects[p.index]
            let obj = PackObject::with_metadata(
              base.obj_type,
              content,
              obj_id,
              old.offset,
              old.crc32,
            )
            objects[p.index] = obj
            resolved[p.index] = true
            by_id[obj_id.to_hex()] = obj
            progress = true
          } else {
            next_pending.push(p)
          }
        DeltaBaseRef::Ref(base_id) =>
          match by_id.get(base_id) {
            Some(base) => {
              let content = apply_delta(base.data, p.delta)
              let obj_id = hash_object_content(base.obj_type, content)
              // Preserve offset and crc from placeholder
              let old = objects[p.index]
              let obj = PackObject::with_metadata(
                base.obj_type,
                content,
                obj_id,
                old.offset,
                old.crc32,
              )
              objects[p.index] = obj
              resolved[p.index] = true
              by_id[obj_id.to_hex()] = obj
              progress = true
            }
            None => next_pending.push(p)
          }
      }
    }
    pending_list = next_pending
  }
  if pending_list.length() > 0 {
    raise GitError::PackfileError("Unresolved delta objects")
  }
  let trailer_offset = data.length() - 20
  if offset != trailer_offset {
    raise GitError::PackfileError("Packfile length mismatch")
  }
  let computed = sha1_prefix(data, trailer_offset)
  let trailer = read_trailer_id(data, trailer_offset)
  if computed != trailer {
    raise GitError::HashMismatch(computed.to_hex(), trailer.to_hex())
  }
  objects
}

///|
fn parse_packfile_stream_internal(
  data : Bytes,
  by_offset : Map[Int, PackObject],
  by_id : Map[String, PackObject],
  emit : (PackObject) -> Unit,
) -> Unit raise GitError {
  if data.length() < 32 {
    raise GitError::PackfileError("Packfile too short")
  }
  if not(
      data[0] == b'P' && data[1] == b'A' && data[2] == b'C' && data[3] == b'K',
    ) {
    raise GitError::PackfileError("Invalid packfile magic")
  }
  let version = read_u32_be(data, 4)
  if version != 2 {
    raise GitError::PackfileError("Unsupported packfile version: \{version}")
  }
  let count = read_u32_be(data, 8)
  let mut offset = 12
  let pending : Array[PendingDeltaStream] = []
  for _ in 0..<count {
    let obj_offset = offset
    let (type_id, size, next_offset) = decode_type_and_size_at(data, offset)
    offset = next_offset
    match type_id {
      1 | 2 | 3 | 4 => {
        let obj_type = packfile_type_to_object_type(type_id)
        let (content, after) = @zlib.zlib_decompress_at(data, offset) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if content.length() != size {
          raise GitError::PackfileError(
            "Object size mismatch: expected=\{size}, got=\{content.length()}",
          )
        }
        let obj = PackObject::new(obj_type, content)
        by_offset[obj_offset] = obj
        let obj_id = hash_object_content(obj.obj_type, obj.data)
        by_id[obj_id.to_hex()] = obj
        emit(obj)
        offset = after
      }
      6 => {
        let (back_offset, after_ref) = read_ofs_delta_offset(data, offset)
        let base_offset = obj_offset - back_offset
        if base_offset < 0 {
          raise GitError::PackfileError("Invalid OFS_DELTA base offset")
        }
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        match by_offset.get(base_offset) {
          Some(base) => {
            let content = apply_delta(base.data, delta)
            let obj = PackObject::new(base.obj_type, content)
            by_offset[obj_offset] = obj
            let obj_id = hash_object_content(obj.obj_type, obj.data)
            by_id[obj_id.to_hex()] = obj
            emit(obj)
          }
          None =>
            pending.push({
              offset: obj_offset,
              base: DeltaBaseRef::Ofs(base_offset),
              delta,
            })
        }
        offset = after
      }
      7 => {
        let (base_id, after_ref) = read_ref_delta_id(data, offset)
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        match by_id.get(base_id) {
          Some(base) => {
            let content = apply_delta(base.data, delta)
            let obj = PackObject::new(base.obj_type, content)
            by_offset[obj_offset] = obj
            let obj_id = hash_object_content(obj.obj_type, obj.data)
            by_id[obj_id.to_hex()] = obj
            emit(obj)
          }
          None =>
            pending.push({
              offset: obj_offset,
              base: DeltaBaseRef::Ref(base_id),
              delta,
            })
        }
        offset = after
      }
      _ =>
        raise GitError::PackfileError(
          "Unknown packfile object type: \{type_id}",
        )
    }
  }
  let mut pending_list = pending
  while pending_list.length() > 0 {
    let mut progress = false
    let next_pending : Array[PendingDeltaStream] = []
    for p in pending_list {
      match p.base {
        Ofs(base_offset) =>
          match by_offset.get(base_offset) {
            Some(base) => {
              let content = apply_delta(base.data, p.delta)
              let obj = PackObject::new(base.obj_type, content)
              by_offset[p.offset] = obj
              let obj_id = hash_object_content(obj.obj_type, obj.data)
              by_id[obj_id.to_hex()] = obj
              emit(obj)
              progress = true
            }
            None => next_pending.push(p)
          }
        Ref(base_id) =>
          match by_id.get(base_id) {
            Some(base) => {
              let content = apply_delta(base.data, p.delta)
              let obj = PackObject::new(base.obj_type, content)
              by_offset[p.offset] = obj
              let obj_id = hash_object_content(obj.obj_type, obj.data)
              by_id[obj_id.to_hex()] = obj
              emit(obj)
              progress = true
            }
            None => next_pending.push(p)
          }
      }
    }
    if not(progress) {
      break
    }
    pending_list = next_pending
  }
  if pending_list.length() > 0 {
    raise GitError::PackfileError("Unresolved delta objects")
  }
  let trailer_offset = data.length() - 20
  if offset != trailer_offset {
    raise GitError::PackfileError("Packfile length mismatch")
  }
  let computed = sha1_prefix(data, trailer_offset)
  let trailer = read_trailer_id(data, trailer_offset)
  if computed != trailer {
    raise GitError::HashMismatch(computed.to_hex(), trailer.to_hex())
  }
}

///|
/// Decode packfile object header and return (type_id, size, next_offset).
pub fn decode_type_and_size_at(
  data : Bytes,
  start : Int,
) -> (Int, Int, Int) raise GitError {
  if start < 0 || start >= data.length() {
    raise GitError::PackfileError("Unexpected end of packfile header")
  }
  let first = data[start].to_int()
  let mut size = first & 0x0f
  let type_id = (first >> 4) & 0x07
  let mut shift = 4
  let mut offset = start + 1
  let mut has_more = (first & 0x80) != 0
  while has_more {
    if offset >= data.length() {
      raise GitError::PackfileError("Unexpected end of packfile size")
    }
    let b = data[offset].to_int()
    offset += 1
    size = size | ((b & 0x7f) << shift)
    shift += 7
    has_more = (b & 0x80) != 0
  }
  (type_id, size, offset)
}

///|
/// Convert packfile type id to ObjectType.
pub fn packfile_type_to_object_type(type_id : Int) -> ObjectType raise GitError {
  match type_id {
    1 => ObjectType::Commit
    2 => ObjectType::Tree
    3 => ObjectType::Blob
    4 => ObjectType::Tag
    _ =>
      raise GitError::PackfileError("Unknown packfile object type: \{type_id}")
  }
}

///|
pub fn read_ofs_delta_offset(
  data : Bytes,
  start : Int,
) -> (Int, Int) raise GitError {
  if start >= data.length() {
    raise GitError::PackfileError("Unexpected end of packfile delta")
  }
  let mut offset = start
  let mut c = data[offset].to_int()
  offset += 1
  let mut val = c & 0x7f
  while (c & 0x80) != 0 {
    if offset >= data.length() {
      raise GitError::PackfileError("Unexpected end of packfile delta")
    }
    c = data[offset].to_int()
    offset += 1
    val = (val + 1) << 7
    val = val | (c & 0x7f)
  }
  (val, offset)
}

///|
pub fn read_ref_delta_id(
  data : Bytes,
  start : Int,
) -> (String, Int) raise GitError {
  if start + 20 > data.length() {
    raise GitError::PackfileError("Unexpected end of packfile delta")
  }
  let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i = 0; i < 20; i = i + 1 {
    bytes[i] = data[start + i]
  }
  let id = ObjectId::new(bytes)
  (id.to_hex(), start + 20)
}

///|
pub fn apply_delta(base : Bytes, delta : Bytes) -> Bytes raise GitError {
  let mut offset = 0
  let (base_size, off1) = read_delta_size(delta, offset)
  offset = off1
  if base_size != base.length() {
    raise GitError::PackfileError("Delta base size mismatch")
  }
  let (result_size, off2) = read_delta_size(delta, offset)
  offset = off2
  let out : Array[Byte] = []
  while offset < delta.length() {
    let opcode = delta[offset].to_int()
    offset += 1
    if (opcode & 0x80) != 0 {
      let mut cp_off = 0
      let mut cp_size = 0
      if (opcode & 0x01) != 0 {
        cp_off = cp_off | delta[offset].to_int()
        offset += 1
      }
      if (opcode & 0x02) != 0 {
        cp_off = cp_off | (delta[offset].to_int() << 8)
        offset += 1
      }
      if (opcode & 0x04) != 0 {
        cp_off = cp_off | (delta[offset].to_int() << 16)
        offset += 1
      }
      if (opcode & 0x08) != 0 {
        cp_off = cp_off | (delta[offset].to_int() << 24)
        offset += 1
      }
      if (opcode & 0x10) != 0 {
        cp_size = cp_size | delta[offset].to_int()
        offset += 1
      }
      if (opcode & 0x20) != 0 {
        cp_size = cp_size | (delta[offset].to_int() << 8)
        offset += 1
      }
      if (opcode & 0x40) != 0 {
        cp_size = cp_size | (delta[offset].to_int() << 16)
        offset += 1
      }
      if cp_size == 0 {
        cp_size = 0x10000
      }
      if cp_off < 0 || cp_off + cp_size > base.length() {
        raise GitError::PackfileError("Delta copy out of range")
      }
      for i = 0; i < cp_size; i = i + 1 {
        out.push(base[cp_off + i])
      }
    } else {
      let literal_len = opcode & 0x7f
      if literal_len == 0 {
        raise GitError::PackfileError("Invalid delta opcode")
      }
      if offset + literal_len > delta.length() {
        raise GitError::PackfileError("Delta literal out of range")
      }
      for i = 0; i < literal_len; i = i + 1 {
        out.push(delta[offset + i])
      }
      offset += literal_len
    }
  }
  if out.length() != result_size {
    raise GitError::PackfileError("Delta result size mismatch")
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn read_delta_size(data : Bytes, start : Int) -> (Int, Int) raise GitError {
  let mut offset = start
  let mut size = 0
  let mut shift = 0
  while true {
    if offset >= data.length() {
      raise GitError::PackfileError("Unexpected end of delta data")
    }
    let b = data[offset].to_int()
    offset += 1
    size = size | ((b & 0x7f) << shift)
    if (b & 0x80) == 0 {
      break
    }
    shift = shift + 7
  }
  (size, offset)
}

///|
fn read_u32_be(data : Bytes, start : Int) -> Int raise GitError {
  if start < 0 || start + 4 > data.length() {
    raise GitError::PackfileError("Unexpected end of packfile header")
  }
  (data[start].to_int() << 24) |
  (data[start + 1].to_int() << 16) |
  (data[start + 2].to_int() << 8) |
  data[start + 3].to_int()
}

///|
fn read_trailer_id(data : Bytes, start : Int) -> ObjectId {
  let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i = 0; i < 20; i = i + 1 {
    bytes[i] = data[start + i]
  }
  ObjectId::new(bytes)
}
