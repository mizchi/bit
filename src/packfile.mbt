///| Git packfile generation

///|
/// Helper to convert Array[Byte] to Bytes
fn pack_array_to_bytes(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] }))
}

///|
/// A Git object ready for packing
pub struct PackObject {
  obj_type : ObjectType
  data : Bytes // Uncompressed object content (without header)
}

///|
/// Delta encoding mode for packfile generation
pub(all) enum PackDeltaMode {
  NoDelta
  RefDelta
  OfsDelta
}

///|
pub fn PackObject::new(obj_type : ObjectType, data : Bytes) -> PackObject {
  { obj_type, data }
}

///|
fn type_and_size_len(size : Int) -> Int {
  let mut remaining = size >> 4
  let mut len = 1
  while remaining > 0 {
    len += 1
    remaining = remaining >> 7
  }
  len
}

///|
fn ofs_delta_len(back_offset : Int) -> Int {
  let mut count = 1
  let mut val = back_offset
  while val > 0x7f {
    val = (val >> 7) - 1
    count += 1
  }
  count
}

///|
fn encode_ofs_delta_offset(back_offset : Int, result : Array[Byte]) -> Unit {
  let parts : Array[Int] = []
  let mut val = back_offset
  parts.push(val & 0x7f)
  while val > 0x7f {
    val = (val >> 7) - 1
    parts.push(val & 0x7f)
  }
  for i in 0..<parts.length() {
    let idx = parts.length() - 1 - i
    let mut b = parts[idx]
    if i < parts.length() - 1 {
      b = b | 0x80
    }
    result.push(b.to_byte())
  }
}

///|
fn encode_delta_size(value : Int, out : Array[Byte]) -> Unit {
  let mut v = value
  while true {
    let b = v & 0x7f
    v = v >> 7
    if v == 0 {
      out.push(b.to_byte())
      break
    } else {
      out.push((b | 0x80).to_byte())
    }
  }
}

///|
fn encode_delta_insert(
  data : Bytes,
  start : Int,
  len : Int,
  out : Array[Byte],
) -> Unit {
  let mut offset = start
  let mut remaining = len
  while remaining > 0 {
    let chunk = if remaining > 0x7f { 0x7f } else { remaining }
    out.push(chunk.to_byte())
    for i = 0; i < chunk; i = i + 1 {
      out.push(data[offset + i])
    }
    offset = offset + chunk
    remaining = remaining - chunk
  }
}

///|
fn encode_delta_copy_single(
  offset : Int,
  size : Int,
  out : Array[Byte],
) -> Unit {
  let mut op = 0x80
  let buf : Array[Byte] = []
  if (offset & 0xff) != 0 {
    op = op | 0x01
    buf.push((offset & 0xff).to_byte())
  }
  if ((offset >> 8) & 0xff) != 0 {
    op = op | 0x02
    buf.push(((offset >> 8) & 0xff).to_byte())
  }
  if ((offset >> 16) & 0xff) != 0 {
    op = op | 0x04
    buf.push(((offset >> 16) & 0xff).to_byte())
  }
  if ((offset >> 24) & 0xff) != 0 {
    op = op | 0x08
    buf.push(((offset >> 24) & 0xff).to_byte())
  }
  if (size & 0xff) != 0 {
    op = op | 0x10
    buf.push((size & 0xff).to_byte())
  }
  if ((size >> 8) & 0xff) != 0 {
    op = op | 0x20
    buf.push(((size >> 8) & 0xff).to_byte())
  }
  if ((size >> 16) & 0xff) != 0 {
    op = op | 0x40
    buf.push(((size >> 16) & 0xff).to_byte())
  }
  out.push(op.to_byte())
  for b in buf {
    out.push(b)
  }
}

///|
fn encode_delta_copy(offset : Int, size : Int, out : Array[Byte]) -> Unit {
  let max_chunk = 0xffffff
  let mut remaining = size
  let mut off = offset
  while remaining > 0 {
    let chunk = if remaining > max_chunk { max_chunk } else { remaining }
    encode_delta_copy_single(off, chunk, out)
    off = off + chunk
    remaining = remaining - chunk
  }
}

///|
let delta_block_size : Int = 32

///|
fn byte_to_uint(b : Byte) -> UInt {
  Int::reinterpret_as_uint(b.to_int())
}

