///| Git diff helpers

///|
pub enum DiffKind {
  Added
  Modified
  Deleted
}

///|
pub struct DiffFile {
  path : String
  kind : DiffKind
  old_content : Bytes?
  new_content : Bytes?
  old_mode : Int?
  new_mode : Int?
}

///|
/// Diff working tree against index (default `git diff`).
pub async fn diff_worktree(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[DiffFile] raise @git.GitError {
  let profile = profile_enabled()
  let mut t0 = profile_start(profile)
  let git_dir = join_path(root, ".git")
  let autocrlf = read_autocrlf_setting(fs, git_dir)
  let index_entries = read_index_entries(fs, git_dir)
  t0 = profile_lap(profile, "diff_worktree read_index_entries", t0)
  let db = ObjectDb::load_lazy(fs, git_dir)
  t0 = profile_lap(profile, "diff_worktree load_db", t0)
  let cached_files = working_files_cache(root)
  let cache_map : Map[String, Bool] = {}
  let mut cache_ready = false
  match cached_files {
    Some(files) => {
      cache_ready = true
      for p in files {
        cache_map[p] = true
      }
    }
    None => ()
  }
  let out : Array[DiffFile] = []
  for entry in index_entries {
    let path = entry.path
    if is_gitlink_mode_int(entry.mode) {
      continue
    }
    if cache_ready && not(cache_map.contains(path)) {
      let ignored = is_ignored_path(fs, root, path, false)
      if not(ignored) {
        let old = diff_read_blob(db, fs, entry.id)
        // Skip if blob not found (e.g., submodule)
        if old is Some(_) {
          out.push({
            path,
            kind: DiffKind::Deleted,
            old_content: old,
            new_content: None,
            old_mode: Some(entry.mode),
            new_mode: None,
          })
        }
        continue
      }
    }
    let abs = join_path(root, path)
    match worktree_entry_meta(fs, abs) {
      None => {
        let old = diff_read_blob(db, fs, entry.id)
        // Skip if blob not found (e.g., submodule)
        if old is Some(_) {
          out.push({
            path,
            kind: DiffKind::Deleted,
            old_content: old,
            new_content: None,
            old_mode: Some(entry.mode),
            new_mode: None,
          })
        }
      }
      Some(info) => {
        let mut content_changed = false
        let mode_changed = info.mode != entry.mode
        let mut old_content : Bytes? = None
        let mut new_content : Bytes? = None
        match info.kind {
          WorktreeKindMeta::Regular => {
            let mut stat_matches = false
            match info.size {
              Some(sz) =>
                match info.mtime_sec {
                  Some(ms) =>
                    match info.mtime_nsec {
                      Some(mn) =>
                        if entry.mtime_sec != 0 || entry.mtime_nsec != 0 {
                          stat_matches = sz == entry.size &&
                            ms == entry.mtime_sec &&
                            mn == entry.mtime_nsec
                        }
                      None => ()
                    }
                  None => ()
                }
              None => ()
            }
            if not(mode_changed) && stat_matches {
              content_changed = false
            } else {
              let content = fs.read_file(abs)
              let normalized = normalize_worktree_content(content, autocrlf)
              let id = @git.hash_blob(normalized)
              content_changed = id != entry.id
              if content_changed {
                let old = diff_read_blob(db, fs, entry.id)
                if old is Some(_) {
                  old_content = old
                  new_content = Some(normalized)
                }
              }
            }
          }
          WorktreeKindMeta::Symlink => {
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
            if not(mode_changed) && stat_matches {
              content_changed = false
            } else {
              match read_symlink_target_path(abs) {
                Some(target) => {
                  let bytes = @utf8.encode(target)
                  let id = @git.hash_blob(bytes)
                  content_changed = id != entry.id
                  if content_changed {
                    let old = diff_read_blob(db, fs, entry.id)
                    if old is Some(_) {
                      old_content = old
                      new_content = Some(bytes)
                    }
                  }
                }
                None => ()
              }
            }
          }
        }
        if content_changed && old_content is None {
          continue
        }
        if content_changed || mode_changed {
          out.push({
            path,
            kind: DiffKind::Modified,
            old_content,
            new_content,
            old_mode: Some(entry.mode),
            new_mode: Some(info.mode),
          })
        }
      }
    }
  }
  t0 = profile_lap(profile, "diff_worktree scan_entries", t0)
  out.sort_by((a, b) => String::compare(a.path, b.path))
  ignore(profile_lap(profile, "diff_worktree sort", t0))
  out
}

///|
/// Diff index against HEAD (`git diff --cached`).
pub fn diff_index(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[DiffFile] raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let index_entries = read_index_entries(fs, git_dir)
  let index_map : Map[String, IndexEntry] = {}
  for e in index_entries {
    index_map[e.path] = e
  }
  let head_entries = diff_read_head_entries(fs, git_dir)
  let db = ObjectDb::load_lazy(fs, git_dir)
  let out : Array[DiffFile] = []
  for item in index_map.to_array() {
    let (path, entry) = item
    match head_entries.get(path) {
      None => {
        let new = diff_read_blob(db, fs, entry.id)
        // Skip if blob not found (e.g., submodule)
        if new is Some(_) {
          out.push({
            path,
            kind: DiffKind::Added,
            old_content: None,
            new_content: new,
            old_mode: None,
            new_mode: Some(entry.mode),
          })
        }
      }
      Some(h) =>
        if h.id != entry.id || h.mode != entry.mode {
          let content_changed = h.id != entry.id
          let mut old : Bytes? = None
          let mut new : Bytes? = None
          if content_changed {
            old = diff_read_blob(db, fs, h.id)
            new = diff_read_blob(db, fs, entry.id)
            // Skip if either blob not found (e.g., submodule)
            if old is None || new is None {
              continue
            }
          }
          out.push({
            path,
            kind: DiffKind::Modified,
            old_content: old,
            new_content: new,
            old_mode: Some(h.mode),
            new_mode: Some(entry.mode),
          })
        }
    }
  }
  for item in head_entries.to_array() {
    let (path, h) = item
    if not(index_map.contains(path)) {
      let old = diff_read_blob(db, fs, h.id)
      // Skip if blob not found (e.g., submodule)
      if old is Some(_) {
        out.push({
          path,
          kind: DiffKind::Deleted,
          old_content: old,
          new_content: None,
          old_mode: Some(h.mode),
          new_mode: None,
        })
      }
    }
  }
  out.sort_by((a, b) => String::compare(a.path, b.path))
  out
}

///|
/// Format diff as simple unified-like text.
pub fn diff_text(files : Array[DiffFile]) -> Array[String] {
  let lines : Array[String] = []
  for f in files {
    lines.push("diff --git a/\{f.path} b/\{f.path}")
    diff_emit_modes(lines, f)
    match f.kind {
      Added => {
        lines.push("--- /dev/null")
        lines.push("+++ b/\{f.path}")
        match f.new_content {
          Some(data) => diff_emit_lines(lines, data, "+")
          None => ()
        }
      }
      Deleted => {
        lines.push("--- a/\{f.path}")
        lines.push("+++ /dev/null")
        match f.old_content {
          Some(data) => diff_emit_lines(lines, data, "-")
          None => ()
        }
      }
      Modified =>
        match (f.old_content, f.new_content) {
          (Some(old), Some(new)) => {
            lines.push("--- a/\{f.path}")
            lines.push("+++ b/\{f.path}")
            diff_emit_lines(lines, old, "-")
            diff_emit_lines(lines, new, "+")
          }
          _ => ()
        }
    }
  }
  lines
}

///|
fn diff_emit_modes(out : Array[String], f : DiffFile) -> Unit {
  match f.kind {
    Added =>
      match f.new_mode {
        Some(mode) => out.push("new file mode " + mode_to_string(mode))
        None => ()
      }
    Deleted =>
      match f.old_mode {
        Some(mode) => out.push("deleted file mode " + mode_to_string(mode))
        None => ()
      }
    Modified =>
      match (f.old_mode, f.new_mode) {
        (Some(old), Some(new)) if old != new => {
          out.push("old mode " + mode_to_string(old))
          out.push("new mode " + mode_to_string(new))
        }
        _ => ()
      }
  }
}

///|
fn diff_emit_lines(out : Array[String], data : Bytes, prefix : String) -> Unit {
  let text = @utf8.decode_lossy(data[:])
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    out.push(prefix + line)
  }
}

