///| Tests for async list_working_files behavior

///|
async test "gitignore async: symlink dir is not traversed" {
  @gitionative.init_worktree_probe()
  let fs = @osfs.OsFs::new()
  let mk = @process.collect_output(
    "mktemp",
    ["-d", "/tmp/bit_gitignore_symlink.XXXXXX"],
    inherit_env=true,
  ) catch {
    _ => return ()
  }
  let (code, stdout, _) = mk
  if code != 0 {
    return ()
  }
  let root = stdout.text() catch { _ => return () }
  let root = root.trim_end().to_string()
  fs.mkdir_p(root + "/real")
  fs.write_string(root + "/real/file.txt", "ok")
  let ln = @process.collect_output(
    "ln",
    ["-s", root + "/real", root + "/link"],
    inherit_env=true,
  ) catch {
    _ => return ()
  }
  let (ln_code, _, _) = ln
  if ln_code != 0 {
    return ()
  }
  let files = @gitlib.list_working_files_async(fs, root)
  assert_true(files.contains("real/file.txt"))
  assert_true(files.contains("link"))
  assert_true(not(files.contains("link/file.txt")))
}
