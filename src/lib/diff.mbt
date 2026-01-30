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
}

///|
/// Diff working tree against index (default `git diff`).
pub fn diff_worktree(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[DiffFile] raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let index_entries = read_index_entries(fs, git_dir)
  let index_map : Map[String, IndexEntry] = {}
  for e in index_entries {
    index_map[e.path] = e
  }
  let db = ObjectDb::load(fs, git_dir)
  let files = list_working_files(fs, root)
  let out : Array[DiffFile] = []
  let seen : Map[String, Bool] = {}
  for path in files {
    seen[path] = true
    // Only diff files that are in the index (skip untracked files)
    match index_map.get(path) {
      None => () // untracked files are not shown in `git diff`
      Some(entry) => {
        let abs = join_path(root, path)
        let content = fs.read_file(abs)
        let id = @git.hash_blob(content)
        if id != entry.id {
          let old = diff_read_blob(db, fs, entry.id)
          out.push({
            path,
            kind: DiffKind::Modified,
            old_content: Some(old),
            new_content: Some(content),
          })
        }
      }
    }
  }
  for item in index_map.to_array() {
    let (path, entry) = item
    if not(seen.contains(path)) {
      let abs = join_path(root, path)
      if not(fs.is_file(abs)) {
        let old = diff_read_blob(db, fs, entry.id)
        out.push({
          path,
          kind: DiffKind::Deleted,
          old_content: Some(old),
          new_content: None,
        })
      }
    }
  }
  out.sort_by(fn(a, b) { String::compare(a.path, b.path) })
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
  let db = ObjectDb::load(fs, git_dir)
  let out : Array[DiffFile] = []
  for item in index_map.to_array() {
    let (path, entry) = item
    match head_entries.get(path) {
      None => {
        let new = diff_read_blob(db, fs, entry.id)
        out.push({
          path,
          kind: DiffKind::Added,
          old_content: None,
          new_content: Some(new),
        })
      }
      Some(h) =>
        if h.id != entry.id {
          let old = diff_read_blob(db, fs, h.id)
          let new = diff_read_blob(db, fs, entry.id)
          out.push({
            path,
            kind: DiffKind::Modified,
            old_content: Some(old),
            new_content: Some(new),
          })
        }
    }
  }
  for item in head_entries.to_array() {
    let (path, h) = item
    if not(index_map.contains(path)) {
      let old = diff_read_blob(db, fs, h.id)
      out.push({
        path,
        kind: DiffKind::Deleted,
        old_content: Some(old),
        new_content: None,
      })
    }
  }
  out.sort_by(fn(a, b) { String::compare(a.path, b.path) })
  out
}

///|
/// Format diff as simple unified-like text.
pub fn diff_text(files : Array[DiffFile]) -> Array[String] {
  let lines : Array[String] = []
  for f in files {
    lines.push("diff --git a/\{f.path} b/\{f.path}")
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
      Modified => {
        lines.push("--- a/\{f.path}")
        lines.push("+++ b/\{f.path}")
        match (f.old_content, f.new_content) {
          (Some(old), Some(new)) => {
            diff_emit_lines(lines, old, "-")
            diff_emit_lines(lines, new, "+")
          }
          _ => ()
        }
      }
    }
  }
  lines
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
fn diff_read_blob(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> Bytes raise @git.GitError {
  let obj = db.get(fs, id)
  match obj {
    None => raise @git.GitError::InvalidObject("Missing blob object")
    Some(o) => {
      if o.obj_type != @git.ObjectType::Blob {
        raise @git.GitError::InvalidObject("Object is not a blob")
      }
      o.data
    }
  }
}

///|
priv struct DiffHeadEntry {
  id : @git.ObjectId
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
          out[path] = { id: entry.id }
        }
      }
    }
  }
}

///|
fn diff_is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}
