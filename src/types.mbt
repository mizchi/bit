///| Git object types and common errors

///|
/// SHA-1 object identifier (20 bytes)
pub struct ObjectId {
  bytes : FixedArray[Byte] // 20 bytes
}

///|
pub fn ObjectId::new(bytes : FixedArray[Byte]) -> ObjectId {
  { bytes, }
}

///|
pub fn ObjectId::zero() -> ObjectId {
  { bytes: FixedArray::make(20, b'\x00') }
}

///|
/// Convert ObjectId to Bytes (20 bytes) - zero-copy when possible
pub fn ObjectId::to_bytes(self : ObjectId) -> Bytes {
  Bytes::from_fixedarray(self.bytes)
}

///|
/// Create ObjectId from Bytes (must be exactly 20 bytes)
pub fn ObjectId::from_bytes(data : Bytes) -> ObjectId raise GitError {
  if data.length() != 20 {
    raise GitError::InvalidObject("Invalid ObjectId length: \{data.length()}")
  }
  let bytes = FixedArray::make(20, b'\x00')
  for i = 0; i < 20; i = i + 1 {
    bytes[i] = data[i]
  }
  { bytes, }
}

///|
/// Create ObjectId from Bytes at offset (for parsing packed data)
pub fn ObjectId::from_bytes_at(data : Bytes, offset : Int) -> ObjectId {
  let bytes = FixedArray::make(20, b'\x00')
  for i = 0; i < 20; i = i + 1 {
    bytes[i] = data[offset + i]
  }
  { bytes, }
}

///|
pub fn ObjectId::from_hex(hex : String) -> ObjectId raise GitError {
  if hex.length() != 40 {
    raise GitError::InvalidObject("Invalid hex length: \{hex.length()}")
  }
  let bytes = FixedArray::make(20, b'\x00')
  let chars = hex.to_array()
  for i = 0; i < 20; i = i + 1 {
    let hi = hex_char_to_int(chars[i * 2])
    let lo = hex_char_to_int(chars[i * 2 + 1])
    bytes[i] = ((hi << 4) | lo).to_byte()
  }
  { bytes, }
}

///|
fn hex_char_to_int(c : Char) -> Int raise GitError {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    raise GitError::InvalidObject("Invalid hex char: \{c}")
  }
}

///|
pub fn ObjectId::to_hex(self : ObjectId) -> String {
  let result = StringBuilder::new()
  for b in self.bytes {
    let hi = (b.to_int() >> 4) & 0x0f
    let lo = b.to_int() & 0x0f
    result.write_char(int_to_hex_char(hi))
    result.write_char(int_to_hex_char(lo))
  }
  result.to_string()
}

///|
fn int_to_hex_char(i : Int) -> Char {
  if i < 10 {
    (i + '0'.to_int()).unsafe_to_char()
  } else {
    (i - 10 + 'a'.to_int()).unsafe_to_char()
  }
}

///|
pub impl Show for ObjectId with output(self, logger) {
  logger.write_string(self.to_hex())
}

///|
pub impl Eq for ObjectId with equal(self, other) {
  for i = 0; i < 20; i = i + 1 {
    if self.bytes[i] != other.bytes[i] {
      return false
    }
  }
  true
}

///|
/// Hash implementation for using ObjectId as Map key
pub impl Hash for ObjectId with hash_combine(self, hasher) {
  // Use first 8 bytes as hash (sufficient for distribution)
  for i = 0; i < 8; i = i + 1 {
    self.bytes[i].hash_combine(hasher)
  }
}

///|
/// Git object types
pub(all) enum ObjectType {
  Blob
  Tree
  Commit
  Tag
} derive(Eq)

///|
pub fn ObjectType::to_string(self : ObjectType) -> String {
  match self {
    Blob => "blob"
    Tree => "tree"
    Commit => "commit"
    Tag => "tag"
  }
}

///|
pub fn ObjectType::to_packfile_type(self : ObjectType) -> Int {
  match self {
    Commit => 1
    Tree => 2
    Blob => 3
    Tag => 4
  }
}

///|
pub impl Show for ObjectType with output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// Git operation errors
pub(all) suberror GitError {
  InvalidObject(String)
  HashMismatch(String, String)
  PackfileError(String)
  ProtocolError(String)
  IoError(String)
} derive(Show, Eq)

///|
/// Tree entry in a Git tree object
pub struct TreeEntry {
  mode : String // "100644", "040000", etc.
  name : String
  id : ObjectId
}

///|
pub fn TreeEntry::new(mode : String, name : String, id : ObjectId) -> TreeEntry {
  { mode, name, id }
}

///|
/// Git commit object
pub struct Commit {
  tree : ObjectId
  parents : Array[ObjectId]
  author : String
  author_time : Int64
  author_tz : String
  committer : String
  commit_time : Int64
  committer_tz : String
  message : String
}

///|
pub fn Commit::new(
  tree : ObjectId,
  parents : Array[ObjectId],
  author : String,
  author_time : Int64,
  author_tz : String,
  committer : String,
  commit_time : Int64,
  committer_tz : String,
  message : String,
) -> Commit {
  {
    tree,
    parents,
    author,
    author_time,
    author_tz,
    committer,
    commit_time,
    committer_tz,
    message,
  }
}
