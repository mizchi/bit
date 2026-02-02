///| Worktree mode normalization (symlink/executable)

///|
pub async fn apply_worktree_modes_from_commit(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let db = ObjectDb::load(rfs, git_dir)
  let files = collect_tree_files_from_commit(db, rfs, commit_id)
  apply_worktree_modes_from_files(db, rfs, fs, root, files)
}

///|
async fn apply_worktree_modes_from_files(
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  fs : &@git.FileSystem,
  root : String,
  files : Map[String, TreeFileEntry],
) -> Unit raise @git.GitError {
  for item in files.to_array() {
    let (path, info) = item
    let full_path = join_path(root, path)
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
  db : ObjectDb,
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
async fn apply_symlink(path : String, target : String) -> Unit raise @git.GitError {
  remove_path_if_exists(path)
  @afs.symlink(target=target, path) catch {
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
  let exists = @afs.exists(path) catch { _ => false }
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
