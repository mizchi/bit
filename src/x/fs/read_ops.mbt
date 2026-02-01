///| Read operations for Fs (RepoFileSystem trait implementation)

///|
fn is_tree_mode(mode : String) -> Bool {
  mode == "040000" || mode == "40000"
}

///|
pub fn Fs::read_file(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bytes raise @git.GitError {
  let norm = normalize_path(path)
  if self.working.deleted.contains(norm) {
    raise @git.GitError::IoError("File not found: \{path}")
  }
  if self.working.files.get(norm) is Some(data) {
    return data
  }
  if self.cache.get_blob(norm) is Some(data) {
    return data
  }
  let obj_id = self.resolve_path(backing_fs, norm)
  guard obj_id is Some(id) else {
    raise @git.GitError::IoError("File not found: \{path}")
  }
  let db = self.get_db(backing_fs)
  let obj = db.get(backing_fs, id)
  guard obj is Some(o) else {
    raise @git.GitError::IoError("Blob not found: \{id}")
  }
  if o.obj_type != @git.ObjectType::Blob {
    raise @git.GitError::InvalidObject("Not a file: \{path}")
  }
  self.cache.set_blob(norm, o.data)
  o.data
}

///|
pub fn Fs::readdir(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Array[String] raise @git.GitError {
  let norm = normalize_path(path)
  let entries : Map[String, Bool] = {}
  for item in self.working.files.to_array() {
    let (file_path, _) = item
    let rel = if norm.length() == 0 {
      file_path
    } else if file_path.has_prefix(norm + "/") {
      String::unsafe_substring(
        file_path,
        start=norm.length() + 1,
        end=file_path.length(),
      )
    } else {
      continue
    }
    match split_first(rel) {
      (name, _) => entries[name] = true
    }
  }
  for item in self.working.dirs.to_array() {
    let (dir_path, _) = item
    let rel = if norm.length() == 0 {
      dir_path
    } else if dir_path.has_prefix(norm + "/") {
      String::unsafe_substring(
        dir_path,
        start=norm.length() + 1,
        end=dir_path.length(),
      )
    } else {
      continue
    }
    match split_first(rel) {
      (name, _) => entries[name] = true
    }
  }
  self.readdir_from_layers(backing_fs, norm, entries)
  self.readdir_from_tree(backing_fs, norm, self.base_tree, entries)
  for item in self.working.deleted.to_array() {
    let (del_path, _) = item
    if parent_dir(del_path) == norm ||
      (norm.length() == 0 && not(del_path.contains("/"))) {
      entries.remove(basename(del_path))
    }
  }
  let out : Array[String] = []
  for item in entries.to_array() {
    let (name, _) = item
    out.push(name)
  }
  out.sort()
  out
}

///|
fn Fs::readdir_from_layers(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  norm : String,
  entries : Map[String, Bool],
) -> Unit {
  for layer in self.layers {
    self.readdir_from_tree(backing_fs, norm, layer.tree_id, entries) catch {
      _ => ()
    }
  }
}

///|
fn Fs::readdir_from_tree(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
  tree_id : @git.ObjectId,
  entries : Map[String, Bool],
) -> Unit raise @git.GitError {
  if tree_id == @git.ObjectId::zero() {
    return
  }
  let tree_entries = self.get_tree_entries(backing_fs, tree_id)
  if path.length() == 0 {
    for entry in tree_entries {
      entries[entry.name] = true
    }
    return
  }
  let parts = split_path(path)
  let mut current_entries = tree_entries
  for i = 0; i < parts.length(); i = i + 1 {
    let part = parts[i]
    let mut found = false
    for entry in current_entries {
      if entry.name == part {
        if is_tree_mode(entry.mode) {
          current_entries = self.get_tree_entries(backing_fs, entry.id)
          found = true
          break
        } else {
          return
        }
      }
    }
    if not(found) {
      return
    }
  }
  for entry in current_entries {
    entries[entry.name] = true
  }
}

///|
pub fn Fs::is_dir(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  let norm = normalize_path(path)
  if norm.length() == 0 {
    return true
  }
  if self.working.deleted.contains(norm) {
    return false
  }
  if self.working.dirs.contains(norm) {
    return true
  }
  for item in self.working.files.to_array() {
    let (file_path, _) = item
    if file_path.has_prefix(norm + "/") {
      return true
    }
  }
  self.is_dir_in_tree(backing_fs, norm)
}

///|
fn Fs::is_dir_in_tree(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  for layer in self.layers {
    if self.check_dir_in_tree(backing_fs, layer.tree_id, path) {
      return true
    }
  }
  self.check_dir_in_tree(backing_fs, self.base_tree, path)
}

///|
fn Fs::check_dir_in_tree(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> Bool {
  if tree_id == @git.ObjectId::zero() {
    return false
  }
  let parts = split_path(path)
  if parts.length() == 0 {
    return true
  }
  let mut current_tree = tree_id
  for i = 0; i < parts.length(); i = i + 1 {
    let part = parts[i]
    let entries = self.get_tree_entries(backing_fs, current_tree) catch {
      _ => return false
    }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        if is_tree_mode(entry.mode) {
          current_tree = entry.id
          found = true
          break
        } else {
          return false
        }
      }
    }
    if not(found) {
      return false
    }
  }
  true
}

///|
pub fn Fs::is_file(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  let norm = normalize_path(path)
  if self.working.deleted.contains(norm) {
    return false
  }
  if self.working.files.contains(norm) {
    return true
  }
  self.resolve_path(backing_fs, norm) is Some(_)
}

///|
/// Check if file exists in base tree (ignoring working layer)
pub fn Fs::exists_in_base(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  let norm = normalize_path(path)
  // Check layers and base_tree directly
  for layer in self.layers {
    if self.find_in_tree(backing_fs, layer.tree_id, norm) is Some(_) {
      return true
    }
  }
  self.find_in_tree(backing_fs, self.base_tree, norm) is Some(_)
}

///|
fn Fs::resolve_path(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> @git.ObjectId? {
  if self.cache.get_path(path) is Some(cached) {
    return cached
  }
  for layer in self.layers {
    if self.find_in_tree(backing_fs, layer.tree_id, path) is Some(id) {
      self.cache.set_path(path, Some(id))
      return Some(id)
    }
  }
  let result = self.find_in_tree(backing_fs, self.base_tree, path)
  self.cache.set_path(path, result)
  result
}

///|
fn Fs::find_in_tree(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? {
  if tree_id == @git.ObjectId::zero() {
    return None
  }
  let parts = split_path(path)
  if parts.length() == 0 {
    return None
  }
  let mut current_tree = tree_id
  for i = 0; i < parts.length(); i = i + 1 {
    let part = parts[i]
    let entries = self.get_tree_entries(backing_fs, current_tree) catch {
      _ => return None
    }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        if i == parts.length() - 1 {
          if not(is_tree_mode(entry.mode)) {
            return Some(entry.id)
          } else {
            return None
          }
        } else if is_tree_mode(entry.mode) {
          current_tree = entry.id
          found = true
          break
        } else {
          return None
        }
      }
    }
    if not(found) {
      return None
    }
  }
  None
}

///|
fn Fs::get_tree_entries(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.TreeEntry] raise @git.GitError {
  if self.cache.get_tree(tree_id) is Some(entries) {
    return entries
  }
  let db = self.get_db(backing_fs)
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Tree not found: \{tree_id}")
  }
  if o.obj_type != @git.ObjectType::Tree {
    raise @git.GitError::InvalidObject("Not a tree: \{tree_id}")
  }
  let entries = @git.parse_tree(o.data)
  self.cache.set_tree(tree_id, entries)
  entries
}

