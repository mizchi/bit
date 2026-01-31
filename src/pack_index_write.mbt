///| Pack index writer (v2)

///|
priv struct PackIndexEntry {
  id : ObjectId
  offset : Int
  crc : UInt
}

///|
/// Build a pack index (v2) from packfile bytes.
pub fn build_pack_index(pack : Bytes) -> Bytes raise GitError {
  let objects = parse_packfile(pack)
  build_pack_index_from_objects(pack, objects)
}

///|
/// Build a pack index (v2) from packfile bytes and parsed objects.
/// Uses cached metadata (id, offset, crc32) from PackObject when available.
pub fn build_pack_index_from_objects(
  pack : Bytes,
  objects : Array[PackObject],
) -> Bytes raise GitError {
  let entries : Array[PackIndexEntry] = []
  for obj in objects {
    // Use cached metadata if available (offset >= 0 means parsed from pack)
    if obj.offset >= 0 {
      entries.push({ id: obj.id, offset: obj.offset, crc: obj.crc32 })
    } else {
      // Fallback: compute values (shouldn't happen for parsed pack objects)
      let id = hash_object_content(obj.obj_type, obj.data)
      entries.push({ id, offset: 0, crc: 0U })
    }
  }
  entries.sort_by(fn(a, b) { compare_object_id(a.id, b.id) })
  let counts : Array[Int] = Array::make(256, 0)
  for entry in entries {
    let first = entry.id.bytes[0].to_int()
    counts[first] = counts[first] + 1
  }
  let out : Array[Byte] = []
  // Index header: magic + version
  out.push(b'\xff')
  out.push(b't')
  out.push(b'O')
  out.push(b'c')
  push_u32_be_from_int(out, 2)

  // Fanout table
  let mut sum = 0
  for i in 0..<256 {
    sum = sum + counts[i]
    push_u32_be_from_int(out, sum)
  }

  // Object name table
  for entry in entries {
    for b in entry.id.bytes {
      out.push(b)
    }
  }

  // CRC32 table
  for entry in entries {
    push_u32_be_from_uint(out, entry.crc)
  }

  // Offsets table (no large offsets due to Int range)
  for entry in entries {
    if entry.offset < 0 {
      raise GitError::PackfileError("Negative pack offset")
    }
    push_u32_be_from_int(out, entry.offset)
  }

  // Packfile checksum (trailer)
  if pack.length() < 20 {
    raise GitError::PackfileError("Packfile too short")
  }
  let trailer_offset = pack.length() - 20
  let pack_checksum = read_trailer_id(pack, trailer_offset)
  for b in pack_checksum.bytes {
    out.push(b)
  }

  // Index checksum
  let before_checksum = bytes_from_array(out)
  let index_checksum = sha1(before_checksum)
  for b in index_checksum.bytes {
    out.push(b)
  }
  bytes_from_array(out)
}

///|
/// Write a pack index to the filesystem.
pub fn write_pack_index(
  fs : &FileSystem,
  idx_path : String,
  pack : Bytes,
) -> Unit raise GitError {
  let idx = build_pack_index(pack)
  fs.write_file(idx_path, idx)
}

///|
/// Write a pack index using pre-parsed objects.
pub fn write_pack_index_from_objects(
  fs : &FileSystem,
  idx_path : String,
  pack : Bytes,
  objects : Array[PackObject],
) -> Unit raise GitError {
  let idx = build_pack_index_from_objects(pack, objects)
  fs.write_file(idx_path, idx)
}

///|
/// Write a pack index using pre-parsed objects with specific version.
pub fn write_pack_index_from_objects_versioned(
  fs : &FileSystem,
  idx_path : String,
  pack : Bytes,
  objects : Array[PackObject],
  version : Int,
) -> Unit raise GitError {
  let idx = if version == 1 {
    build_pack_index_v1_from_objects(pack, objects)
  } else {
    build_pack_index_from_objects(pack, objects)
  }
  fs.write_file(idx_path, idx)
}

