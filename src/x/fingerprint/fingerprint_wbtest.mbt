///|
fn get_current_timestamp() -> Int64 {
  @env.now().to_int().to_int64() / 1000
}

///|
fn make_tmp_root(prefix : String) -> String {
  "/tmp/bit-test-" + prefix + "-" + get_current_timestamp().to_string()
}

///|
async fn cleanup_tmp_dir(path : String) -> Unit {
  ignore(@process.run("rm", ["-rf", path], inherit_env=true)) catch {
    _ => ()
  }
}

///|
async fn git_write_tree_after_add_all(root : String) -> String? {
  let add_code = @process.run("git", ["add", "-A"], inherit_env=true, cwd=root) catch {
    _ => -1
  }
  if add_code != 0 {
    return None
  }
  let (code, out, _) = @process.collect_output(
    "git",
    ["write-tree"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => return None
  }
  if code != 0 {
    return None
  }
  let text = out.text() catch { _ => return None }
  Some(text.trim_end().to_string())
}

///|
async fn git_cached_name_status(root : String) -> String? {
  let (code, out, _) = @process.collect_output(
    "git",
    ["diff", "--cached", "--name-status"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => return None
  }
  if code != 0 {
    return None
  }
  let text = out.text() catch { _ => return None }
  Some(text.trim_end().to_string())
}

///|
async fn git_reset_clean(root : String) -> Bool {
  let reset_code = @process.run(
    "git",
    ["reset", "--hard"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  if reset_code != 0 {
    return false
  }
  let clean_code = @process.run(
    "git",
    ["clean", "-fd"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  clean_code == 0
}

///|
async fn assert_git_add_all_equivalent(fs : @osfs.OsFs, root : String) -> Unit {
  let cached_before = git_cached_name_status(root).unwrap_or("")
  let ours = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  let cached_after = git_cached_name_status(root).unwrap_or("")
  assert_eq(cached_before, cached_after)
  guard git_write_tree_after_add_all(root) is Some(expected) else {
    assert_eq(1, 0)
    return
  }
  assert_eq(ours, expected)
}

///|
async test "fingerprint: parse mode aliases" {
  assert_eq(parse_fingerprint_mode("fast"), Some(FingerprintMode::Fast))
  assert_eq(parse_fingerprint_mode("git"), Some(FingerprintMode::GitCompat))
  assert_eq(
    parse_fingerprint_mode("git-compat"),
    Some(FingerprintMode::GitCompat),
  )
  assert_eq(
    parse_fingerprint_mode("git_compat"),
    Some(FingerprintMode::GitCompat),
  )
  assert_eq(parse_fingerprint_mode("unknown"), None)
}

///|
async test "fingerprint: fast mode changes when file content changes" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-fast-change")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root + "/nested")
  fs.write_string(root + "/nested/file.txt", "hello\n")
  let hash1 = directory_fingerprint(fs, root, FingerprintMode::Fast)
  fs.write_string(root + "/nested/file.txt", "hello world\n")
  let hash2 = directory_fingerprint(fs, root, FingerprintMode::Fast)
  assert_eq(hash1 == hash2, false)
  cleanup_tmp_dir(root)
}

///|
async test "fingerprint: fast mode ignores .git and .bit metadata dirs" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-fast-ignore")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root)
  fs.write_string(root + "/tracked.txt", "payload\n")
  let hash1 = directory_fingerprint(fs, root, FingerprintMode::Fast)
  fs.mkdir_p(root + "/.git")
  fs.mkdir_p(root + "/.bit")
  fs.write_string(root + "/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(root + "/.bit/WORKSPACE", "metadata\n")
  let hash2 = directory_fingerprint(fs, root, FingerprintMode::Fast)
  assert_eq(hash1, hash2)
  cleanup_tmp_dir(root)
}

///|
async test "fingerprint: git compat mode matches git write-tree for simple files" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-git-compat")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root)
  let init_code = @process.run(
    "git",
    ["init", "-b", "main"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  if init_code != 0 {
    cleanup_tmp_dir(root)
    return
  }
  fs.mkdir_p(root + "/pkg")
  fs.write_string(root + "/README.md", "hello\n")
  fs.write_string(root + "/pkg/mod.txt", "mod\n")
  let ours = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  guard git_write_tree_after_add_all(root) is Some(expected) else {
    cleanup_tmp_dir(root)
    assert_eq(1, 0)
    return
  }
  assert_eq(ours, expected)
  cleanup_tmp_dir(root)
}

///|
async test "fingerprint: git compat matches git add -A write-tree with staged and unstaged mix" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-git-add-all-mix")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root)
  let init_code = @process.run(
    "git",
    ["init", "-b", "main"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  if init_code != 0 {
    cleanup_tmp_dir(root)
    return
  }
  let cfg_email = @process.run(
    "git",
    ["config", "user.email", "test@example.com"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  let cfg_name = @process.run(
    "git",
    ["config", "user.name", "Test User"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  assert_eq(cfg_email, 0)
  assert_eq(cfg_name, 0)
  fs.mkdir_p(root + "/dir")
  fs.write_string(root + "/tracked.txt", "base\n")
  fs.write_string(root + "/dir/a.txt", "a\n")
  let add_base = @process.run("git", ["add", "-A"], inherit_env=true, cwd=root) catch {
    _ => -1
  }
  let commit_base = @process.run(
    "git",
    ["commit", "-m", "base"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  assert_eq(add_base, 0)
  assert_eq(commit_base, 0)

  // staged + unstaged on tracked file
  fs.write_string(root + "/tracked.txt", "stage-1\n")
  let stage_code = @process.run(
    "git",
    ["add", "tracked.txt"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  assert_eq(stage_code, 0)
  fs.write_string(root + "/tracked.txt", "worktree-2\n")
  // untracked file under new directory
  fs.mkdir_p(root + "/newdir/sub")
  fs.write_string(root + "/newdir/sub/file.txt", "u\n")
  // unstaged delete
  fs.remove_file(root + "/dir/a.txt")

  let before_cached = git_cached_name_status(root).unwrap_or("")
  let ours = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  let after_cached = git_cached_name_status(root).unwrap_or("")
  assert_eq(before_cached, after_cached)
  guard git_write_tree_after_add_all(root) is Some(expected) else {
    cleanup_tmp_dir(root)
    assert_eq(1, 0)
    return
  }
  assert_eq(ours, expected)
  cleanup_tmp_dir(root)
}

///|
async test "fingerprint: git compat mode ignores empty directories" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-git-empty-dir")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root + "/pkg")
  fs.write_string(root + "/pkg/mod.txt", "mod\n")
  let hash1 = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  fs.mkdir_p(root + "/pkg/empty")
  fs.mkdir_p(root + "/only-empty-dir")
  let hash2 = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  assert_eq(hash1, hash2)
  cleanup_tmp_dir(root)
}

///|
async test "fingerprint: git compat mode changes when file is renamed" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-git-rename")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root + "/pkg")
  fs.write_string(root + "/pkg/a.txt", "same-content\n")
  let hash1 = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  fs.remove_file(root + "/pkg/a.txt")
  fs.write_string(root + "/pkg/b.txt", "same-content\n")
  let hash2 = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  assert_eq(hash1 == hash2, false)
  cleanup_tmp_dir(root)
}

///|
async test "fingerprint: fast and git compat produce different fingerprints" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-mode-diff")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root + "/pkg")
  fs.write_string(root + "/pkg/file.txt", "payload\n")
  let fast = directory_fingerprint(fs, root, FingerprintMode::Fast)
  let git = directory_fingerprint(fs, root, FingerprintMode::GitCompat)
  assert_eq(fast == git, false)
  cleanup_tmp_dir(root)
}

///|
async test "fingerprint: git compat add-all matrix matches git write-tree" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = make_tmp_root("fingerprint-git-add-all-matrix")
  cleanup_tmp_dir(root)
  fs.mkdir_p(root)
  let init_code = @process.run(
    "git",
    ["init", "-b", "main"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  if init_code != 0 {
    cleanup_tmp_dir(root)
    return
  }
  ignore(
    @process.run(
      "git",
      ["config", "user.email", "test@example.com"],
      inherit_env=true,
      cwd=root,
    ),
  ) catch {
    _ => ()
  }
  ignore(
    @process.run(
      "git",
      ["config", "user.name", "Test User"],
      inherit_env=true,
      cwd=root,
    ),
  ) catch {
    _ => ()
  }
  fs.mkdir_p(root + "/dir")
  fs.write_string(root + "/tracked.txt", "base\n")
  fs.write_string(root + "/dir/a.txt", "a\n")
  let add_base = @process.run("git", ["add", "-A"], inherit_env=true, cwd=root) catch {
    _ => -1
  }
  let commit_base = @process.run(
    "git",
    ["commit", "-m", "base"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  assert_eq(add_base, 0)
  assert_eq(commit_base, 0)

  // case: untracked file
  assert_true(git_reset_clean(root))
  fs.write_string(root + "/untracked.txt", "u\n")
  assert_git_add_all_equivalent(fs, root)

  // case: untracked nested directory file
  assert_true(git_reset_clean(root))
  fs.mkdir_p(root + "/newdir/sub")
  fs.write_string(root + "/newdir/sub/file.txt", "n\n")
  assert_git_add_all_equivalent(fs, root)

  // case: tracked unstaged modification
  assert_true(git_reset_clean(root))
  fs.write_string(root + "/tracked.txt", "mod\n")
  assert_git_add_all_equivalent(fs, root)

  // case: staged + unstaged on same tracked file
  assert_true(git_reset_clean(root))
  fs.write_string(root + "/tracked.txt", "stage-1\n")
  ignore(
    @process.run(
      "git",
      ["add", "tracked.txt"],
      inherit_env=true,
      cwd=root,
    ),
  ) catch {
    _ => ()
  }
  fs.write_string(root + "/tracked.txt", "worktree-2\n")
  assert_git_add_all_equivalent(fs, root)

  // case: staged rename
  assert_true(git_reset_clean(root))
  ignore(
    @process.run(
      "git",
      ["mv", "tracked.txt", "renamed.txt"],
      inherit_env=true,
      cwd=root,
    ),
  ) catch {
    _ => ()
  }
  assert_git_add_all_equivalent(fs, root)

  // case: staged delete + untracked file
  assert_true(git_reset_clean(root))
  ignore(
    @process.run(
      "git",
      ["rm", "-f", "dir/a.txt"],
      inherit_env=true,
      cwd=root,
    ),
  ) catch {
    _ => ()
  }
  fs.write_string(root + "/extra.txt", "x\n")
  assert_git_add_all_equivalent(fs, root)

  cleanup_tmp_dir(root)
}