// ============================================================================
// Async read operations with on-demand fetch support
// ============================================================================

///|
/// Read file content, fetching from remote if not available locally (async).
/// This is the primary method for partial clone repositories.
pub async fn Fs::read_file_async(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  write_fs : &@git.FileSystem,
  path : String,
) -> Bytes raise @git.GitError {
  let norm = normalize_path(path)
  // Check working layer first
  if self.working.deleted.contains(norm) {
    raise @git.GitError::IoError("File not found: \{path}")
  }
  if self.working.files.get(norm) is Some(data) {
    return data
  }
  // Check cache
  if self.cache.get_blob(norm) is Some(data) {
    return data
  }
  // Resolve path to object ID
  let obj_id = self.resolve_path(read_fs, norm)
  guard obj_id is Some(id) else {
    raise @git.GitError::IoError("File not found: \{path}")
  }
  // Try to get object, using promisor if available
  let obj = self.get_object_async(read_fs, write_fs, id)
  guard obj is Some(o) else {
    raise @git.GitError::IoError("Blob not found: \{id}")
  }
  if o.obj_type != @git.ObjectType::Blob {
    raise @git.GitError::InvalidObject("Not a file: \{path}")
  }
  self.cache.set_blob(norm, o.data)
  o.data
}

///|
/// Get an object, fetching from promisor remote if not available locally (async).
async fn Fs::get_object_async(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  write_fs : &@git.FileSystem,
  id : @git.ObjectId,
) -> @git.PackObject? raise @git.GitError {
  // First try local via PromisorDb
  let promisor_db = self.get_promisor_db(read_fs)
  match promisor_db {
    Some(pdb) => {
      // Try local first
      let local_obj = pdb.get(read_fs, id)
      if local_obj is Some(_) {
        return local_obj
      }
      // If promisor remote available, fetch
      if pdb.has_promisor() {
        return pdb.fetch_one(write_fs, id)
      }
      None
    }
    None => {
      // Promisor disabled, use regular ObjectDb
      let db = self.get_db(read_fs)
      db.get(read_fs, id)
    }
  }
}