///|
fn uint_from_int(v : Int) -> UInt {
  Int::reinterpret_as_uint(v)
}

///|
fn rolling_hash_init(data : Bytes, start : Int, len : Int) -> UInt {
  let base = uint_from_int(257)
  let mut h = uint_from_int(0)
  for i = 0; i < len; i = i + 1 {
    h = h * base + byte_to_uint(data[start + i])
  }
  h
}

///|
fn rolling_hash_base_pow(len : Int) -> UInt {
  let base = uint_from_int(257)
  let mut pow = uint_from_int(1)
  for _ in 1..<len {
    pow = pow * base
  }
  pow
}

///|
fn rolling_hash_next(
  hash : UInt,
  base_pow : UInt,
  out_b : Byte,
  in_b : Byte,
) -> UInt {
  let base = uint_from_int(257)
  let removed = byte_to_uint(out_b) * base_pow
  let h1 = hash - removed
  h1 * base + byte_to_uint(in_b)
}

///|
fn build_block_index(
  base : Bytes,
  block_size : Int,
) -> (Map[UInt, Array[Int]], UInt) {
  let base_pow = rolling_hash_base_pow(block_size)
  let index : Map[UInt, Array[Int]] = {}
  if base.length() < block_size {
    return (index, base_pow)
  }
  let mut h = rolling_hash_init(base, 0, block_size)
  let last = base.length() - block_size
  for i = 0; i <= last; i = i + 1 {
    match index.get(h) {
      Some(arr) => arr.push(i)
      None => {
        let arr : Array[Int] = [i]
        index[h] = arr
      }
    }
    if i < last {
      h = rolling_hash_next(h, base_pow, base[i], base[i + block_size])
    }
  }
  (index, base_pow)
}

///|
fn find_best_match(
  base : Bytes,
  target : Bytes,
  target_pos : Int,
  block_size : Int,
  candidates : Array[Int],
) -> (Int, Int)? {
  let mut best_len = 0
  let mut best_off = 0
  let mut checked = 0
  for off in candidates {
    if off + block_size > base.length() {
      continue
    }
    let mut ok = true
    for i = 0; i < block_size; i = i + 1 {
      if base[off + i] != target[target_pos + i] {
        ok = false
        break
      }
    }
    if ok {
      let mut len = block_size
      while target_pos + len < target.length() &&
            off + len < base.length() &&
            base[off + len] == target[target_pos + len] {
        len += 1
      }
      if len > best_len {
        best_len = len
        best_off = off
      }
    }
    checked += 1
    if checked > 64 {
      break
    }
  }
  if best_len >= block_size {
    Some((best_off, best_len))
  } else {
    None
  }
}

