///| Tree helpers for checkout/reset/merge

///|
pub struct TreeFileEntry {
  id : @git.ObjectId
  mode : Int
}

///|
pub fn collect_tree_files(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Map[String, TreeFileEntry] raise @git.GitError {
  let out : Map[String, TreeFileEntry] = {}
  collect_tree_files_inner(db, fs, tree_id, "", out)
  out
}

///|
pub fn collect_tree_files_from_commit(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> Map[String, TreeFileEntry] raise @git.GitError {
  let commit_obj = db.get(fs, commit_id)
  match commit_obj {
    None => raise @git.GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != @git.ObjectType::Commit {
        raise @git.GitError::InvalidObject("Object is not a commit")
      }
      let info = @git.parse_commit(obj.data)
      collect_tree_files(db, fs, info.tree)
    }
  }
}

///|
pub fn tree_files_to_index(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  files : Map[String, TreeFileEntry],
) -> Array[IndexEntry] raise @git.GitError {
  let entries : Array[IndexEntry] = []
  for item in files.to_array() {
    let (path, info) = item
    if is_gitlink_mode_int(info.mode) {
      entries.push({
        path,
        id: info.id,
        mode: info.mode,
        size: 0,
        mtime_sec: 0,
        mtime_nsec: 0,
      })
      continue
    }
    let obj = db.get(fs, info.id)
    match obj {
      None =>
        raise @git.GitError::InvalidObject(
          "Missing blob object: " + info.id.to_hex(),
        )
      Some(o) => {
        if o.obj_type != @git.ObjectType::Blob {
          raise @git.GitError::InvalidObject("Object is not a blob")
        }
        entries.push({
          path,
          id: info.id,
          mode: info.mode,
          size: o.data.length(),
          mtime_sec: 0,
          mtime_nsec: 0,
        })
      }
    }
  }
  entries.sort_by((a, b) => String::compare(a.path, b.path))
  entries
}

///|
pub fn write_worktree_from_files(
  db : ObjectDb,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  files : Map[String, TreeFileEntry],
  remove_missing? : Bool = false,
) -> Unit raise @git.GitError {
  if remove_missing {
    let entries = read_index_entries(rfs, git_dir)
    for entry in entries {
      if not(files.contains(entry.path)) {
        let path = join_path(root, entry.path)
        if rfs.is_file(path) {
          fs.remove_file(path)
        }
      }
    }
  }
  for item in files.to_array() {
    let (path, info) = item
    if is_gitlink_mode_int(info.mode) {
      let full_path = join_path(root, path)
      fs.mkdir_p(full_path)
      continue
    }
    let full_path = join_path(root, path)
    if rfs.is_dir(full_path) {
      let git_marker = join_path(full_path, ".git")
      if rfs.is_file(git_marker) || rfs.is_dir(git_marker) {
        raise @git.GitError::InvalidObject(
          "Refusing to overwrite submodule: \{path}",
        )
      }
    }
    let obj = db.get(rfs, info.id)
    match obj {
      None =>
        raise @git.GitError::InvalidObject(
          "Missing blob object: " + info.id.to_hex(),
        )
      Some(o) => {
        if o.obj_type != @git.ObjectType::Blob {
          raise @git.GitError::InvalidObject("Object is not a blob")
        }
        let full_path = join_path(root, path)
        let dir = parent_dir(full_path)
        fs.mkdir_p(dir)
        fs.write_file(full_path, o.data)
      }
    }
  }
}

///|
/// Combined worktree write + index build — reads each blob only once.
pub fn write_worktree_and_build_index(
  db : ObjectDb,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  files : Map[String, TreeFileEntry],
  remove_missing? : Bool = false,
) -> Array[IndexEntry] raise @git.GitError {
  if remove_missing {
    let entries = read_index_entries(rfs, git_dir)
    for entry in entries {
      if not(files.contains(entry.path)) {
        let path = join_path(root, entry.path)
        if rfs.is_file(path) {
          fs.remove_file(path)
        }
      }
    }
  }
  let index_entries : Array[IndexEntry] = []
  for item in files.to_array() {
    let (path, info) = item
    if is_gitlink_mode_int(info.mode) {
      let full_path = join_path(root, path)
      fs.mkdir_p(full_path)
      index_entries.push({
        path,
        id: info.id,
        mode: info.mode,
        size: 0,
        mtime_sec: 0,
        mtime_nsec: 0,
      })
      continue
    }
    let full_path = join_path(root, path)
    if rfs.is_dir(full_path) {
      let git_marker = join_path(full_path, ".git")
      if rfs.is_file(git_marker) || rfs.is_dir(git_marker) {
        raise @git.GitError::InvalidObject(
          "Refusing to overwrite submodule: \{path}",
        )
      }
    }
    let obj = db.get(rfs, info.id)
    match obj {
      None =>
        raise @git.GitError::InvalidObject(
          "Missing blob object: " + info.id.to_hex(),
        )
      Some(o) => {
        if o.obj_type != @git.ObjectType::Blob {
          raise @git.GitError::InvalidObject("Object is not a blob")
        }
        let full_path = join_path(root, path)
        let dir = parent_dir(full_path)
        fs.mkdir_p(dir)
        fs.write_file(full_path, o.data)
        index_entries.push({
          path,
          id: info.id,
          mode: info.mode,
          size: o.data.length(),
          mtime_sec: 0,
          mtime_nsec: 0,
        })
      }
    }
  }
  index_entries.sort_by((a, b) => String::compare(a.path, b.path))
  index_entries
}

///|
fn collect_tree_files_inner(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  out : Map[String, TreeFileEntry],
) -> Unit raise @git.GitError {
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None =>
      raise @git.GitError::InvalidObject(
        "Missing tree object: " + tree_id.to_hex(),
      )
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
          collect_tree_files_inner(db, fs, entry.id, path, out)
        } else {
          let mode = worktree_parse_octal(entry.mode)
          out[path] = { id: entry.id, mode }
        }
      }
    }
  }
}
