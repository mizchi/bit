///|
fn cleanup_scalar_test_dir(fs : OsFs, path : String) -> Unit {
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let full = path + "/" + entry
    if fs.is_dir(full) {
      cleanup_scalar_test_dir(fs, full)
    } else {
      fs.remove_file(full) catch {
        _ => ()
      }
    }
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
test "scalar: resolve register path from enlistment root" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-scalar-resolve-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/work/src/.git")
  let resolved = scalar_resolve_register_repo_path(fs, root + "/work")
  assert_eq(resolved, root + "/work/src")
  cleanup_scalar_test_dir(fs, root)
}

///|
test "scalar: register + unregister maintenance repo entries" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-scalar-config-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root)
  let prev_global = @sys.get_env_var("GIT_CONFIG_GLOBAL")
  let config_path = root + "/global.gitconfig"
  @sys.set_env_var("GIT_CONFIG_GLOBAL", config_path)
  scalar_add_maintenance_repo(fs, "/tmp/repo-a")
  scalar_add_maintenance_repo(fs, "/tmp/repo-b")
  let listed = scalar_list_maintenance_repos(fs)
  assert_eq(listed.length(), 2)
  assert_eq(listed[0], "/tmp/repo-a")
  assert_eq(listed[1], "/tmp/repo-b")
  scalar_remove_maintenance_repo(fs, "/tmp/repo-a")
  let listed2 = scalar_list_maintenance_repos(fs)
  assert_eq(listed2.length(), 1)
  assert_eq(listed2[0], "/tmp/repo-b")
  match prev_global {
    Some(path) => @sys.set_env_var("GIT_CONFIG_GLOBAL", path)
    None => @sys.unset_env_var("GIT_CONFIG_GLOBAL")
  }
  cleanup_scalar_test_dir(fs, root)
}

///|
test "scalar: clone option parser handles scalar-only flags" {
  let parsed = scalar_parse_clone_options([
    "--full-clone",
    "--no-src",
    "--no-tags",
    "--no-maintenance",
    "--single-branch",
    "https://example.com/repo.git",
    "dst",
  ])
  assert_true(parsed.full_clone)
  assert_false(parsed.src)
  assert_false(parsed.tags)
  assert_false(parsed.maintenance)
  assert_eq(parsed.clone_opts.length(), 1)
  assert_eq(parsed.clone_opts[0], "--single-branch")
  assert_eq(parsed.positional.length(), 2)
  assert_eq(parsed.positional[0], "https://example.com/repo.git")
  assert_eq(parsed.positional[1], "dst")
}

///|
test "scalar: clone option parser keeps --branch value out of positional args" {
  let parsed = scalar_parse_clone_options([
    "--branch",
    "main",
    "--single-branch",
    "https://example.com/repo.git",
    "dst",
  ])
  assert_eq(parsed.clone_opts.length(), 3)
  assert_eq(parsed.clone_opts[0], "--branch")
  assert_eq(parsed.clone_opts[1], "main")
  assert_eq(parsed.clone_opts[2], "--single-branch")
  assert_eq(parsed.positional.length(), 2)
  assert_eq(parsed.positional[0], "https://example.com/repo.git")
  assert_eq(parsed.positional[1], "dst")
}
