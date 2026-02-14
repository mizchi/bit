///|
fn restore_env_var_for_branch_wbtest(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
test "branch delegate gate: non-reftable simple create stays pure path" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string("/repo/.git/config", "[core]\n\trepositoryformatversion = 0\n")
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_false(
    branch_should_delegate_to_real_git_with_repo(fs, "/repo/.git", ["feature"]),
  )
  restore_env_var_for_branch_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_branch_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "branch delegate gate: reftable repo delegates simple create" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config",
    "[core]\n\trepositoryformatversion = 1\n[extensions]\n\trefStorage = reftable\n",
  )
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_true(
    branch_should_delegate_to_real_git_with_repo(fs, "/repo/.git", ["bRanch1"]),
  )
  restore_env_var_for_branch_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_branch_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}
