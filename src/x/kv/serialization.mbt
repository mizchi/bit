///| Serialization for hot/cold storage transfer

///|

///| Hot layer: In-memory or Durable Objects (fast, limited capacity)

///| Cold layer: R2 or NativeFS (slow, unlimited capacity)

///|
/// Serialized snapshot for cold storage
pub(all) struct SerializedSnapshot {
  version : Int // format version
  node_id : String
  head : Bytes // 20 bytes SHA1
  clock : Array[(String, Int64)] // vector clock entries
  objects : Array[SerializedObject]
}

///|
/// Serialized git object
pub(all) struct SerializedObject {
  id : Bytes // 20 bytes SHA1
  obj_type : Int // 1=commit, 2=tree, 3=blob, 4=tag
  data : Bytes
}

///|
/// Serialize ObjectId to bytes - now uses direct byte access
fn object_id_to_bytes(id : @git.ObjectId) -> Bytes {
  id.to_bytes()
}

///|
/// Deserialize bytes to ObjectId - now uses direct byte access
fn _bytes_to_object_id(bytes : Bytes, offset : Int) -> @git.ObjectId {
  @git.ObjectId::from_bytes_at(bytes, offset)
}

///|
fn object_type_to_int(t : @git.ObjectType) -> Int {
  match t {
    Commit => 1
    Tree => 2
    Blob => 3
    Tag => 4
  }
}

///|
fn _int_to_object_type(n : Int) -> @git.ObjectType {
  match n {
    1 => @git.ObjectType::Commit
    2 => @git.ObjectType::Tree
    4 => @git.ObjectType::Tag
    _ => @git.ObjectType::Blob
  }
}

///|
/// Create a serialized snapshot from Kv state
pub fn Kv::serialize_snapshot(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
) -> SerializedSnapshot {
  // Collect clock entries
  let clock_entries : Array[(String, Int64)] = []
  for entry in self.clock.clocks {
    clock_entries.push((entry.0, entry.1))
  }
  // Collect reachable objects
  let objects : Array[SerializedObject] = []
  if self.head != @git.ObjectId::zero() {
    let db = self.bitfs.get_db(backing_fs) catch {
      _ => return make_empty_snapshot(self)
    }
    collect_objects_for_serialization(db, backing_fs, self.head, objects, {})
  }
  {
    version: 1,
    node_id: self.node_id.id,
    head: object_id_to_bytes(self.head),
    clock: clock_entries,
    objects,
  }
}

///|
fn make_empty_snapshot(db : Kv) -> SerializedSnapshot {
  let clock_entries : Array[(String, Int64)] = []
  for entry in db.clock.clocks {
    clock_entries.push((entry.0, entry.1))
  }
  {
    version: 1,
    node_id: db.node_id.id,
    head: object_id_to_bytes(db.head),
    clock: clock_entries,
    objects: [],
  }
}

///|
fn collect_objects_for_serialization(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
  objects : Array[SerializedObject],
  visited : Map[String, Bool],
) -> Unit {
  if id == @git.ObjectId::zero() {
    return
  }
  let hex = id.to_hex()
  if visited.contains(hex) {
    return
  }
  visited[hex] = true
  let obj = db.get(backing_fs, id) catch { _ => return }
  guard obj is Some(o) else { return }
  // Add this object
  objects.push({
    id: object_id_to_bytes(id),
    obj_type: object_type_to_int(o.obj_type),
    data: o.data,
  })
  // Recurse into children
  match o.obj_type {
    Commit => {
      let commit = @git.parse_commit(o.data) catch { _ => return }
      collect_objects_for_serialization(
        db,
        backing_fs,
        commit.tree,
        objects,
        visited,
      )
      for parent in commit.parents {
        collect_objects_for_serialization(
          db, backing_fs, parent, objects, visited,
        )
      }
    }
    Tree => {
      let entries = @git.parse_tree(o.data) catch { _ => return }
      for entry in entries {
        collect_objects_for_serialization(
          db,
          backing_fs,
          entry.id,
          objects,
          visited,
        )
      }
    }
    Blob | Tag => ()
  }
}

///|
/// Serialize snapshot to bytes (simple binary format)
/// Format:
///   4 bytes: version (little-endian)
///   4 bytes: node_id length
///   N bytes: node_id
///   20 bytes: head
///   4 bytes: clock entry count
///   For each clock entry:
///     4 bytes: key length
///     N bytes: key
///     8 bytes: value (little-endian)
///   4 bytes: object count
///   For each object:
///     20 bytes: id
///     1 byte: type
///     4 bytes: data length
///     N bytes: data
pub fn SerializedSnapshot::to_bytes(self : SerializedSnapshot) -> Bytes {
  let buf : Array[Byte] = []
  // Version
  write_u32_le(buf, self.version)
  // Node ID
  write_string(buf, self.node_id)
  // Head
  for i = 0; i < 20; i = i + 1 {
    buf.push(self.head[i])
  }
  // Clock entries
  write_u32_le(buf, self.clock.length())
  for entry in self.clock {
    write_string(buf, entry.0)
    write_i64_le(buf, entry.1)
  }
  // Objects
  write_u32_le(buf, self.objects.length())
  for obj in self.objects {
    for i = 0; i < 20; i = i + 1 {
      buf.push(obj.id[i])
    }
    buf.push(obj.obj_type.to_byte())
    write_u32_le(buf, obj.data.length())
    for i = 0; i < obj.data.length(); i = i + 1 {
      buf.push(obj.data[i])
    }
  }
  Bytes::from_array(buf)
}

