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
        let exec = @afs.can_execute(abs_path) catch { _ => false }
        let mode = if exec { 0o100755 } else { 0o100644 }
        Some({ kind: WorktreeKind::Regular, mode })
      } else {
        None
      }
  }
}

///|
async fn try_readlink(path : String) -> String? raise @git.GitError {
  let (code, stdout, stderr) = @process.collect_output(
    "readlink",
    [path],
    inherit_env=true,
  ) catch {
    err => raise @git.GitError::IoError(err.to_string())
  }
  if code != 0 {
    ignore(stderr)
    return None
  }
  let text = stdout.text() catch { _ => "" }
  Some(text.trim_end().to_string())
}
