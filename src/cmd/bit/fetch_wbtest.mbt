///|
fn restore_env_var_for_fetch_wbtest(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
test "fetch-delegate: collects global path overrides in deterministic order" {
  let prev_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_explicit_git_dir = @sys.get_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  @sys.set_env_var("GIT_SHIM_CWD", "/tmp/bit-delegate-cwd")
  @sys.set_env_var("GIT_SHIM_PWD", "/tmp/bit-delegate-pwd")
  @sys.set_env_var("GIT_DIR", "/tmp/bit-delegate-gitdir")
  @sys.set_env_var("GIT_SHIM_EXPLICIT_GIT_DIR", "1")
  let args = collect_global_path_overrides_for_delegate()
  assert_eq(args.length(), 3)
  assert_eq(args[0], "-C")
  assert_eq(args[1], "/tmp/bit-delegate-cwd")
  assert_eq(args[2], "--git-dir=/tmp/bit-delegate-gitdir")
  restore_env_var_for_fetch_wbtest("GIT_SHIM_CWD", prev_cwd)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_PWD", prev_pwd)
  restore_env_var_for_fetch_wbtest("GIT_DIR", prev_git_dir)
  restore_env_var_for_fetch_wbtest(
    "GIT_SHIM_EXPLICIT_GIT_DIR", prev_explicit_git_dir,
  )
}

///|
test "fetch-delegate: falls back to GIT_SHIM_PWD when CWD is missing" {
  let prev_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_explicit_git_dir = @sys.get_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.set_env_var("GIT_SHIM_PWD", "/tmp/bit-delegate-pwd")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  let args = collect_global_path_overrides_for_delegate()
  assert_eq(args.length(), 2)
  assert_eq(args[0], "-C")
  assert_eq(args[1], "/tmp/bit-delegate-pwd")
  restore_env_var_for_fetch_wbtest("GIT_SHIM_CWD", prev_cwd)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_PWD", prev_pwd)
  restore_env_var_for_fetch_wbtest("GIT_DIR", prev_git_dir)
  restore_env_var_for_fetch_wbtest(
    "GIT_SHIM_EXPLICIT_GIT_DIR", prev_explicit_git_dir,
  )
}

///|
test "fetch-delegate: skips unset global path overrides" {
  let prev_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_explicit_git_dir = @sys.get_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  let args = collect_global_path_overrides_for_delegate()
  assert_eq(args.length(), 0)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_CWD", prev_cwd)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_PWD", prev_pwd)
  restore_env_var_for_fetch_wbtest("GIT_DIR", prev_git_dir)
  restore_env_var_for_fetch_wbtest(
    "GIT_SHIM_EXPLICIT_GIT_DIR", prev_explicit_git_dir,
  )
}

///|
test "fetch-delegate: does not append --git-dir without explicit marker" {
  let prev_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_explicit_git_dir = @sys.get_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  @sys.set_env_var("GIT_SHIM_CWD", "/tmp/bit-delegate-cwd")
  @sys.unset_env_var("GIT_SHIM_PWD")
  @sys.set_env_var("GIT_DIR", "/tmp/bit-delegate-gitdir")
  @sys.unset_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  let args = collect_global_path_overrides_for_delegate()
  assert_eq(args.length(), 2)
  assert_eq(args[0], "-C")
  assert_eq(args[1], "/tmp/bit-delegate-cwd")
  restore_env_var_for_fetch_wbtest("GIT_SHIM_CWD", prev_cwd)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_PWD", prev_pwd)
  restore_env_var_for_fetch_wbtest("GIT_DIR", prev_git_dir)
  restore_env_var_for_fetch_wbtest(
    "GIT_SHIM_EXPLICIT_GIT_DIR", prev_explicit_git_dir,
  )
}

///|
test "fetch-delegate: parses multiline -c overrides and ignores empty lines" {
  let prev_overrides = @sys.get_env_var("GIT_CONFIG_OVERRIDES")
  @sys.set_env_var(
    "GIT_CONFIG_OVERRIDES", "push.default=upstream\n\ncore.eol=lf\n",
  )
  let args = collect_global_config_overrides_for_delegate()
  assert_eq(args.length(), 4)
  assert_eq(args[0], "-c")
  assert_eq(args[1], "push.default=upstream")
  assert_eq(args[2], "-c")
  assert_eq(args[3], "core.eol=lf")
  restore_env_var_for_fetch_wbtest("GIT_CONFIG_OVERRIDES", prev_overrides)
}

///|
test "fetch-delegate: empty SHIM_REAL_GIT does not enable delegation" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  @sys.set_env_var("SHIM_REAL_GIT", "")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_false(is_real_git_delegate_enabled())
  restore_env_var_for_fetch_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "fetch-delegate: secondary real-git env enables delegation when primary empty" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  @sys.set_env_var("SHIM_REAL_GIT", "")
  @sys.set_env_var("GIT_SHIM_REAL_GIT", "/tmp/mock-git")
  assert_true(is_real_git_delegate_enabled())
  assert_eq(resolve_real_git_for_fetch(), "/tmp/mock-git")
  restore_env_var_for_fetch_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "fetch-delegate: absolute real-git path requires existing file" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "/tmp/mock-git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_false(real_git_delegate_is_available(fs))
  fs.write_string("/tmp/mock-git", "#!/bin/sh\n")
  assert_true(real_git_delegate_is_available(fs))
  restore_env_var_for_fetch_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "fetch-delegate: command name is treated as available" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_true(real_git_delegate_is_available(fs))
  restore_env_var_for_fetch_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_fetch_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}
