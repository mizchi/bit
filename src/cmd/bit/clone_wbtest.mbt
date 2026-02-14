///|
fn restore_env_var_for_clone_wbtest(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
test "clone caps contain token: direct token word" {
  let caps = ["multi_ack thin-pack filter side-band-64k"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: token with value" {
  let caps = ["filter=blob:none"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: fetch equals token" {
  let caps = ["fetch=filter", "agent=git/2.45.0"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: fetch embedded token list" {
  let caps = ["fetch=shallow deepen-since filter", "agent=git/2.45.0"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: missing token" {
  let caps = ["multi_ack thin-pack", "fetch=shallow deepen-since"]
  assert_false(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone local source file resolver: existing relative bundle path" {
  let fs = @git.TestFs::new()
  fs.write_string("/work/repo/repo.bundle", "bundle")
  let resolved = resolve_local_clone_source_file(fs, "/work/repo", "repo.bundle")
  assert_eq(resolved, Some("/work/repo/repo.bundle"))
}

///|
test "clone local source file resolver: file URL path" {
  let fs = @git.TestFs::new()
  fs.write_string("/tmp/repo.bundle", "bundle")
  let resolved = resolve_local_clone_source_file(
    fs, "/work/repo", "file:///tmp/repo.bundle",
  )
  assert_eq(resolved, Some("/tmp/repo.bundle"))
}

///|
test "clone local source file resolver: remote URL is ignored" {
  let fs = @git.TestFs::new()
  let resolved = resolve_local_clone_source_file(
    fs, "/work/repo", "https://example.com/repo.bundle",
  )
  assert_eq(resolved, None)
}

///|
test "clone bundle delegate gate: unavailable real git path stays in pure path" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "/tmp/mock-git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_false(clone_can_delegate_to_real_git(fs))
  assert_false(
    clone_should_delegate_to_real_git_for_bundle(
      fs, Some("/work/repo/repo.bundle"),
    ),
  )
  restore_env_var_for_clone_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_clone_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "clone bundle delegate gate: available real git path is delegated" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_true(clone_can_delegate_to_real_git(fs))
  assert_true(
    clone_should_delegate_to_real_git_for_bundle(
      fs, Some("/work/repo/repo.bundle"),
    ),
  )
  assert_false(
    clone_should_delegate_to_real_git_for_bundle(
      fs, Some("/work/repo/not-bundle.git"),
    ),
  )
  restore_env_var_for_clone_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_clone_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "clone reftable delegate gate: unavailable real git path stays in pure path" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "/tmp/mock-git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_false(clone_should_delegate_to_real_git_for_ref_format(fs, "reftable"))
  assert_false(clone_should_delegate_to_real_git_for_ref_format(fs, "files"))
  restore_env_var_for_clone_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_clone_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "clone reftable delegate gate: available real git path is delegated" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_true(clone_should_delegate_to_real_git_for_ref_format(fs, "reftable"))
  assert_false(clone_should_delegate_to_real_git_for_ref_format(fs, "files"))
  restore_env_var_for_clone_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_clone_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "clone standard delegate gate: available real git uses delegate" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_true(
    clone_should_delegate_to_real_git_for_standard_clone(
      fs, "https://example.com/repo.git",
    ),
  )
  restore_env_var_for_clone_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_clone_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
test "clone standard delegate gate: shorthand keeps pure path" {
  let prev_primary = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_secondary = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  let fs = @git.TestFs::new()
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_false(clone_should_delegate_to_real_git_for_standard_clone(fs, "octo/repo"))
  restore_env_var_for_clone_wbtest("SHIM_REAL_GIT", prev_primary)
  restore_env_var_for_clone_wbtest("GIT_SHIM_REAL_GIT", prev_secondary)
}

///|
fn cleanup_clone_wbtest_tree(fs : OsFs, path : String) -> Unit {
  if fs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
    return
  }
  if not(fs.is_dir(path)) {
    return
  }
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    cleanup_clone_wbtest_tree(fs, path + "/" + entry)
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
test "clone: configure_reftable_ref_storage writes reftable metadata" {
  let fs = OsFs::new()
  let root = "/tmp/bit-clone-reftable-" + get_current_timestamp().to_string()
  cleanup_clone_wbtest_tree(fs, root)
  fs.mkdir_p(root)
  fs.write_string(root + "/config", "[core]\n\trepositoryformatversion = 0\n")
  configure_reftable_ref_storage(fs, root) catch {
    err => fail("unexpected error: \{err}")
  }
  assert_true(fs.is_dir(root + "/reftable"))
  assert_true(fs.is_file(root + "/reftable/tables.list"))
  let config = decode_bytes(fs.read_file(root + "/config"))
  assert_true(config.contains("[extensions]"))
  assert_true(config.contains("refStorage = reftable"))
  cleanup_clone_wbtest_tree(fs, root)
}
