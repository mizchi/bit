///| Promisor remote support for partial clones

///| Allows fetching missing objects on-demand from a remote

///|
/// Read promisor remote URL from .git/objects/info/promisor
pub fn read_promisor_remote(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  let promisor_path = join_path(git_dir, "objects/info/promisor")
  if not(fs.is_file(promisor_path)) {
    return None
  }
  let content = fs.read_file(promisor_path) catch { _ => return None }
  let remote = @utf8.decode_lossy(content[:]).trim().to_string()
  if remote.length() > 0 {
    Some(remote)
  } else {
    None
  }
}

///|
/// Check if this is a partial clone repository
pub fn is_partial_clone(fs : &@git.RepoFileSystem, git_dir : String) -> Bool {
  read_promisor_remote(fs, git_dir) is Some(_)
}

///|
/// Promisor-aware object database that can fetch missing objects
pub struct PromisorDb {
  db : ObjectDb
  git_dir : String
  promisor_remote : String?
  // Cache for fetched objects (to avoid duplicate fetches)
  fetched : Map[String, Bool]
}

///|
pub fn PromisorDb::new(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  lazy? : Bool = true,
) -> PromisorDb raise @git.GitError {
  let db = if lazy {
    ObjectDb::load_lazy(fs, git_dir)
  } else {
    ObjectDb::load(fs, git_dir)
  }
  let promisor_remote = read_promisor_remote(fs, git_dir)
  { db, git_dir, promisor_remote, fetched: {} }
}

///|
/// Get object synchronously (for non-async contexts, local only)
pub fn PromisorDb::get(
  self : PromisorDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> @git.PackObject? raise @git.GitError {
  self.db.get(fs, id)
}

///|
/// Check if an object exists locally
pub fn PromisorDb::has_local(
  self : PromisorDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> Bool raise @git.GitError {
  match self.db.get(fs, id) {
    Some(_) => true
    None => false
  }
}

///|
/// Check if this is a partial clone with promisor remote
pub fn PromisorDb::has_promisor(self : PromisorDb) -> Bool {
  self.promisor_remote is Some(_)
}

///|
/// Get the promisor remote URL if available
pub fn PromisorDb::get_promisor_remote(self : PromisorDb) -> String? {
  self.promisor_remote
}

///|
/// Fetch missing objects from the promisor remote (async)
/// Returns the fetched objects and writes them to local storage
pub async fn PromisorDb::fetch_missing(
  self : PromisorDb,
  write_fs : &@git.FileSystem,
  ids : Array[@git.ObjectId],
) -> Array[@git.PackObject] raise @git.GitError {
  guard self.promisor_remote is Some(remote) else { return [] }
  // Filter out already fetched
  let to_fetch : Array[@git.ObjectId] = []
  for id in ids {
    let hex = id.to_hex()
    if not(self.fetched.contains(hex)) {
      to_fetch.push(id)
      self.fetched.set(hex, true)
    }
  }
  if to_fetch.length() == 0 {
    return []
  }
  // Fetch from remote
  let objects = @git.fetch_objects_http(remote, to_fetch, true, depth=0)
  // Write to local storage
  for obj in objects {
    let _ = write_loose_object(write_fs, self.git_dir, obj.obj_type, obj.data)

  }
  objects
}

///|
/// Fetch a single missing object (async)
pub async fn PromisorDb::fetch_one(
  self : PromisorDb,
  write_fs : &@git.FileSystem,
  id : @git.ObjectId,
) -> @git.PackObject? raise @git.GitError {
  let objects = self.fetch_missing(write_fs, [id])
  for obj in objects {
    if obj.id == id {
      return Some(obj)
    }
  }
  None
}

///|
/// Get object, fetching from remote if necessary (async version)
/// Requires both read and write filesystem access
pub async fn PromisorDb::get_or_fetch(
  self : PromisorDb,
  read_fs : &@git.RepoFileSystem,
  write_fs : &@git.FileSystem,
  id : @git.ObjectId,
) -> @git.PackObject? raise @git.GitError {
  // First try local
  let local = self.db.get(read_fs, id)
  if local is Some(_) {
    return local
  }
  // If not found and we have a promisor remote, fetch it
  if self.promisor_remote is None {
    return None
  }
  let hex = id.to_hex()
  // Check if already tried to fetch
  if self.fetched.contains(hex) {
    return None
  }
  // Fetch and return
  self.fetch_one(write_fs, id)
}