///|
/// Format diff as stat summary (like git diff --stat).
pub fn diff_stat(files : Array[DiffFile]) -> Array[String] {
  let lines : Array[String] = []
  let mut total_add = 0
  let mut total_del = 0
  let mut max_name_len = 0
  for f in files {
    if f.path.length() > max_name_len {
      max_name_len = f.path.length()
    }
  }
  for f in files {
    let (add, del) = count_line_changes(f.old_content, f.new_content)
    total_add = total_add + add
    total_del = total_del + del
    let total = add + del
    let bar_len = if total > 50 { 50 } else { total }
    let add_bar = "+".repeat(if total > 0 { add * bar_len / total } else { 0 })
    let del_bar = "-".repeat(if total > 0 { del * bar_len / total } else { 0 })
    let padding = " ".repeat(max_name_len - f.path.length())
    lines.push(" \{f.path}\{padding} | \{total} \{add_bar}\{del_bar}")
  }
  if files.length() > 0 {
    let files_changed = files.length()
    lines.push(
      " \{files_changed} file(s) changed, \{total_add} insertions(+), \{total_del} deletions(-)",
    )
  }
  lines
}

///|
fn count_line_changes(old : Bytes?, new : Bytes?) -> (Int, Int) {
  let old_lines = match old {
    Some(data) => count_lines(data)
    None => 0
  }
  let new_lines = match new {
    Some(data) => count_lines(data)
    None => 0
  }
  if new_lines >= old_lines {
    (new_lines - old_lines, 0)
  } else {
    (0, old_lines - new_lines)
  }
}

