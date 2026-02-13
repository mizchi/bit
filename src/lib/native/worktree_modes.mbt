///| Worktree mode normalization (symlink/executable)

///|
pub async fn apply_worktree_modes_from_commit(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let files = @gitlib.collect_tree_files_from_commit(db, rfs, commit_id)
  apply_worktree_modes_from_files(db, rfs, fs, root, git_dir, files)
}

///|
async fn apply_worktree_modes_from_files(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  fs : &@git.FileSystem,
  root : String,
  git_dir : String,
  files : Map[String, @gitlib.TreeFileEntry],
) -> Unit raise @git.GitError {
  let items = files.to_array()
  items.sort_by((left, right) => {
    let (left_path, _) = left
    let (right_path, _) = right
    String::compare(left_path, right_path)
  })
  let paths : Array[String] = []
  for item in items {
    let (path, _) = item
    paths.push(path)
  }
  let skip_paths = detect_case_insensitive_collision_skips(
    fs, rfs, git_dir, paths,
  )
  for item in items {
    let (path, info) = item
    if skip_paths.contains(path) {
      continue
    }
    let full_path = worktree_modes_join_path(root, path)
    if is_gitlink_mode_int(info.mode) {
      fs.mkdir_p(full_path)
      continue
    }
    if is_symlink_mode_int(info.mode) {
      let target = read_symlink_target(db, rfs, info.id)
      apply_symlink(full_path, target)
      continue
    }
    if is_regular_file_mode_int(info.mode) {
      if is_executable_mode_int(info.mode) {
        apply_file_mode(full_path, 0o755)
      } else {
        apply_file_mode(full_path, 0o644)
      }
    }
  }
}

///|
fn read_symlink_target(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> String raise @git.GitError {
  let obj = db.get(rfs, id)
  match obj {
    None => raise @git.GitError::InvalidObject("Missing blob object")
    Some(o) => {
      if o.obj_type != @git.ObjectType::Blob {
        raise @git.GitError::InvalidObject("Object is not a blob")
      }
      @utf8.decode_lossy(o.data[:])
    }
  }
}

///|
fn worktree_is_case_insensitive(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Bool raise @git.GitError {
  let lower_path = if git_dir.has_suffix("/") {
    git_dir + "bit-case-probe-9fcb2c2d"
  } else {
    git_dir + "/bit-case-probe-9fcb2c2d"
  }
  let upper_path = if git_dir.has_suffix("/") {
    git_dir + "BIT-CASE-PROBE-9FCB2C2D"
  } else {
    git_dir + "/BIT-CASE-PROBE-9FCB2C2D"
  }
  if rfs.is_file(lower_path) ||
    rfs.is_dir(lower_path) ||
    rfs.is_file(upper_path) ||
    rfs.is_dir(upper_path) {
    return false
  }
  fs.write_string(lower_path, "1")
  let insensitive = rfs.is_file(upper_path)
  if rfs.is_file(lower_path) {
    fs.remove_file(lower_path)
  }
  insensitive
}

///|
fn detect_case_insensitive_collision_skips(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  paths : Array[String],
) -> Map[String, Bool] raise @git.GitError {
  let skip : Map[String, Bool] = {}
  if not(worktree_is_case_insensitive(fs, rfs, git_dir)) {
    return skip
  }
  let mut i = 0
  while i < paths.length() {
    let left = paths[i]
    let left_fold = left.to_lower()
    let mut j = i + 1
    while j < paths.length() {
      let right = paths[j]
      let right_fold = right.to_lower()
      if left_fold == right_fold {
        skip[right] = true
      } else {
        let right_prefix = right_fold + "/"
        let left_prefix = left_fold + "/"
        if left_fold.has_prefix(right_prefix) {
          skip[right] = true
        } else if right_fold.has_prefix(left_prefix) {
          skip[left] = true
        }
      }
      j += 1
    }
    i += 1
  }
  skip
}

///|
async fn apply_symlink(
  path : String,
  target : String,
) -> Unit raise @git.GitError {
  remove_path_if_exists(path)
  @afs.symlink(target~, path) catch {
    err => raise @git.GitError::IoError(err.to_string())
  }
}

///|
async fn apply_file_mode(path : String, mode : Int) -> Unit raise @git.GitError {
  @afs.chmod(path, mode) catch {
    err => raise @git.GitError::IoError(err.to_string())
  }
}

///|
async fn remove_path_if_exists(path : String) -> Unit raise @git.GitError {
  let exists = @afs.exists(path) catch {
    err if @async.is_cancellation_error(err) => abort("cancelled")
    _ => false
  }
  if not(exists) {
    return
  }
  let kind_result : Result[@afs.FileKind, Error] = try? @afs.kind(
    path,
    follow_symlink=false,
  )
  match kind_result {
    Ok(kind) =>
      match kind {
        @afs.FileKind::Directory =>
          @afs.rmdir(path, recursive=true) catch {
            err => raise @git.GitError::IoError(err.to_string())
          }
        _ =>
          @afs.remove(path) catch {
            err => raise @git.GitError::IoError(err.to_string())
          }
      }
    Err(_) =>
      @afs.remove(path) catch {
        err => raise @git.GitError::IoError(err.to_string())
      }
  }
}

///|

///|
fn is_executable_mode_int(mode : Int) -> Bool {
  mode == 0o100755
}

///|
fn is_symlink_mode_int(mode : Int) -> Bool {
  mode == 0o120000
}

///|
fn is_regular_file_mode_int(mode : Int) -> Bool {
  mode == 0o100644 || mode == 0o100755
}

///|
fn is_gitlink_mode_int(mode : Int) -> Bool {
  mode == 0o160000
}

///|
fn worktree_modes_join_path(root : String, path : String) -> String {
  if root.has_suffix("/") {
    root + path
  } else {
    root + "/" + path
  }
}