///|
/// Build a pack index (v1) from packfile bytes and parsed objects.
fn build_pack_index_v1_from_objects(
  pack : Bytes,
  objects : Array[PackObject],
) -> Bytes raise GitError {
  let entries : Array[PackIndexEntry] = []
  for obj in objects {
    if obj.offset >= 0 {
      entries.push({ id: obj.id, offset: obj.offset, crc: obj.crc32 })
    } else {
      let id = hash_object_content(obj.obj_type, obj.data)
      entries.push({ id, offset: 0, crc: 0U })
    }
  }
  entries.sort_by(fn(a, b) { compare_object_id(a.id, b.id) })

  // Build fanout table (counts per first byte)
  let counts : Array[Int] = Array::make(256, 0)
  for entry in entries {
    let first = entry.id.bytes[0].to_int()
    counts[first] = counts[first] + 1
  }
  let out : Array[Byte] = []

  // v1 format: no header, starts directly with fanout
  // Fanout table (cumulative counts)
  let mut sum = 0
  for i in 0..<256 {
    sum = sum + counts[i]
    push_u32_be_from_int(out, sum)
  }

  // v1 entries: each entry is offset(4) + sha1(20) = 24 bytes
  for entry in entries {
    if entry.offset < 0 {
      raise GitError::PackfileError("Negative pack offset")
    }
    push_u32_be_from_int(out, entry.offset)
    for b in entry.id.bytes {
      out.push(b)
    }
  }

  // Packfile checksum (trailer)
  if pack.length() < 20 {
    raise GitError::PackfileError("Packfile too short")
  }
  let trailer_offset = pack.length() - 20
  let pack_checksum = read_trailer_id(pack, trailer_offset)
  for b in pack_checksum.bytes {
    out.push(b)
  }
  bytes_from_array(out)
}

///|
fn scan_pack_entry_offsets(
  data : Bytes,
) -> (Array[Int], Array[Int]) raise GitError {
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
  if count < 0 {
    raise GitError::PackfileError("Packfile object count out of range")
  }
  let mut offset = 12
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  for _ in 0..<count {
    let start = offset
    let (type_id, size, next_offset) = decode_type_and_size_at(data, offset)
    offset = next_offset
    let after = match type_id {
      1 | 2 | 3 | 4 => {
        let (content, after) = @zlib.zlib_decompress_at(data, offset) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if content.length() != size {
          raise GitError::PackfileError(
            "Object size mismatch: expected=\{size}, got=\{content.length()}",
          )
        }
        after
      }
      6 => {
        let (_, after_ref) = read_ofs_delta_offset(data, offset)
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        after
      }
      7 => {
        let (_, after_ref) = read_ref_delta_id(data, offset)
        let (delta, after) = @zlib.zlib_decompress_at(data, after_ref) catch {
          e => raise GitError::PackfileError("Zlib error: \{e}")
        }
        if delta.length() != size {
          raise GitError::PackfileError(
            "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
          )
        }
        after
      }
      _ =>
        raise GitError::PackfileError(
          "Unknown packfile object type: \{type_id}",
        )
    }
    offset = after
    starts.push(start)
    ends.push(after)
  }
  let trailer_offset = data.length() - 20
  if offset != trailer_offset {
    raise GitError::PackfileError("Packfile length mismatch")
  }
  let pack_bytes = Bytes::from_array(
    FixedArray::makei(trailer_offset, fn(i) { data[i] }),
  )
  let computed = sha1(pack_bytes)
  let trailer = read_trailer_id(data, trailer_offset)
  if computed != trailer {
    raise GitError::HashMismatch(computed.to_hex(), trailer.to_hex())
  }
  (starts, ends)
}

///|
fn compare_object_id(a : ObjectId, b : ObjectId) -> Int {
  for i in 0..<20 {
    let av = a.bytes[i].to_int()
    let bv = b.bytes[i].to_int()
    if av != bv {
      return av - bv
    }
  }
  0
}

///|
pub fn crc32_range(data : Bytes, start : Int, end : Int) -> UInt raise GitError {
  if start < 0 || end < start || end > data.length() {
    raise GitError::PackfileError("Invalid CRC range")
  }
  let slice = Bytes::from_array(
    FixedArray::makei(end - start, fn(i) { data[start + i] }),
  )
  @zlib.crc32(slice)
}

///|
fn bytes_from_array(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] }))
}

///|
fn push_u32_be_from_int(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 24) & 0xff).to_byte())
  out.push(((value >> 16) & 0xff).to_byte())
  out.push(((value >> 8) & 0xff).to_byte())
  out.push((value & 0xff).to_byte())
}

///|
fn push_u32_be_from_uint(out : Array[Byte], value : UInt) -> Unit {
  let mask = Int::reinterpret_as_uint(0xff)
  let b0 = (value >> 24) & mask
  let b1 = (value >> 16) & mask
  let b2 = (value >> 8) & mask
  let b3 = value & mask
  out.push(UInt::reinterpret_as_int(b0).to_byte())
  out.push(UInt::reinterpret_as_int(b1).to_byte())
  out.push(UInt::reinterpret_as_int(b2).to_byte())
  out.push(UInt::reinterpret_as_int(b3).to_byte())
}
