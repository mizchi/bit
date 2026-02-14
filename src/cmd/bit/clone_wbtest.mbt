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
  let resolved = resolve_local_clone_source_file(
    fs, "/work/repo", "repo.bundle",
  )
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
test "clone bundle advanced compat requires local bundle path" {
  assert_true(
    clone_bundle_requires_advanced_compat(Some("/work/repo/repo.bundle")),
  )
  assert_false(
    clone_bundle_requires_advanced_compat(Some("/work/repo/not-bundle.git")),
  )
  assert_false(clone_bundle_requires_advanced_compat(None))
}

///|
test "clone reftable advanced compat depends on ref-format only" {
  assert_true(clone_ref_format_requires_advanced_compat("reftable"))
  assert_false(clone_ref_format_requires_advanced_compat("files"))
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
