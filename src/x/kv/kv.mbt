///| Kv core implementation

///|
/// Create a new Kv from an existing BitFs
pub fn Kv::new(
  node_id : NodeId,
  bitfs : @fs.Fs,
  head : @git.ObjectId,
) -> Kv {
  {
    node_id,
    bitfs,
    clock: VectorClock::new(),
    head,
    peers: {},
    pending_objects: {},
  }
}

///|
/// Create an empty Kv
pub fn Kv::empty(node_id : NodeId, git_dir : String) -> Kv {
  let bitfs = @fs.Fs::empty(git_dir)
  {
    node_id,
    bitfs,
    clock: VectorClock::new(),
    head: @git.ObjectId::zero(),
    peers: {},
    pending_objects: {},
  }
}

///|
/// Get the current HEAD
pub fn Kv::head(self : Kv) -> @git.ObjectId {
  self.head
}

///|
/// Get the node ID
pub fn Kv::node_id(self : Kv) -> NodeId {
  self.node_id
}

///|
/// Get the current vector clock
pub fn Kv::clock(self : Kv) -> VectorClock {
  self.clock
}

///|
/// Check if there are uncommitted changes
pub fn Kv::is_dirty(self : Kv) -> Bool {
  self.bitfs.is_dirty()
}

///|
/// Get value by hierarchical key
/// Key format: "/path/to/key" or "path/to/key"
pub fn Kv::get(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  key : String,
) -> Bytes? {
  let path = normalize_key(key)
  let result = self.bitfs.read_file(backing_fs, path) catch { _ => return None }
  Some(result)
}

///|
/// Set value by hierarchical key
pub fn Kv::set(self : Kv, key : String, value : Bytes) -> Unit {
  let path = normalize_key(key)
  self.bitfs.write_file(path, value)
}

///|
/// Set string value
pub fn Kv::set_string(self : Kv, key : String, value : String) -> Unit {
  self.set(
    key,
    Bytes::from_array(value.to_array().map(fn(c) { c.to_int().to_byte() })),
  )
}

///|
/// Delete a key
pub fn Kv::delete(self : Kv, key : String) -> Unit {
  let path = normalize_key(key)
  self.bitfs.remove_file(path)
}

///|
/// Check if key exists
pub fn Kv::has(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  key : String,
) -> Bool {
  let path = normalize_key(key)
  self.bitfs.is_file(backing_fs, path)
}

///|
/// List keys under a prefix (directory)
pub fn Kv::list(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  prefix : String,
) -> Array[String] {
  let path = normalize_key(prefix)
  let entries = self.bitfs.readdir(backing_fs, path) catch { _ => return [] }
  entries
}

///|
/// List all keys recursively under a prefix
pub fn Kv::list_recursive(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  prefix : String,
) -> Array[String] {
  let results : Array[String] = []
  collect_keys_recursive(self, backing_fs, prefix, results)
  results
}

///|
fn collect_keys_recursive(
  db : Kv,
  backing_fs : &@git.RepoFileSystem,
  prefix : String,
  results : Array[String],
) -> Unit {
  let path = normalize_key(prefix)
  let entries = db.bitfs.readdir(backing_fs, path) catch { _ => return }
  for entry in entries {
    let full_path = if path.length() == 0 { entry } else { path + "/" + entry }
    if db.bitfs.is_file(backing_fs, full_path) {
      results.push("/" + full_path)
    } else if db.bitfs.is_dir(backing_fs, full_path) {
      collect_keys_recursive(db, backing_fs, "/" + full_path, results)
    }
  }
}

///|
/// Commit current changes and update HEAD
pub fn Kv::commit(
  self : Kv,
  write_fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  message : String,
  timestamp : Int64,
) -> @git.ObjectId raise @git.GitError {
  // Increment our clock
  self.clock = self.clock.increment(self.node_id)
  // Create snapshot
  let author = self.node_id.id
  let snapshot = self.bitfs.snapshot(
    write_fs, backing_fs, message, author, timestamp,
  )
  self.head = snapshot.commit_id
  snapshot.commit_id
}

///|
/// Discard uncommitted changes
pub fn Kv::rollback(self : Kv) -> Unit {
  self.bitfs.rollback()
}

///|
/// Normalize key to path format
fn normalize_key(key : String) -> String {
  let mut result = key
  // Remove leading slashes
  while result.length() > 0 && result[0] == '/' {
    result = String::unsafe_substring(result, start=1, end=result.length())
  }
  // Remove trailing slashes
  while result.length() > 0 && result[result.length() - 1] == '/' {
    result = String::unsafe_substring(result, start=0, end=result.length() - 1)
  }
  result
}
