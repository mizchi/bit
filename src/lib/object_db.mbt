///| Git object database loader (loose + pack + idx)

///|
pub struct PackIndex {
  pack_path : String
  ids : Array[String]
  offsets : Array[Int64]
}

///|
/// Lazy pack index - loads index data on first access
pub struct LazyPackIndex {
  idx_path : String
  pack_path : String
  mut loaded : PackIndex?
}

///|
pub fn LazyPackIndex::new(
  idx_path : String,
  pack_path : String,
) -> LazyPackIndex {
  { idx_path, pack_path, loaded: None }
}

///|
pub fn LazyPackIndex::get(
  self : LazyPackIndex,
  fs : &@git.RepoFileSystem,
) -> PackIndex raise @git.GitError {
  match self.loaded {
    Some(idx) => idx
    None => {
      let data = fs.read_file(self.idx_path)
      let idx = parse_pack_index(data, self.pack_path)
      self.loaded = Some(idx)
      idx
    }
  }
}

///|
pub fn LazyPackIndex::find_offset(
  self : LazyPackIndex,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> Int64? raise @git.GitError {
  let idx = self.get(fs)
  idx.find_offset(id)
}

///|
pub fn LazyPackIndex::find_offset_hex(
  self : LazyPackIndex,
  fs : &@git.RepoFileSystem,
  hex : String,
) -> Int64? raise @git.GitError {
  let idx = self.get(fs)
  idx.find_offset_hex(hex)
}

///|
pub fn PackIndex::find_offset(self : PackIndex, id : @git.ObjectId) -> Int64? {
  let target = id.to_hex()
  PackIndex::find_offset_hex(self, target)
}

///|
pub fn PackIndex::find_offset_hex(self : PackIndex, hex : String) -> Int64? {
  let mut lo = 0
  let mut hi = self.ids.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let cmp = String::compare(self.ids[mid], hex)
    if cmp == 0 {
      return Some(self.offsets[mid])
    } else if cmp < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  None
}

///|
pub struct ObjectDb {
  objects_dir : String // base path for objects
  loose_paths : Map[String, String] // hex -> path (cache)
  packs : Array[PackIndex]
  lazy_packs : Array[LazyPackIndex] // lazily loaded pack indexes
}

///|
/// Load ObjectDb with full loose object scan (slower but complete)
pub fn ObjectDb::load(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> ObjectDb raise @git.GitError {
  let objects_dir = join_path(git_dir, "objects")
  let loose_paths = if fs.is_dir(objects_dir) {
    collect_loose_paths(fs, objects_dir)
  } else {
    {}
  }
  let packs = if fs.is_dir(objects_dir) {
    let pack_dir = join_path(objects_dir, "pack")
    if fs.is_dir(pack_dir) {
      load_pack_indexes(fs, pack_dir)
    } else {
      []
    }
  } else {
    []
  }
  { objects_dir, loose_paths, packs, lazy_packs: [] }
}

///|
/// Load ObjectDb lazily - don't scan loose objects or load pack indexes upfront
pub fn ObjectDb::load_lazy(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> ObjectDb raise @git.GitError {
  let objects_dir = join_path(git_dir, "objects")
  let lazy_packs = if fs.is_dir(objects_dir) {
    let pack_dir = join_path(objects_dir, "pack")
    if fs.is_dir(pack_dir) {
      collect_lazy_pack_indexes(fs, pack_dir)
    } else {
      []
    }
  } else {
    []
  }
  { objects_dir, loose_paths: {}, packs: [], lazy_packs }
}

///|
pub fn ObjectDb::get(
  self : ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> @git.PackObject? raise @git.GitError {
  let seen : Map[String, Bool] = {}
  get_by_hex(self, fs, id.to_hex(), seen)
}

///|
fn get_by_hex(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  hex : String,
  seen : Map[String, Bool],
) -> @git.PackObject? raise @git.GitError {
  if seen.contains(hex) {
    raise @git.GitError::InvalidObject("Delta cycle detected: \{hex}")
  }
  seen[hex] = true
  // Try to load from loose objects - first check cache, then try direct path
  let loose_path = match db.loose_paths.get(hex) {
    Some(path) => Some(path)
    None =>
      // Try constructing path directly (lazy loading)
      if hex.length() == 40 {
        let prefix = String::unsafe_substring(hex, start=0, end=2)
        let suffix = String::unsafe_substring(hex, start=2, end=40)
        let path = db.objects_dir + "/" + prefix + "/" + suffix
        if fs.is_file(path) {
          db.loose_paths[hex] = path // cache for future lookups
          Some(path)
        } else {
          None
        }
      } else {
        None
      }
  }
  match loose_path {
    Some(path) => {
      let compressed = fs.read_file(path)
      let raw = @zlib.zlib_decompress(compressed) catch {
        e => raise @git.GitError::InvalidObject("Zlib error: \{e}")
      }
      let obj = parse_loose_object(raw)
      // Verify hash
      let computed = @git.hash_object_content(obj.obj_type, obj.data).to_hex()
      if computed != hex {
        raise @git.GitError::HashMismatch(computed, hex)
      }
      return Some(obj)
    }
    None => ()
  }
  // Try pack files (eagerly loaded)
  for pack in db.packs {
    match PackIndex::find_offset_hex(pack, hex) {
      None => ()
      Some(offset) => {
        let data = fs.read_file(pack.pack_path)
        let obj = read_pack_object_at(data, pack, offset, db, fs, seen)
        return Some(obj)
      }
    }
  }
  // Try lazy pack files (loaded on first access)
  for lazy_pack in db.lazy_packs {
    try {
      match lazy_pack.find_offset_hex(fs, hex) {
        None => ()
        Some(offset) => {
          let pack = lazy_pack.get(fs) // ensure loaded
          let data = fs.read_file(pack.pack_path)
          let obj = read_pack_object_at(data, pack, offset, db, fs, seen)
          return Some(obj)
        }
      }
    } catch {
      _ => ()
    }
  }
  None
}

///|
pub fn load_object_store_from_fs(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectStore raise @git.GitError {
  let store = @git.ObjectStore::new()
  let objects_dir = join_path(git_dir, "objects")
  if fs.is_dir(objects_dir) {
    let loose = load_loose_objects(fs, objects_dir)
    if loose.length() > 0 {
      store.add_objects(loose)
    }
    let pack_dir = join_path(objects_dir, "pack")
    if fs.is_dir(pack_dir) {
      let packed = load_pack_objects(fs, pack_dir)
      if packed.length() > 0 {
        store.add_objects(packed)
      }
    }
  }
  store
}

///|

///|
/// Collect paths to loose objects without loading content (lazy loading)
fn collect_loose_paths(
  fs : &@git.RepoFileSystem,
  objects_dir : String,
) -> Map[String, String] raise @git.GitError {
  let result : Map[String, String] = {}
  let entries = fs.readdir(objects_dir)
  for entry in entries {
    if entry.length() != 2 {
      continue
    }
    let dir = join_path(objects_dir, entry)
    if not(fs.is_dir(dir)) {
      continue
    }
    let files = fs.readdir(dir)
    for name in files {
      if name.length() != 38 {
        continue
      }
      let path = join_path(dir, name)
      if not(fs.is_file(path)) {
        continue
      }
      let hex = entry + name
      result[hex] = path
    }
  }
  result
}

///|
fn load_loose_objects(
  fs : &@git.RepoFileSystem,
  objects_dir : String,
) -> Array[@git.PackObject] raise @git.GitError {
  let result : Array[@git.PackObject] = []
  let paths = collect_loose_paths(fs, objects_dir)
  for item in paths.to_array() {
    let (_, path) = item
    let compressed = fs.read_file(path)
    let raw = @zlib.zlib_decompress(compressed) catch {
      e => raise @git.GitError::InvalidObject("Zlib error: \{e}")
    }
    let obj = parse_loose_object(raw)
    result.push(obj)
  }
  result
}

///|
fn load_pack_indexes(
  fs : &@git.RepoFileSystem,
  pack_dir : String,
) -> Array[PackIndex] raise @git.GitError {
  let result : Array[PackIndex] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if not(entry.has_suffix(".idx")) {
      continue
    }
    let idx_path = join_path(pack_dir, entry)
    if not(fs.is_file(idx_path)) {
      continue
    }
    let base = String::unsafe_substring(entry, start=0, end=entry.length() - 4)
    let pack_path = join_path(pack_dir, base + ".pack")
    if not(fs.is_file(pack_path)) {
      continue
    }
    let data = fs.read_file(idx_path)
    let idx = parse_pack_index(data, pack_path)
    result.push(idx)
  }
  result
}

///|
/// Collect pack index paths without loading them (for lazy loading)
fn collect_lazy_pack_indexes(
  fs : &@git.RepoFileSystem,
  pack_dir : String,
) -> Array[LazyPackIndex] raise @git.GitError {
  let result : Array[LazyPackIndex] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if not(entry.has_suffix(".idx")) {
      continue
    }
    let idx_path = join_path(pack_dir, entry)
    if not(fs.is_file(idx_path)) {
      continue
    }
    let base = String::unsafe_substring(entry, start=0, end=entry.length() - 4)
    let pack_path = join_path(pack_dir, base + ".pack")
    if not(fs.is_file(pack_path)) {
      continue
    }
    result.push(LazyPackIndex::new(idx_path, pack_path))
  }
  result
}

///|
fn load_pack_objects(
  fs : &@git.RepoFileSystem,
  pack_dir : String,
) -> Array[@git.PackObject] raise @git.GitError {
  let result : Array[@git.PackObject] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if not(entry.has_suffix(".pack")) {
      continue
    }
    let path = join_path(pack_dir, entry)
    if not(fs.is_file(path)) {
      continue
    }
    let data = fs.read_file(path)
    let objects = @git.parse_packfile(data)
    for obj in objects {
      result.push(obj)
    }
  }
  result
}

///|
fn parse_pack_index(
  data : Bytes,
  pack_path : String,
) -> PackIndex raise @git.GitError {
  if data.length() < 8 {
    raise @git.GitError::InvalidObject("Index file too short")
  }
  let magic = read_u32_be_at64(data, 0)
  if magic != 0xff744f63L {
    raise @git.GitError::InvalidObject("Unsupported pack index version")
  }
  let version = read_u32_be_at64(data, 4)
  if version != 2L {
    raise @git.GitError::InvalidObject(
      "Unsupported pack index version: \{version}",
    )
  }
  let mut offset = 8
  let fanout : Array[Int64] = []
  for _ in 0..<256 {
    fanout.push(read_u32_be_at64(data, offset))
    offset += 4
  }
  let count64 = fanout[255]
  if count64 > 2147483647L {
    raise @git.GitError::InvalidObject("Too many objects in index")
  }
  let count = count64.to_int()
  let ids : Array[String] = []
  for _ in 0..<count {
    if offset + 20 > data.length() {
      raise @git.GitError::InvalidObject("Index file truncated (ids)")
    }
    let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
    for i = 0; i < 20; i = i + 1 {
      bytes[i] = data[offset + i]
    }
    offset += 20
    ids.push(@git.ObjectId::new(bytes).to_hex())
  }
  // Skip CRC32 table
  offset += count * 4
  if offset + count * 4 > data.length() {
    raise @git.GitError::InvalidObject("Index file truncated (offsets)")
  }
  let offsets : Array[Int64] = []
  let large_indices : Array[Int] = []
  for i in 0..<count {
    let v = read_u32_be_at64(data, offset)
    offset += 4
    if (v & 0x80000000L) != 0L {
      offsets.push(v & 0x7fffffffL)
      large_indices.push(i)
    } else {
      offsets.push(v)
    }
  }
  if large_indices.length() > 0 {
    let mut large_idx = 0
    while large_idx < large_indices.length() {
      if offset + 8 > data.length() {
        raise @git.GitError::InvalidObject(
          "Index file truncated (large offsets)",
        )
      }
      let v = read_u64_be_at64(data, offset)
      offset += 8
      let pos = large_indices[large_idx]
      offsets[pos] = v
      large_idx += 1
    }
  }
  { pack_path, ids, offsets }
}

///|
fn read_pack_object_at(
  data : Bytes,
  pack : PackIndex,
  offset : Int64,
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  seen : Map[String, Bool],
) -> @git.PackObject raise @git.GitError {
  let offset_i = offset_to_int(offset)
  let (type_id, size, next_offset) = @git.decode_type_and_size_at(
    data, offset_i,
  )
  match type_id {
    1 | 2 | 3 | 4 => {
      let obj_type = @git.packfile_type_to_object_type(type_id)
      let (content, _after) = @zlib.zlib_decompress_at(data, next_offset) catch {
        e => raise @git.GitError::PackfileError("Zlib error: \{e}")
      }
      if content.length() != size {
        raise @git.GitError::PackfileError(
          "Object size mismatch: expected=\{size}, got=\{content.length()}",
        )
      }
      @git.PackObject::new(obj_type, content)
    }
    6 => {
      let (back_offset, after_ref) = @git.read_ofs_delta_offset(
        data, next_offset,
      )
      let base_offset = offset_i - back_offset
      if base_offset < 0 {
        raise @git.GitError::PackfileError("Invalid OFS_DELTA base offset")
      }
      let (delta, _after) = @zlib.zlib_decompress_at(data, after_ref) catch {
        e => raise @git.GitError::PackfileError("Zlib error: \{e}")
      }
      if delta.length() != size {
        raise @git.GitError::PackfileError(
          "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
        )
      }
      let base = read_pack_object_at(
        data,
        pack,
        base_offset.to_int64(),
        db,
        fs,
        seen,
      )
      let content = @git.apply_delta(base.data, delta)
      @git.PackObject::new(base.obj_type, content)
    }
    7 => {
      let (base_hex, after_ref) = @git.read_ref_delta_id(data, next_offset)
      let (delta, _after) = @zlib.zlib_decompress_at(data, after_ref) catch {
        e => raise @git.GitError::PackfileError("Zlib error: \{e}")
      }
      if delta.length() != size {
        raise @git.GitError::PackfileError(
          "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
        )
      }
      let base = match PackIndex::find_offset_hex(pack, base_hex) {
        Some(base_offset) =>
          read_pack_object_at(data, pack, base_offset, db, fs, seen)
        None =>
          match get_by_hex(db, fs, base_hex, seen) {
            Some(obj) => obj
            None =>
              raise @git.GitError::PackfileError(
                "Missing base object for REF_DELTA",
              )
          }
      }
      let content = @git.apply_delta(base.data, delta)
      @git.PackObject::new(base.obj_type, content)
    }
    _ =>
      raise @git.GitError::PackfileError(
        "Unknown packfile object type: \{type_id}",
      )
  }
}

///|
fn parse_loose_object(data : Bytes) -> @git.PackObject raise @git.GitError {
  let len = data.length()
  if len == 0 {
    raise @git.GitError::InvalidObject("Empty loose object")
  }
  let type_buf = StringBuilder::new()
  let mut i = 0
  while i < len && data[i] != b' ' {
    type_buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  if i >= len || data[i] != b' ' {
    raise @git.GitError::InvalidObject("Invalid loose object header")
  }
  i += 1
  let mut size = 0
  while i < len && data[i] != b'\x00' {
    let b = data[i]
    if b < b'0' || b > b'9' {
      raise @git.GitError::InvalidObject("Invalid loose object size")
    }
    size = size * 10 + (b.to_int() - b'0'.to_int())
    i += 1
  }
  if i >= len || data[i] != b'\x00' {
    raise @git.GitError::InvalidObject("Invalid loose object header")
  }
  i += 1
  let content_len = len - i
  if content_len != size {
    raise @git.GitError::InvalidObject(
      "Loose object size mismatch: expected=\{size}, got=\{content_len}",
    )
  }
  let content = Bytes::from_array(
    FixedArray::makei(content_len, fn(j) { data[i + j] }),
  )
  let obj_type = object_type_from_string(type_buf.to_string())
  @git.PackObject::new(obj_type, content)
}

///|
fn object_type_from_string(s : String) -> @git.ObjectType raise @git.GitError {
  if s == "blob" {
    @git.ObjectType::Blob
  } else if s == "tree" {
    @git.ObjectType::Tree
  } else if s == "commit" {
    @git.ObjectType::Commit
  } else if s == "tag" {
    @git.ObjectType::Tag
  } else {
    raise @git.GitError::InvalidObject("Unknown object type: \{s}")
  }
}

///|
fn read_u32_be_at64(data : Bytes, start : Int) -> Int64 raise @git.GitError {
  if start + 4 > data.length() {
    raise @git.GitError::InvalidObject("Unexpected end of index data")
  }
  let b0 = data[start].to_int64()
  let b1 = data[start + 1].to_int64()
  let b2 = data[start + 2].to_int64()
  let b3 = data[start + 3].to_int64()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn read_u64_be_at64(data : Bytes, start : Int) -> Int64 raise @git.GitError {
  if start + 8 > data.length() {
    raise @git.GitError::InvalidObject("Unexpected end of index data")
  }
  let hi = read_u32_be_at64(data, start)
  let lo = read_u32_be_at64(data, start + 4)
  (hi << 32) | lo
}

///|
fn offset_to_int(offset : Int64) -> Int raise @git.GitError {
  if offset < 0L || offset > 2147483647L {
    raise @git.GitError::InvalidObject("Pack offset exceeds Int range")
  }
  offset.to_int()
}