///|
/// Deserialize snapshot from bytes - optimized with slice operations
pub fn SerializedSnapshot::from_bytes(data : Bytes) -> SerializedSnapshot {
  let mut pos = 0
  // Version
  let version = read_u32_le(data, pos)
  pos += 4
  // Node ID
  let (node_id, new_pos) = read_string(data, pos)
  pos = new_pos
  // Head - use slice instead of loop copy
  let head = data[pos:pos + 20].to_bytes()
  pos += 20
  // Clock entries
  let clock_count = read_u32_le(data, pos)
  pos += 4
  let clock : Array[(String, Int64)] = []
  for _ in 0..<clock_count {
    let (key, new_pos2) = read_string(data, pos)
    pos = new_pos2
    let value = read_i64_le(data, pos)
    pos += 8
    clock.push((key, value))
  }
  // Objects
  let object_count = read_u32_le(data, pos)
  pos += 4
  let objects : Array[SerializedObject] = []
  for _ in 0..<object_count {
    // Use slice for id bytes
    let id = data[pos:pos + 20].to_bytes()
    pos += 20
    let obj_type = data[pos].to_int()
    pos += 1
    let data_len = read_u32_le(data, pos)
    pos += 4
    // Use slice for object data
    let obj_data = data[pos:pos + data_len].to_bytes()
    pos += data_len
    objects.push({ id, obj_type, data: obj_data })
  }
  { version, node_id, head, clock, objects }
}

///|
fn write_u32_le(buf : Array[Byte], value : Int) -> Unit {
  buf.push((value & 0xFF).to_byte())
  buf.push(((value >> 8) & 0xFF).to_byte())
  buf.push(((value >> 16) & 0xFF).to_byte())
  buf.push(((value >> 24) & 0xFF).to_byte())
}

///|
fn write_i64_le(buf : Array[Byte], value : Int64) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    buf.push(((value >> (i * 8)) & 0xFFL).to_byte())
  }
}

///|
fn write_string(buf : Array[Byte], s : String) -> Unit {
  let bytes = string_to_bytes(s)
  write_u32_le(buf, bytes.length())
  for i = 0; i < bytes.length(); i = i + 1 {
    buf.push(bytes[i])
  }
}

///|
fn string_to_bytes(s : String) -> Bytes {
  let arr = s.to_array()
  let result : Array[Byte] = []
  for i = 0; i < arr.length(); i = i + 1 {
    result.push(arr[i].to_int().to_byte())
  }
  Bytes::from_array(result)
}

///|
fn read_u32_le(data : Bytes, pos : Int) -> Int {
  data[pos].to_int() |
  (data[pos + 1].to_int() << 8) |
  (data[pos + 2].to_int() << 16) |
  (data[pos + 3].to_int() << 24)
}

///|
fn read_i64_le(data : Bytes, pos : Int) -> Int64 {
  let mut result = 0L
  for i = 0; i < 8; i = i + 1 {
    result = result | (data[pos + i].to_int64() << (i * 8))
  }
  result
}

///|
fn read_string(data : Bytes, pos : Int) -> (String, Int) {
  let len = read_u32_le(data, pos)
  let chars : Array[Char] = []
  for i = 0; i < len; i = i + 1 {
    chars.push(data[pos + 4 + i].to_int().unsafe_to_char())
  }
  (String::from_array(chars), pos + 4 + len)
}

///|
/// Calculate total serialized size
pub fn SerializedSnapshot::byte_size(self : SerializedSnapshot) -> Int {
  let mut size = 0
  size += 4 // version
  size += 4 + self.node_id.length() // node_id
  size += 20 // head
  size += 4 // clock count
  for entry in self.clock {
    size += 4 + entry.0.length() + 8 // key + value
  }
  size += 4 // object count
  for obj in self.objects {
    size += 20 + 1 + 4 + obj.data.length() // id + type + len + data
  }
  size
}

///|
/// Statistics about serialized data
pub(all) struct SerializationStats {
  total_bytes : Int
  object_count : Int
  commit_count : Int
  tree_count : Int
  blob_count : Int
  blob_bytes : Int
}

///|
pub fn SerializedSnapshot::stats(
  self : SerializedSnapshot,
) -> SerializationStats {
  let mut commits = 0
  let mut trees = 0
  let mut blobs = 0
  let mut blob_bytes = 0
  for obj in self.objects {
    match obj.obj_type {
      1 => commits += 1
      2 => trees += 1
      3 => {
        blobs += 1
        blob_bytes += obj.data.length()
      }
      _ => ()
    }
  }
  {
    total_bytes: self.byte_size(),
    object_count: self.objects.length(),
    commit_count: commits,
    tree_count: trees,
    blob_count: blobs,
    blob_bytes,
  }
}