///|
fn count_lines(data : Bytes) -> Int {
  let mut count = 0
  for b in data {
    if b == b'\n' {
      count = count + 1
    }
  }
  if data.length() > 0 && data[data.length() - 1] != b'\n' {
    count = count + 1
  }
  count
}

///|
fn diff_read_blob(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> Bytes? raise @git.GitError {
  let obj = db.get(fs, id)
  match obj {
    None => None // Object might be in a submodule or unavailable
    Some(o) =>
      if o.obj_type != @git.ObjectType::Blob {
        None // Submodule entries point to commits, not blobs
      } else {
        Some(o.data)
      }
  }
}

///|
priv struct DiffHeadEntry {
  id : @git.ObjectId
  mode : Int
}

///|
fn diff_read_head_entries(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Map[String, DiffHeadEntry] raise @git.GitError {
  let result : Map[String, DiffHeadEntry] = {}
  let head = resolve_head_commit(fs, git_dir)
  match head {
    None => return result
    Some(commit_id) => {
      let db = ObjectDb::load(fs, git_dir)
      let commit_obj = db.get(fs, commit_id)
      match commit_obj {
        None => return result
        Some(obj) => {
          if obj.obj_type != @git.ObjectType::Commit {
            raise @git.GitError::InvalidObject("Object is not a commit")
          }
          let info = @git.parse_commit(obj.data)
          diff_collect_tree(db, fs, info.tree, "", result)
        }
      }
    }
  }
  result
}

///|
fn diff_collect_tree(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  out : Map[String, DiffHeadEntry],
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
        if diff_is_tree_mode(entry.mode) {
          diff_collect_tree(db, fs, entry.id, path, out)
        } else {
          out[path] = { id: entry.id, mode: worktree_parse_octal(entry.mode) }
        }
      }
    }
  }
}

///|
fn diff_is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}

///|
/// Diff two trees by their ObjectIds. Returns DiffFile array.
pub fn diff_trees(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  old_tree : @git.ObjectId?,
  new_tree : @git.ObjectId,
) -> Array[DiffFile] raise @git.GitError {
  let db = ObjectDb::load(fs, git_dir)
  let out : Array[DiffFile] = []
  let old_entries : Map[String, DiffHeadEntry] = {}
  let new_entries : Map[String, DiffHeadEntry] = {}
  match old_tree {
    Some(ot) => diff_collect_tree(db, fs, ot, "", old_entries)
    None => ()
  }
  diff_collect_tree(db, fs, new_tree, "", new_entries)
  // Added and modified
  for path, entry in new_entries {
    match old_entries.get(path) {
      None => {
        let new_content = diff_read_blob(db, fs, entry.id)
        if new_content is Some(_) {
          out.push({
            path,
            kind: DiffKind::Added,
            old_content: None,
            new_content,
            old_mode: None,
            new_mode: Some(entry.mode),
          })
        }
      }
      Some(old_entry) =>
        if old_entry.id != entry.id || old_entry.mode != entry.mode {
          let old_content = diff_read_blob(db, fs, old_entry.id)
          let new_content = diff_read_blob(db, fs, entry.id)
          out.push({
            path,
            kind: DiffKind::Modified,
            old_content,
            new_content,
            old_mode: Some(old_entry.mode),
            new_mode: Some(entry.mode),
          })
        }
    }
  }
  // Deleted
  for path, entry in old_entries {
    if not(new_entries.contains(path)) {
      let old_content = diff_read_blob(db, fs, entry.id)
      if old_content is Some(_) {
        out.push({
          path,
          kind: DiffKind::Deleted,
          old_content,
          new_content: None,
          old_mode: Some(entry.mode),
          new_mode: None,
        })
      }
    }
  }
  out.sort_by(fn(a, b) { String::compare(a.path, b.path) })
  out
}
