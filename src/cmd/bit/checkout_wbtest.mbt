///|
fn restore_env_var_for_checkout_wbtest(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
test "checkout delegate gate: single positional stays in pure path" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  @sys.set_env_var("SHIM_REAL_GIT", "/tmp/mock-git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_false(checkout_should_delegate_to_real_git(["main"]))
  assert_false(checkout_should_delegate_to_real_git(["HEAD"]))
  assert_false(checkout_should_delegate_to_real_git(["-"]))
  restore_env_var_for_checkout_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_checkout_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "checkout delegate gate: optioned and multi-target forms are delegated" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  @sys.set_env_var("SHIM_REAL_GIT", "/tmp/mock-git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_true(checkout_should_delegate_to_real_git(["-b", "feature"]))
  assert_true(checkout_should_delegate_to_real_git(["--force", "feature"]))
  assert_true(checkout_should_delegate_to_real_git(["main", "path.txt"]))
  assert_true(checkout_should_delegate_to_real_git(["--", "path.txt"]))
  restore_env_var_for_checkout_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_checkout_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}
