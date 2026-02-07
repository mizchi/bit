///|
test "helpers: resolve_git_dir falls back to bare repo when GIT_DIR points missing .git" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-resolve-git-dir-bare-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/objects")
  fs.write_string(root + "/HEAD", "ref: refs/heads/main\n")

  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  @sys.set_env_var("GIT_DIR", root + "/.git")

  let resolved = resolve_git_dir(fs, root)
  assert_eq(resolved, root)

  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }

  fs.remove_file(root + "/HEAD") catch {
    _ => ()
  }
  fs.remove_dir(root + "/objects") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}
