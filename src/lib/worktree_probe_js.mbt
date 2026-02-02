///|
/// Worktree probe helpers (JS target: no symlink/exec support)

///|
priv enum WorktreeKind {
  Regular
  Symlink(target~ : String)
}

///|
priv struct WorktreeEntry {
  kind : WorktreeKind
  mode : Int
}

///|
async fn worktree_entry(
  fs : &@git.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntry? raise @git.GitError {
  match try_readlink(abs_path) {
    Some(target) =>
      Some({ kind: WorktreeKind::Symlink(target=target), mode: 0o120000 })
    None =>
      if fs.is_file(abs_path) {
        Some({ kind: WorktreeKind::Regular, mode: 0o100644 })
      } else {
        None
      }
  }
}

///|
async fn try_readlink(path : String) -> String? raise @git.GitError {
  ignore(path)
  @async.sleep(0) catch {
    err => raise @git.GitError::IoError(err.to_string())
  }
  None
}
