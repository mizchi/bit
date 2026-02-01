///|
/// Tests for subdir-clone functionality

///|
test "subdir: write and read attributes" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/info")
  // Write attributes
  let commit_id = @git.ObjectId::from_hex("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2") catch {
    _ => return ()
  }
  write_subdir_attributes(
    fs,
    test_dir + "/.git",
    "https://github.com/user/repo",
    "src/lib",
    commit_id,
  )
  // Read back
  let info = read_subdir_attributes(fs, test_dir + "/.git")
  match info {
    Some((remote, path, base)) => {
      assert_eq(remote, "https://github.com/user/repo")
      assert_eq(path, "src/lib")
      assert_eq(base, "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
    }
    None => assert_true(false)
  }
  // Cleanup
  fs.remove_file(test_dir + "/.git/info/attributes") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/info") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: is_subdir_clone detection" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir2-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/info")
  // Initially not a subdir-clone
  assert_false(is_subdir_clone(fs, test_dir + "/.git"))
  // Write attributes
  let commit_id = @git.ObjectId::from_hex("b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3") catch {
    _ => return ()
  }
  write_subdir_attributes(
    fs,
    test_dir + "/.git",
    "https://github.com/user/repo",
    "src/lib",
    commit_id,
  )
  // Now it's a subdir-clone
  assert_true(is_subdir_clone(fs, test_dir + "/.git"))
  // Cleanup
  fs.remove_file(test_dir + "/.git/info/attributes") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/info") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: get_subdir_info returns metadata" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir3-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/info")
  // Write attributes
  let commit_id = @git.ObjectId::from_hex("c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4") catch {
    _ => return ()
  }
  write_subdir_attributes(
    fs,
    test_dir + "/.git",
    "https://github.com/example/repo",
    "packages/core",
    commit_id,
  )
  // Get info
  let info = get_subdir_info(fs, test_dir + "/.git")
  match info {
    Some((remote, path, base)) => {
      assert_eq(remote, "https://github.com/example/repo")
      assert_eq(path, "packages/core")
      assert_eq(base, "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4")
    }
    None => assert_true(false)
  }
  // Cleanup
  fs.remove_file(test_dir + "/.git/info/attributes") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/info") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: update_subdir_base updates base commit" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir4-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/info")
  // Write initial attributes
  let commit_id = @git.ObjectId::from_hex("d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5") catch {
    _ => return ()
  }
  write_subdir_attributes(
    fs,
    test_dir + "/.git",
    "https://github.com/user/repo",
    "src/lib",
    commit_id,
  )
  // Update base
  update_subdir_base(fs, test_dir + "/.git", "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6")
  // Read back
  let info = read_subdir_attributes(fs, test_dir + "/.git")
  match info {
    Some((_, _, base)) => {
      assert_eq(base, "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6")
    }
    None => assert_true(false)
  }
  // Cleanup
  fs.remove_file(test_dir + "/.git/info/attributes") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/info") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: get_effective_remote_url prefers subdir remote" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir5-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/info")
  // Write config with origin remote
  let config = #|[remote "origin"]
    #|  url = https://github.com/other/repo
    #|  fetch = +refs/heads/*:refs/remotes/origin/*
  fs.write_file(test_dir + "/.git/config", string_to_bytes(config))
  // Write subdir attributes
  let commit_id = @git.ObjectId::from_hex("f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1") catch {
    _ => return ()
  }
  write_subdir_attributes(
    fs,
    test_dir + "/.git",
    "https://github.com/user/subdir-repo",
    "src/lib",
    commit_id,
  )
  // Get effective remote - should prefer subdir remote
  let remote = get_effective_remote_url(fs, test_dir + "/.git")
  match remote {
    Some(url) => assert_eq(url, "https://github.com/user/subdir-repo")
    None => assert_true(false)
  }
  // Cleanup
  fs.remove_file(test_dir + "/.git/config") catch { _ => () }
  fs.remove_file(test_dir + "/.git/info/attributes") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/info") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: get_effective_remote_url falls back to config" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir6-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/info")
  // Write config with origin remote (no subdir attributes)
  let config = #|[remote "origin"]
    #|	url = https://github.com/other/repo
    #|	fetch = +refs/heads/*:refs/remotes/origin/*
  fs.write_file(test_dir + "/.git/config", string_to_bytes(config))
  // Get effective remote - should fall back to config
  let remote = get_effective_remote_url(fs, test_dir + "/.git")
  match remote {
    Some(url) => assert_eq(url, "https://github.com/other/repo")
    None => assert_true(false)
  }
  // Cleanup
  fs.remove_file(test_dir + "/.git/config") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/info") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: attributes file format" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir7-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/info")
  // Write attributes
  let commit_id = @git.ObjectId::from_hex("1234567890abcdef1234567890abcdef12345678") catch {
    _ => return ()
  }
  write_subdir_attributes(
    fs,
    test_dir + "/.git",
    "https://github.com/test/repo",
    "pkg/lib",
    commit_id,
  )
  // Read raw file content
  let content = fs.read_file(test_dir + "/.git/info/attributes") catch {
    _ => return ()
  }
  let text = bytes_to_string(content)
  // Verify format
  assert_true(text.contains("# subdir-clone metadata"))
  assert_true(text.contains("* subdir-remote=https://github.com/test/repo"))
  assert_true(text.contains("* subdir-path=pkg/lib"))
  assert_true(text.contains("* subdir-base=1234567890abcdef1234567890abcdef12345678"))
  // Cleanup
  fs.remove_file(test_dir + "/.git/info/attributes") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/info") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: resolve_ref_for_subdir with direct ref" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir8-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/refs/heads")
  fs.mkdir_p(test_dir + "/.git/objects")
  // Write HEAD ref
  fs.write_file(
    test_dir + "/.git/HEAD",
    string_to_bytes("ref: refs/heads/main\n"),
  )
  fs.write_file(
    test_dir + "/.git/refs/heads/main",
    string_to_bytes("abcdef1234567890abcdef1234567890abcdef12\n"),
  )
  // Resolve HEAD
  let result = resolve_ref_for_subdir(fs, test_dir + "/.git", "HEAD")
  match result {
    Some(id) =>
      assert_eq(id.to_hex(), "abcdef1234567890abcdef1234567890abcdef12")
    None => assert_true(false)
  }
  // Cleanup
  fs.remove_file(test_dir + "/.git/HEAD") catch { _ => () }
  fs.remove_file(test_dir + "/.git/refs/heads/main") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/refs/heads") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/refs") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/objects") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: resolve_ref_for_subdir with remote ref" {
  let fs = OsFs::new()
  let test_dir = "/tmp/bit-test-subdir9-" + get_current_timestamp().to_string()
  fs.mkdir_p(test_dir + "/.git/refs/remotes/origin")
  fs.mkdir_p(test_dir + "/.git/objects")
  // Write remote ref
  fs.write_file(
    test_dir + "/.git/refs/remotes/origin/main",
    string_to_bytes("fedcba0987654321fedcba0987654321fedcba09\n"),
  )
  // Resolve origin/main
  let result = resolve_ref_for_subdir(fs, test_dir + "/.git", "origin/main")
  match result {
    Some(id) =>
      assert_eq(id.to_hex(), "fedcba0987654321fedcba0987654321fedcba09")
    None => assert_true(false)
  }
  // Cleanup
  fs.remove_file(test_dir + "/.git/refs/remotes/origin/main") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/refs/remotes/origin") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/refs/remotes") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/refs") catch { _ => () }
  fs.remove_dir(test_dir + "/.git/objects") catch { _ => () }
  fs.remove_dir(test_dir + "/.git") catch { _ => () }
  fs.remove_dir(test_dir) catch { _ => () }
}

///|
test "subdir: print_subdir_clone_usage outputs help" {
  // Just verify it doesn't crash
  // In real test we'd capture stdout
  print_subdir_clone_usage()
}
