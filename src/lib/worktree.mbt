///| Working tree operations: status, add, commit

///|
pub struct Status {
  staged_added : Array[String]
  staged_modified : Array[String]
  staged_deleted : Array[String]
  unstaged_modified : Array[String]
  unstaged_deleted : Array[String]
  untracked : Array[String]
}

///|
/// Get status similar to `git status --porcelain` buckets.
pub async fn status(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Status raise @git.GitError {
  let profile = profile_enabled()
  let mut t0 = profile_start(profile)
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if fs.is_file(git_dir) {
    resolve_gitdir(fs, git_dir)
  } else {
    git_dir
  }
  let autocrlf = read_autocrlf_setting(fs, actual_git_dir)
  let racy_git = racy_git_enabled()
  let index_entries = read_index_entries(fs, actual_git_dir)
  t0 = profile_lap(profile, "status read_index_entries", t0)
  let index_map : Map[String, IndexEntry] = {}
  for e in index_entries {
    index_map[e.path] = e
  }
  let untracked : Array[String] = []
  let unstaged_modified : Array[String] = []
  let unstaged_deleted : Array[String] = []
  let files = list_working_files_async(fs, root)
  t0 = profile_lap(profile, "status list_working_files", t0)
  let visited : Map[String, Bool] = {}
  for path in files {
    visited[path] = true
    match index_map.get(path) {
      None => untracked.push(path)
      Some(entry) => {
        if is_gitlink_mode_int(entry.mode) {
          continue
        }
        let abs = join_path(root, path)
        match @gitio.worktree_entry_meta(fs, abs) {
          None => ()
          Some(info) =>
            match info.kind {
              @gitio.WorktreeKindMeta::Regular => {
                let mut stat_matches = false
                let mut size_mismatch = false
                match info.size {
                  Some(sz) => {
                    size_mismatch = sz != entry.size
                    match info.mtime_sec {
                      Some(ms) =>
                        match info.mtime_nsec {
                          Some(mn) =>
                            if entry.mtime_sec != 0 || entry.mtime_nsec != 0 {
                              stat_matches = not(size_mismatch) &&
                                ms == entry.mtime_sec &&
                                mn == entry.mtime_nsec
                            }
                          None => ()
                        }
                      None => ()
                    }
                  }
                  None => ()
                }
                if info.mode != entry.mode {
                  unstaged_modified.push(path)
                } else if size_mismatch {
                  unstaged_modified.push(path)
                } else if not(stat_matches) {
                  let content = fs.read_file(abs)
                  let normalized = normalize_worktree_content(content, autocrlf)
                  let id = @git.hash_blob(normalized)
                  if id != entry.id {
                    unstaged_modified.push(path)
                  }
                } else if racy_git {
                  let content = fs.read_file(abs)
                  let normalized = normalize_worktree_content(content, autocrlf)
                  let id = @git.hash_blob(normalized)
                  if id != entry.id {
                    unstaged_modified.push(path)
                  }
                }
              }
              @gitio.WorktreeKindMeta::Symlink => {
                let mode_changed = info.mode != entry.mode
                let mut stat_matches = false
                match info.mtime_sec {
                  Some(ms) =>
                    match info.mtime_nsec {
                      Some(mn) =>
                        if entry.mtime_sec != 0 || entry.mtime_nsec != 0 {
                          stat_matches = ms == entry.mtime_sec &&
                            mn == entry.mtime_nsec
                        }
                      None => ()
                    }
                  None => ()
                }
                if mode_changed {
                  unstaged_modified.push(path)
                } else if not(stat_matches) {
                  match @gitio.read_symlink_target_path(abs) {
                    Some(target) => {
                      let id = target |> @utf8.encode |> @git.hash_blob
                      if id != entry.id {
                        unstaged_modified.push(path)
                      }
                    }
                    None => ()
                  }
                } else if racy_git {
                  match @gitio.read_symlink_target_path(abs) {
                    Some(target) => {
                      let id = target |> @utf8.encode |> @git.hash_blob
                      if id != entry.id {
                        unstaged_modified.push(path)
                      }
                    }
                    None => ()
                  }
                }
              }
            }
        }
      }
    }
  }
  t0 = profile_lap(profile, "status scan_worktree", t0)
  for item in index_map.to_array() {
    let (path, _) = item
    if not(visited.contains(path)) {
      let abs = join_path(root, path)
      if index_map.get(path) is Some(entry) {
        if is_gitlink_mode_int(entry.mode) {
          continue
        }
      }
      if @gitio.worktree_entry_meta(fs, abs) is None {
        unstaged_deleted.push(path)
      }
    }
  }
  t0 = profile_lap(profile, "status scan_deleted", t0)
  let staged_added : Array[String] = []
  let staged_modified : Array[String] = []
  let staged_deleted : Array[String] = []
  collect_staged_changes_from_head(
    fs, actual_git_dir, index_map, staged_modified, staged_deleted,
  )
  t0 = profile_lap(profile, "status read_head_entries", t0)
  for item in index_map.to_array() {
    let (path, _) = item
    staged_added.push(path)
  }
  staged_added.sort()
  staged_modified.sort()
  staged_deleted.sort()
  unstaged_modified.sort()
  unstaged_deleted.sort()
  untracked.sort()
  ignore(profile_lap(profile, "status sort", t0))
  {
    staged_added,
    staged_modified,
    staged_deleted,
    unstaged_modified,
    unstaged_deleted,
    untracked,
  }
}

///|
/// Format status in porcelain-like lines.
pub async fn status_porcelain(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[String] raise @git.GitError {
  let s = status(fs, root)
  status_porcelain_from(s)
}

///|
pub fn status_porcelain_from(s : Status) -> Array[String] {
  if s.staged_added.length() == 0 &&
    s.staged_modified.length() == 0 &&
    s.staged_deleted.length() == 0 &&
    s.unstaged_modified.length() == 0 &&
    s.unstaged_deleted.length() == 0 &&
    s.untracked.length() == 0 {
    return []
  }
  let xmap : Map[String, Char] = {}
  let ymap : Map[String, Char] = {}
  for p in s.staged_added {
    xmap[p] = 'A'
  }
  for p in s.staged_modified {
    xmap[p] = 'M'
  }
  for p in s.staged_deleted {
    xmap[p] = 'D'
  }
  for p in s.unstaged_modified {
    ymap[p] = 'M'
  }
  for p in s.unstaged_deleted {
    ymap[p] = 'D'
  }
  let paths : Map[String, Bool] = {}
  for p in s.staged_added {
    paths[p] = true
  }
  for p in s.staged_modified {
    paths[p] = true
  }
  for p in s.staged_deleted {
    paths[p] = true
  }
  for p in s.unstaged_modified {
    paths[p] = true
  }
  for p in s.unstaged_deleted {
    paths[p] = true
  }
  let out : Array[String] = []
  let list : Array[String] = []
  for item in paths.to_array() {
    let (p, _) = item
    list.push(p)
  }
  list.sort()
  for p in list {
    let x = xmap.get(p).unwrap_or(' ')
    let y = ymap.get(p).unwrap_or(' ')
    out.push("\{x}\{y} \{p}")
  }
  for p in s.untracked {
    out.push("?? \{p}")
  }
  out
}

///|
/// Add files to index (like `git add`).
pub fn add_paths(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let autocrlf = read_autocrlf_setting(rfs, actual_git_dir)
  let entries = read_index_entries(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = {}
  for e in entries {
    map[e.path] = e
  }
  let all_paths = expand_paths(rfs, root, paths)
  for path in all_paths {
    let abs = join_path(root, path)
    if rfs.is_file(abs) {
      let content = rfs.read_file(abs)
      let normalized = normalize_worktree_content(content, autocrlf)
      let id = write_loose_object(
        fs,
        actual_git_dir,
        @git.ObjectType::Blob,
        normalized,
      )
      let size = content.length()
      map[path] = {
        path,
        id,
        mode: default_file_mode(),
        size,
        mtime_sec: 0,
        mtime_nsec: 0,
      }
    } else {
      map.remove(path)
    }
  }
  let out : Array[IndexEntry] = []
  for item in map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  write_index_entries(fs, actual_git_dir, out)
}

///|
/// Add files to index with worktree mode detection (native).
pub async fn add_paths_async(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let autocrlf = read_autocrlf_setting(rfs, actual_git_dir)
  let entries = read_index_entries(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = {}
  for e in entries {
    map[e.path] = e
  }
  let all_paths = expand_paths_async(rfs, root, paths)
  for path in all_paths {
    let abs = join_path(root, path)
    match @gitio.worktree_entry(rfs, abs) {
      None => map.remove(path)
      Some(info) =>
        match info.kind {
          @gitio.WorktreeKind::Regular => {
            let content = rfs.read_file(abs)
            let normalized = normalize_worktree_content(content, autocrlf)
            let id = write_loose_object(
              fs,
              actual_git_dir,
              @git.ObjectType::Blob,
              normalized,
            )
            let size = content.length()
            let mtime_sec = info.mtime_sec.unwrap_or(0)
            let mtime_nsec = info.mtime_nsec.unwrap_or(0)
            map[path] = {
              path,
              id,
              mode: info.mode,
              size,
              mtime_sec,
              mtime_nsec,
            }
          }
          @gitio.WorktreeKind::Symlink(target~) => {
            let bytes = @utf8.encode(target)
            let id = write_loose_object(
              fs,
              actual_git_dir,
              @git.ObjectType::Blob,
              bytes,
            )
            let size = bytes.length()
            let mtime_sec = info.mtime_sec.unwrap_or(0)
            let mtime_nsec = info.mtime_nsec.unwrap_or(0)
            map[path] = {
              path,
              id,
              mode: info.mode,
              size,
              mtime_sec,
              mtime_nsec,
            }
          }
        }
    }
  }
  let out : Array[IndexEntry] = []
  for item in map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  write_index_entries(fs, actual_git_dir, out)
}

///|
/// @git.Commit current index and update HEAD.
pub fn commit(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer? : String = author,
  committer_timestamp? : Int64 = author_timestamp,
  allow_empty? : Bool = false,
) -> @git.ObjectId raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let parent = resolve_head_commit(rfs, actual_git_dir)
  let entries = read_index_entries(rfs, actual_git_dir)
  let tree_id = if entries.length() == 0 {
    if not(allow_empty) {
      raise @git.GitError::InvalidObject("Empty index")
    }
    match parent {
      Some(parent_id) => {
        let db = ObjectDb::load(rfs, actual_git_dir)
        let parent_tree = match db.get(rfs, parent_id) {
          Some(obj) if obj.obj_type == @git.ObjectType::Commit =>
            (@git.parse_commit(obj.data).tree |> Some) catch {
              _ => None
            }
          _ => None
        }
        match parent_tree {
          Some(tree) => tree
          None => {
            let (empty_tree_id, empty_tree_compressed) = @git.create_tree([])
            write_object_bytes(
              fs, actual_git_dir, empty_tree_id, empty_tree_compressed,
            )
            empty_tree_id
          }
        }
      }
      None => {
        let (empty_tree_id, empty_tree_compressed) = @git.create_tree([])
        write_object_bytes(
          fs, actual_git_dir, empty_tree_id, empty_tree_compressed,
        )
        empty_tree_id
      }
    }
  } else {
    write_tree_from_index(fs, actual_git_dir, entries)
  }
  let parents = match parent {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    tree_id, parents, author, author_timestamp, "+0000", committer, committer_timestamp,
    "+0000", message,
  )
  let (commit_id, compressed) = @git.create_commit(commit)
  write_object_bytes(fs, actual_git_dir, commit_id, compressed)
  update_head_ref(fs, rfs, actual_git_dir, commit_id)
  commit_id
}

///|
fn expand_paths(
  fs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Array[String] raise @git.GitError {
  let result : Array[String] = []
  let all = list_working_files(fs, root)
  for p in paths {
    let path = normalize_rel_path(p)
    // Handle "." specially - add all files
    if path == "." {
      for f in all {
        result.push(f)
      }
      continue
    }
    let abs = join_path(root, path)
    if fs.is_dir(abs) {
      let prefix = if path.has_suffix("/") { path } else { path + "/" }
      for f in all {
        if f.has_prefix(prefix) {
          result.push(f)
        }
      }
    } else {
      result.push(path)
    }
  }
  result
}

///|
async fn expand_paths_async(
  fs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Array[String] raise @git.GitError {
  let result : Array[String] = []
  let all = list_working_files_async(fs, root)
  for p in paths {
    let path = normalize_rel_path(p)
    // Handle "." specially - add all files
    if path == "." {
      for f in all {
        result.push(f)
      }
      continue
    }
    let abs = join_path(root, path)
    if fs.is_dir(abs) {
      let prefix = if path.has_suffix("/") { path } else { path + "/" }
      for f in all {
        if f.has_prefix(prefix) {
          result.push(f)
        }
      }
    } else {
      result.push(path)
    }
  }
  result
}

///|
fn normalize_rel_path(path : String) -> String {
  if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
}

///|
fn default_file_mode() -> Int {
  33188 // 0o100644
}

///|
priv enum AutoCrlf {
  Off
  Input
  On
}

///|
fn read_autocrlf_setting(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> AutoCrlf {
  let mut value : AutoCrlf? = None
  match @gitio.env_get("HOME") {
    None => ()
    Some(home) => {
      let candidates : Array[String] = []
      if @gitio.env_get("XDG_CONFIG_HOME") is Some(base) {
        candidates.push(base + "/git/config")
      }
      candidates.push(home + "/.gitconfig")
      for path in candidates {
        if fs.is_file(path) {
          value = read_autocrlf_from_config(fs, path)
          break
        }
      }
    }
  }
  let local_path = join_path(git_dir, "config")
  if fs.is_file(local_path) {
    match read_autocrlf_from_config(fs, local_path) {
      Some(v) => value = Some(v)
      None => ()
    }
  }
  match value {
    Some(v) => v
    None => AutoCrlf::Off
  }
}

///|
fn read_autocrlf_from_config(
  fs : &@git.RepoFileSystem,
  path : String,
) -> AutoCrlf? {
  let bytes = fs.read_file(path) catch { _ => return None }
  let content = @utf8.decode_lossy(bytes[:])
  parse_autocrlf_from_content(content)
}

///|
fn parse_autocrlf_from_content(content : String) -> AutoCrlf? {
  let mut section = ""
  let mut value : AutoCrlf? = None
  for line_view in content.split("\n") {
    let line = line_view.trim().to_string()
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let inner = String::unsafe_substring(line, start=1, end=line.length() - 1)
      let inner_trim = inner.trim().to_string()
      let section_name = match inner_trim.find(" ") {
        Some(i) => String::unsafe_substring(inner_trim, start=0, end=i)
        None => inner_trim
      }
      section = section_name.to_lower()
      continue
    }
    if section != "core" {
      continue
    }
    match line.find("=") {
      None => ()
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
          .trim()
          .to_string()
          .to_lower()
        if key != "autocrlf" {
          continue
        }
        let raw_value = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          .trim()
          .to_string()
          .to_lower()
        value = raw_value |> parse_autocrlf_value |> Some
      }
    }
  }
  value
}

///|
fn parse_autocrlf_value(value : String) -> AutoCrlf {
  match value {
    "true" | "yes" | "1" => AutoCrlf::On
    "input" => AutoCrlf::Input
    _ => AutoCrlf::Off
  }
}

///|
fn racy_git_enabled() -> Bool {
  match @gitio.env_get("BIT_RACY_GIT") {
    Some(v) => v != "" && v != "0"
    None => false
  }
}

///|
fn normalize_worktree_content(content : Bytes, autocrlf : AutoCrlf) -> Bytes {
  match autocrlf {
    Off => content
    Input | On =>
      if is_binary_bytes(content) {
        content
      } else {
        normalize_crlf_to_lf(content)
      }
  }
}

///|
fn is_binary_bytes(content : Bytes) -> Bool {
  let limit = if content.length() > 8000 { 8000 } else { content.length() }
  for i in 0..<limit {
    if content[i] == b'\x00' {
      return true
    }
  }
  false
}

///|
fn normalize_crlf_to_lf(content : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  let mut changed = false
  while i < content.length() {
    if content[i] == b'\r' &&
      i + 1 < content.length() &&
      content[i + 1] == b'\n' {
      out.push(b'\n')
      i += 2
      changed = true
      continue
    }
    out.push(content[i])
    i += 1
  }
  if not(changed) {
    return content
  }
  Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
}

///|
pub fn write_loose_object(
  fs : &@git.FileSystem,
  git_dir : String,
  obj_type : @git.ObjectType,
  content : Bytes,
) -> @git.ObjectId raise @git.GitError {
  let (id, compressed) = @git.create_object(obj_type, content)
  write_object_bytes(fs, git_dir, id, compressed)
  id
}

///|
pub fn write_object_bytes(
  fs : &@git.FileSystem,
  git_dir : String,
  id : @git.ObjectId,
  compressed : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let path = join_path(
    git_dir,
    "objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length()),
  )
  let dir = join_path(
    git_dir,
    "objects/" + String::unsafe_substring(hex, start=0, end=2),
  )
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
}

///|
pub fn resolve_head_commit(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId? raise @git.GitError {
  match read_head_ref(fs, git_dir) {
    Branch(name) => resolve_ref(fs, git_dir, "refs/heads/" + name)
    Detached(id) => Some(id)
  }
}

///|
pub fn update_head_ref(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let head_path = join_path(git_dir, "HEAD")
  let head = read_head_ref(rfs, git_dir) catch {
    _ => HeadRef::Detached(commit_id)
  }
  match head {
    Branch(name) => {
      let ref_path = join_path(git_dir, "refs/heads/" + name)
      let dir = parent_dir(ref_path)
      fs.mkdir_p(dir)
      fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    Detached(_) => fs.write_string(head_path, commit_id.to_hex() + "\n")
  }
}

///|
pub fn write_tree_from_index(
  fs : &@git.FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  prefix? : String? = None,
) -> @git.ObjectId raise @git.GitError {
  // If prefix is specified, filter entries and strip prefix from paths
  let rel_entries = match prefix {
    Some(p) => {
      // Ensure prefix ends with /
      let prefix_with_slash = if p.has_suffix("/") { p } else { p + "/" }
      let result : Array[IndexEntry] = []
      for e in entries {
        if e.path.has_prefix(prefix_with_slash) {
          // Strip the prefix from the path
          let new_path = e.path[prefix_with_slash.length():].to_string() catch {
            _ => continue
          }
          result.push({
            path: new_path,
            id: e.id,
            mode: e.mode,
            size: e.size,
            mtime_sec: e.mtime_sec,
            mtime_nsec: e.mtime_nsec,
          })
        }
      }
      result
    }
    None => entries.map(e => e)
  }
  write_tree_from_entries(fs, git_dir, rel_entries)
}

///|
fn write_tree_from_entries(
  fs : &@git.FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> @git.ObjectId raise @git.GitError {
  let file_entries : Array[@git.TreeEntry] = []
  let dir_map : Map[String, Array[IndexEntry]] = {}
  for e in entries {
    match split_first(e.path) {
      (name, None) => {
        let mode = mode_to_string(e.mode)
        file_entries.push(@git.TreeEntry::new(mode, name, e.id))
      }
      (name, Some(rest)) =>
        match dir_map.get(name) {
          Some(list) =>
            list.push({
              path: rest,
              id: e.id,
              mode: e.mode,
              size: e.size,
              mtime_sec: e.mtime_sec,
              mtime_nsec: e.mtime_nsec,
            })
          None =>
            dir_map[name] = [
              {
                path: rest,
                id: e.id,
                mode: e.mode,
                size: e.size,
                mtime_sec: e.mtime_sec,
                mtime_nsec: e.mtime_nsec,
              },
            ]
        }
    }
  }
  for item in dir_map.to_array() {
    let (dir_name, list) = item
    let sub_id = write_tree_from_entries(fs, git_dir, list)
    file_entries.push(@git.TreeEntry::new("40000", dir_name, sub_id))
  }
  // Git sorts tree entries by name, with directories having "/" appended for comparison
  file_entries.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    compare_strings_lexicographic(a_key, b_key)
  })
  let (tree_id, compressed) = @git.create_tree(file_entries)
  write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn split_first(path : String) -> (String, String?) {
  match path.find("/") {
    None => (path, None)
    Some(idx) => {
      let name = String::unsafe_substring(path, start=0, end=idx)
      let rest = String::unsafe_substring(
        path,
        start=idx + 1,
        end=path.length(),
      )
      (name, Some(rest))
    }
  }
}

///|
/// Lexicographic string comparison (byte-by-byte ASCII order)
fn compare_strings_lexicographic(a : String, b : String) -> Int {
  let a_len = a.length()
  let b_len = b.length()
  let min_len = if a_len < b_len { a_len } else { b_len }
  for i in 0..<min_len {
    let a_char = a.unsafe_get(i).to_int()
    let b_char = b.unsafe_get(i).to_int()
    if a_char < b_char {
      return -1
    } else if a_char > b_char {
      return 1
    }
  }
  // If all characters are equal, shorter string comes first
  if a_len < b_len {
    -1
  } else if a_len > b_len {
    1
  } else {
    0
  }
}

///|
fn mode_to_string(mode : Int) -> String {
  if mode == default_file_mode() {
    "100644"
  } else {
    to_octal_string(mode)
  }
}

///|
fn to_octal_string(value : Int) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = []
  let mut v = value
  while v > 0 {
    let d = v % 8
    digits.push((d + '0'.to_int()).unsafe_to_char())
    v = v / 8
  }
  let rev = digits.rev()
  let sb = StringBuilder::new()
  for c in rev {
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn trim_worktree_text(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s[start]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s[end - 1]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      end -= 1
    } else {
      break
    }
  }
  String::unsafe_substring(s, start~, end~)
}

///|
fn resolve_worktree_common_git_dir(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = join_path(git_dir, "commondir")
  if not(fs.is_file(commondir_path)) {
    return git_dir
  }
  let raw = @utf8.decode_lossy(
    (fs.read_file(commondir_path) catch { _ => Bytes::default() })[:],
  )
  let rel = trim_worktree_text(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(join_path(git_dir, rel))
  }
}

///|
fn collect_staged_changes_from_head(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  index_map : Map[String, IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise @git.GitError {
  let head = resolve_head_commit(fs, git_dir)
  match head {
    None => return
    Some(commit_id) => {
      let common_git_dir = resolve_worktree_common_git_dir(fs, git_dir)
      let db = ObjectDb::load_lazy(fs, common_git_dir)
      let commit_obj = db.get(fs, commit_id)
      match commit_obj {
        None => return
        Some(obj) => {
          if obj.obj_type != @git.ObjectType::Commit {
            raise @git.GitError::InvalidObject("Object is not a commit")
          }
          let info = @git.parse_commit(obj.data)
          collect_staged_changes_db(
            db,
            fs,
            info.tree,
            "",
            index_map,
            staged_modified,
            staged_deleted,
          )
        }
      }
    }
  }
}

///|
fn collect_staged_changes_db(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  index_map : Map[String, IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise @git.GitError {
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None => raise @git.GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != @git.ObjectType::Tree {
        raise @git.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @git.parse_tree(obj.data)
      for entry in entries {
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if is_tree_mode(entry.mode) {
          collect_staged_changes_db(
            db,
            fs,
            entry.id,
            path,
            index_map,
            staged_modified,
            staged_deleted,
          )
        } else {
          let mode = worktree_parse_octal(entry.mode)
          match index_map.get(path) {
            Some(index_entry) => {
              if index_entry.id != entry.id || index_entry.mode != mode {
                staged_modified.push(path)
              }
              index_map.remove(path)
            }
            None => staged_deleted.push(path)
          }
        }
      }
    }
  }
}

///|
fn worktree_parse_octal(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
/// Commit with amend (replace the last commit).
pub fn commit_amend(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer? : String = author,
  committer_timestamp? : Int64 = author_timestamp,
) -> @git.ObjectId raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let entries = read_index_entries(rfs, actual_git_dir)
  if entries.length() == 0 {
    raise @git.GitError::InvalidObject("Empty index")
  }
  let tree_id = write_tree_from_index(fs, actual_git_dir, entries)
  // Get the parent of the current HEAD (grandparent of new commit)
  let current_head = resolve_head_commit(rfs, actual_git_dir)
  let parents = match current_head {
    Some(head_id) => {
      // Get parent of current HEAD
      let db = ObjectDb::load(rfs, actual_git_dir)
      let obj = db.get(rfs, head_id)
      match obj {
        Some(o) => {
          let info = @git.parse_commit(o.data)
          info.parents
        }
        None => []
      }
    }
    None => []
  }
  let commit = @git.Commit::new(
    tree_id, parents, author, author_timestamp, "+0000", committer, committer_timestamp,
    "+0000", message,
  )
  let (commit_id, compressed) = @git.create_commit(commit)
  write_object_bytes(fs, actual_git_dir, commit_id, compressed)
  update_head_ref(fs, rfs, actual_git_dir, commit_id)
  commit_id
}

///|
/// Remove files from index (and optionally working tree).
pub fn rm_paths(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
  cached? : Bool = false,
  force? : Bool = false,
  recursive? : Bool = false,
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let entries = read_index_entries(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = {}
  for e in entries {
    map[e.path] = e
  }
  // Expand paths if recursive
  let all_paths = if recursive {
    expand_rm_paths(rfs, root, paths, map)
  } else {
    paths
  }
  ignore(force)
  for path in all_paths {
    let norm_path = normalize_rel_path(path)
    // Remove from index
    map.remove(norm_path)
    // Remove from working tree unless --cached
    if not(cached) {
      let abs = join_path(root, norm_path)
      if rfs.is_file(abs) {
        fs.remove_file(abs)
      }
    }
  }
  let out : Array[IndexEntry] = []
  for item in map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  write_index_entries(fs, actual_git_dir, out)
}

///|
fn expand_rm_paths(
  rfs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
  index_map : Map[String, IndexEntry],
) -> Array[String] {
  let result : Array[String] = []
  for p in paths {
    let norm_path = normalize_rel_path(p)
    let abs = join_path(root, norm_path)
    if rfs.is_dir(abs) {
      // Add all index entries under this directory
      let prefix = if norm_path.has_suffix("/") {
        norm_path
      } else {
        norm_path + "/"
      }
      for item in index_map.to_array() {
        let (entry_path, _) = item
        if entry_path.has_prefix(prefix) || entry_path == norm_path {
          result.push(entry_path)
        }
      }
    } else {
      result.push(norm_path)
    }
  }
  result
}

///|
/// Move/rename a file in the index and working tree.
pub fn mv_path(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  source : String,
  dest : String,
  force? : Bool = false,
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let src_norm = normalize_rel_path(source)
  let dst_norm = normalize_rel_path(dest)
  let src_abs = join_path(root, src_norm)
  let dst_abs = join_path(root, dst_norm)
  // Check source exists
  if not(rfs.is_file(src_abs)) {
    raise @git.GitError::InvalidObject("source '\{source}' does not exist")
  }
  // Check dest doesn't exist (unless force)
  if rfs.is_file(dst_abs) && not(force) {
    raise @git.GitError::InvalidObject("destination '\{dest}' already exists")
  }
  // Read index
  let entries = read_index_entries(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = {}
  for e in entries {
    map[e.path] = e
  }
  // Find source entry
  guard map.get(src_norm) is Some(src_entry) else {
    raise @git.GitError::InvalidObject("'\{source}' not in index")
  }
  // Remove source, add dest
  map.remove(src_norm)
  map[dst_norm] = {
    path: dst_norm,
    id: src_entry.id,
    mode: src_entry.mode,
    size: src_entry.size,
    mtime_sec: src_entry.mtime_sec,
    mtime_nsec: src_entry.mtime_nsec,
  }
  // Move file on disk
  let content = rfs.read_file(src_abs)
  fs.write_file(dst_abs, content)
  fs.remove_file(src_abs)
  // Write index
  let out : Array[IndexEntry] = []
  for item in map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  write_index_entries(fs, actual_git_dir, out)
}