///|
/// Prefetch multiple objects from promisor remote (async).
/// Useful for batch fetching before accessing many files.
pub async fn Fs::prefetch(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  write_fs : &@git.FileSystem,
  paths : Array[String],
) -> Int raise @git.GitError {
  let promisor_db = self.get_promisor_db(read_fs)
  guard promisor_db is Some(pdb) else { return 0 }
  if not(pdb.has_promisor()) {
    return 0
  }
  // Collect object IDs that need fetching
  let ids : Array[@git.ObjectId] = []
  for path in paths {
    let norm = normalize_path(path)
    // Skip working layer files
    if self.working.files.contains(norm) {
      continue
    }
    if self.working.deleted.contains(norm) {
      continue
    }
    // Resolve path to object ID
    match self.resolve_path(read_fs, norm) {
      Some(id) =>
        // Check if not already cached
        if self.cache.get_blob(norm) is None {
          // Check if not locally available
          if not(pdb.has_local(read_fs, id)) {
            ids.push(id)
          }
        }
      None => ()
    }
  }
  if ids.length() == 0 {
    return 0
  }
  // Batch fetch
  let fetched = pdb.fetch_missing(write_fs, ids)
  fetched.length()
}

///|
/// Check if a file requires fetching from remote
pub fn Fs::needs_fetch(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool raise @git.GitError {
  let norm = normalize_path(path)
  // Check working layer
  if self.working.files.contains(norm) || self.working.deleted.contains(norm) {
    return false
  }
  // Check cache
  if self.cache.get_blob(norm) is Some(_) {
    return false
  }
  // Resolve to object ID
  let obj_id = self.resolve_path(read_fs, norm)
  guard obj_id is Some(id) else { return false }
  // Check if object exists locally
  let promisor_db = self.get_promisor_db(read_fs)
  match promisor_db {
    Some(pdb) => not(pdb.has_local(read_fs, id))
    None => {
      let db = self.get_db(read_fs)
      db.get(read_fs, id) is None
    }
  }
}

///|
/// Simple glob pattern matching.
/// Supports: * (any chars except /), ** (any path), ? (single char)
fn glob_match(pattern : String, path : String) -> Bool {
  glob_match_impl(pattern, 0, path, 0)
}

///|
fn glob_match_impl(pattern : String, pi : Int, path : String, si : Int) -> Bool {
  let plen = pattern.length()
  let slen = path.length()
  // Both exhausted
  if pi >= plen && si >= slen {
    return true
  }
  // Pattern exhausted but path remains
  if pi >= plen {
    return false
  }
  // Check for **
  if pi + 1 < plen && pattern[pi] == '*' && pattern[pi + 1] == '*' {
    // Skip trailing / after **
    let next_pi = if pi + 2 < plen && pattern[pi + 2] == '/' {
      pi + 3
    } else {
      pi + 2
    }
    // ** matches zero or more path segments
    for i in si..<=slen {
      if glob_match_impl(pattern, next_pi, path, i) {
        return true
      }
    }
    return false
  }
  // Path exhausted but pattern remains
  if si >= slen {
    // Only valid if remaining pattern is all * or **
    if pattern[pi] == '*' {
      return glob_match_impl(pattern, pi + 1, path, si)
    }
    return false
  }
  // Single * - match any chars except /
  if pattern[pi] == '*' {
    // Try matching zero chars
    if glob_match_impl(pattern, pi + 1, path, si) {
      return true
    }
    // Try matching one more char (not /)
    if path[si] != '/' {
      return glob_match_impl(pattern, pi, path, si + 1)
    }
    return false
  }
  // ? matches any single char except /
  if pattern[pi] == '?' {
    if path[si] != '/' {
      return glob_match_impl(pattern, pi + 1, path, si + 1)
    }
    return false
  }
  // Literal match
  if pattern[pi] == path[si] {
    return glob_match_impl(pattern, pi + 1, path, si + 1)
  }
  false
}

///|
/// Prefetch files matching a glob pattern.
/// Example patterns: "*.rs", "src/**/*.mbt", "README.*"
pub async fn Fs::prefetch_glob(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  write_fs : &@git.FileSystem,
  pattern : String,
) -> Int raise @git.GitError {
  // Collect all files matching the pattern
  let matching : Array[String] = []
  self.collect_matching_files(read_fs, "", pattern, matching)
  if matching.length() == 0 {
    return 0
  }
  // Use existing prefetch
  self.prefetch(read_fs, write_fs, matching)
}

///|
/// Recursively collect files matching a glob pattern
fn Fs::collect_matching_files(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  dir : String,
  pattern : String,
  result : Array[String],
) -> Unit raise @git.GitError {
  let entries = self.readdir(read_fs, dir)
  for entry in entries {
    let full_path = if dir == "" { entry } else { dir + "/" + entry }
    if self.is_file(read_fs, full_path) {
      if glob_match(pattern, full_path) {
        result.push(full_path)
      }
    } else if self.is_dir(read_fs, full_path) {
      // Recurse into subdirectory
      self.collect_matching_files(read_fs, full_path, pattern, result)
    }
  }
}

///|
/// Collect files in breadth-first order up to a limit.
/// Useful for progressive preloading.
pub fn Fs::collect_files_bfs(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  limit : Int,
) -> Array[String] raise @git.GitError {
  let result : Array[String] = []
  let queue : Array[String] = [""]
  let mut head = 0
  while head < queue.length() && result.length() < limit {
    let dir = queue[head]
    head += 1
    let entries = self.readdir(read_fs, dir)
    for entry in entries {
      if result.length() >= limit {
        break
      }
      let full_path = if dir == "" { entry } else { dir + "/" + entry }
      if self.is_file(read_fs, full_path) {
        result.push(full_path)
      } else if self.is_dir(read_fs, full_path) {
        // Add directory to queue for later processing
        queue.push(full_path)
      }
    }
  }
  result
}

///|
/// Prefetch files in breadth-first order.
/// Prioritizes shallow files (root level first, then subdirs).
pub async fn Fs::prefetch_bfs(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  write_fs : &@git.FileSystem,
  limit : Int,
) -> Int raise @git.GitError {
  let files = self.collect_files_bfs(read_fs, limit)
  self.prefetch(read_fs, write_fs, files)
}

///|
/// Get list of files that need fetching, in BFS order.
/// Useful for showing progress or prioritizing fetches.
pub fn Fs::get_pending_fetches(
  self : Fs,
  read_fs : &@git.RepoFileSystem,
  limit : Int,
) -> Array[String] raise @git.GitError {
  let files = self.collect_files_bfs(read_fs, limit)
  let pending : Array[String] = []
  for file in files {
    if self.needs_fetch(read_fs, file) {
      pending.push(file)
    }
  }
  pending
}