///|
fn build_delta(base : Bytes, target : Bytes) -> Bytes {
  let base_len = base.length()
  let target_len = target.length()
  let out : Array[Byte] = []
  encode_delta_size(base_len, out)
  encode_delta_size(target_len, out)
  if target_len == 0 {
    return Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
  }
  if base_len < delta_block_size || target_len < delta_block_size {
    encode_delta_insert(target, 0, target_len, out)
    return Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
  }
  let (index, base_pow) = build_block_index(base, delta_block_size)
  let mut t = 0
  let mut literal_start = 0
  let mut literal_len = 0
  let last = target_len - delta_block_size
  let mut th = rolling_hash_init(target, 0, delta_block_size)
  while t <= last {
    let matched = match index.get(th) {
      None => None
      Some(cands) => find_best_match(base, target, t, delta_block_size, cands)
    }
    match matched {
      Some((base_off, match_len)) => {
        if literal_len > 0 {
          encode_delta_insert(target, literal_start, literal_len, out)
          literal_len = 0
        }
        encode_delta_copy(base_off, match_len, out)
        t = t + match_len
        literal_start = t
        if t <= last {
          th = rolling_hash_init(target, t, delta_block_size)
        }
      }
      None => {
        if literal_len == 0 {
          literal_start = t
        }
        literal_len += 1
        if t < last {
          th = rolling_hash_next(
            th,
            base_pow,
            target[t],
            target[t + delta_block_size],
          )
        }
        t = t + 1
      }
    }
  }
  if t < target_len {
    let tail_len = target_len - t
    if literal_len == 0 {
      literal_start = t
      literal_len = tail_len
    } else if literal_start + literal_len == t {
      literal_len = literal_len + tail_len
    } else {
      encode_delta_insert(target, literal_start, literal_len, out)
      literal_start = t
      literal_len = tail_len
    }
  }
  if literal_len > 0 {
    encode_delta_insert(target, literal_start, literal_len, out)
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn pack_object_with_delta(
  obj : PackObject,
  base : (Int, PackObject)?,
  obj_offset : Int,
  result : Array[Byte],
  delta_mode : PackDeltaMode,
) -> (Int, Bool) {
  let obj_type = obj.obj_type.to_packfile_type()
  let data = obj.data
  let compressed = @zlib.zlib_compress(data)
  let normal_len = type_and_size_len(data.length()) + compressed.length()
  match delta_mode {
    PackDeltaMode::NoDelta => {
      encode_type_and_size(obj_type, data.length(), result)
      for b in compressed {
        result.push(b)
      }
      return (normal_len, false)
    }
    _ => ()
  }
  match base {
    None => {
      encode_type_and_size(obj_type, data.length(), result)
      for b in compressed {
        result.push(b)
      }
      (normal_len, false)
    }
    Some((base_offset, base_obj)) => {
      if base_offset < obj_offset && base_obj.obj_type == obj.obj_type {
        let delta = build_delta(base_obj.data, data)
        let compressed_delta = @zlib.zlib_compress(delta)
        match delta_mode {
          PackDeltaMode::OfsDelta => {
            let back_offset = obj_offset - base_offset
            let delta_len = type_and_size_len(delta.length()) +
              ofs_delta_len(back_offset) +
              compressed_delta.length()
            if delta_len < normal_len {
              encode_type_and_size(6, delta.length(), result)
              encode_ofs_delta_offset(back_offset, result)
              for b in compressed_delta {
                result.push(b)
              }
              return (delta_len, true)
            }
          }
          PackDeltaMode::RefDelta => {
            let base_id = hash_object_content(base_obj.obj_type, base_obj.data)
            let delta_len = type_and_size_len(delta.length()) +
              base_id.bytes.length() +
              compressed_delta.length()
            if delta_len < normal_len {
              encode_type_and_size(7, delta.length(), result)
              for b in base_id.bytes {
                result.push(b)
              }
              for b in compressed_delta {
                result.push(b)
              }
              return (delta_len, true)
            }
          }
          PackDeltaMode::NoDelta => ()
        }
      }
      encode_type_and_size(obj_type, data.length(), result)
      for b in compressed {
        result.push(b)
      }
      (normal_len, false)
    }
  }
}

///|
/// Create a packfile from a list of objects
/// Format:
///   [PACK]           4 bytes magic
///   [version]        4 bytes (big-endian, always 2)
///   [object count]   4 bytes (big-endian)
///   [...objects...]  variable
///   [SHA-1 trailer]  20 bytes
pub fn create_packfile(objects : Array[PackObject]) -> Bytes {
  create_packfile_with_delta(objects, PackDeltaMode::OfsDelta)
}

///|
/// Create a packfile from a list of objects with a chosen delta mode
pub fn create_packfile_with_delta(
  objects : Array[PackObject],
  delta_mode : PackDeltaMode,
) -> Bytes {
  let (pack, _) = create_packfile_with_delta_stats(objects, delta_mode)
  pack
}

///|
/// Create a packfile with delta statistics (delta object count)
pub fn create_packfile_with_delta_stats(
  objects : Array[PackObject],
  delta_mode : PackDeltaMode,
) -> (Bytes, Int) {
  let result : Array[Byte] = []

  // Magic: "PACK"
  result.push(b'P')
  result.push(b'A')
  result.push(b'C')
  result.push(b'K')

  // Version: 2 (big-endian)
  result.push(b'\x00')
  result.push(b'\x00')
  result.push(b'\x00')
  result.push(b'\x02')

  // Object count (big-endian)
  let count = objects.length()
  result.push(((count >> 24) & 0xff).to_byte())
  result.push(((count >> 16) & 0xff).to_byte())
  result.push(((count >> 8) & 0xff).to_byte())
  result.push((count & 0xff).to_byte())

  // Pack each object (delta against the last object of the same type)
  let mut offset = 12
  let last_by_type : Map[Int, (Int, PackObject)] = {}
  let mut delta_count = 0
  for obj in objects {
    let obj_offset = offset
    let key = obj.obj_type.to_packfile_type()
    let base = last_by_type.get(key)
    let (written, used_delta) = pack_object_with_delta(
      obj, base, obj_offset, result, delta_mode,
    )
    offset = offset + written
    if used_delta {
      delta_count = delta_count + 1
    }
    last_by_type[key] = (obj_offset, obj)
  }

  // Compute SHA-1 of everything so far
  let trailer = sha1_array_prefix(result, result.length())

  // Append trailer
  for b in trailer.bytes {
    result.push(b)
  }
  (pack_array_to_bytes(result), delta_count)
}

///|
/// Encode type and size in Git's variable-length format
pub fn encode_type_and_size(
  obj_type : Int,
  size : Int,
  result : Array[Byte],
) -> Unit {
  // First byte: MSB | type(3) | size(4)
  let mut remaining = size >> 4
  let first_byte = if remaining > 0 {
    0x80 | (obj_type << 4) | (size & 0x0f)
  } else {
    (obj_type << 4) | (size & 0x0f)
  }
  result.push(first_byte.to_byte())

  // Continue bytes: MSB | size(7)
  while remaining > 0 {
    let next_remaining = remaining >> 7
    let byte_val = if next_remaining > 0 {
      0x80 | (remaining & 0x7f)
    } else {
      remaining & 0x7f
    }
    result.push(byte_val.to_byte())
    remaining = next_remaining
  }
}

///|
/// Create a packfile containing a single blob
pub fn create_blob_packfile(content : Bytes) -> Bytes {
  let obj = PackObject::new(ObjectType::Blob, content)
  create_packfile([obj])
}

///|
/// Create a packfile with blob, tree, and commit
pub fn create_commit_packfile(
  blob_content : Bytes,
  filename : String,
  commit : Commit,
) -> (ObjectId, Bytes) {
  // Create blob
  let (blob_id, _) = create_blob(blob_content)

  // Create tree with single entry
  let entry = TreeEntry::new("100644", filename, blob_id)
  let (tree_id, _) = create_tree([entry])

  // Update commit with correct tree
  let final_commit = Commit::new(
    tree_id,
    commit.parents,
    commit.author,
    commit.author_time,
    commit.author_tz,
    commit.committer,
    commit.commit_time,
    commit.committer_tz,
    commit.message,
  )
  let (commit_id, _) = create_commit(final_commit)

  // Build pack objects (raw content, not git object format)
  let pack_objects = [
    PackObject::new(ObjectType::Blob, blob_content),
    PackObject::new(ObjectType::Tree, build_tree_content([entry])),
    PackObject::new(ObjectType::Commit, build_commit_content(final_commit)),
  ]
  let packfile = create_packfile(pack_objects)
  (commit_id, packfile)
}

///|
/// Build raw tree content (without "tree {size}\0" header)
fn build_tree_content(entries : Array[TreeEntry]) -> Bytes {
  let content : Array[Byte] = []
  for entry in entries {
    for c in entry.mode {
      content.push(c.to_int().to_byte())
    }
    content.push(b' ')
    for c in entry.name {
      content.push(c.to_int().to_byte())
    }
    content.push(b'\x00')
    for b in entry.id.bytes {
      content.push(b)
    }
  }
  pack_array_to_bytes(content)
}

///|
/// Build raw commit content (without "commit {size}\0" header)
fn build_commit_content(commit : Commit) -> Bytes {
  let content = StringBuilder::new()
  content.write_string("tree ")
  content.write_string(commit.tree.to_hex())
  content.write_char('\n')
  for parent in commit.parents {
    content.write_string("parent ")
    content.write_string(parent.to_hex())
    content.write_char('\n')
  }
  content.write_string("author ")
  content.write_string(commit.author)
  content.write_string(" ")
  content.write_string(commit.author_time.to_string())
  content.write_string(" ")
  content.write_string(commit.author_tz)
  content.write_char('\n')
  content.write_string("committer ")
  content.write_string(commit.committer)
  content.write_string(" ")
  content.write_string(commit.commit_time.to_string())
  content.write_string(" ")
  content.write_string(commit.committer_tz)
  content.write_char('\n')
  content.write_char('\n')
  content.write_string(commit.message)
  let str = content.to_string()
  let bytes : Array[Byte] = []
  for c in str {
    bytes.push(c.to_int().to_byte())
  }
  pack_array_to_bytes(bytes)
}
