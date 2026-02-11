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
  let root_entries = fs.readdir(root) catch { _ => [] }
  root_entries.sort_by((a, b) => String::lexical_compare(a, b))
  assert_eq(root_entries, [".git", "README.md", "pkg"])
  let readme_blob = @git.hash_blob(fs.read_file(root + "/README.md")).to_hex()
  let mod_blob = @git.hash_blob(fs.read_file(root + "/pkg/mod.txt")).to_hex()
  let pkg_tree = build_git_tree_id(fs, root, "pkg", [".", "..", ".git", ".bit"])
    .unwrap_or(@git.ObjectId::zero())
    .to_hex()
  let readme_id = @git.ObjectId::from_hex(readme_blob) catch {
    _ => @git.ObjectId::zero()
  }
  let pkg_id = @git.ObjectId::from_hex(pkg_tree) catch {
    _ => @git.ObjectId::zero()
  }
  let canonical_root = @git.create_tree([
    @git.TreeEntry::new("100644", "README.md", readme_id),
    @git.TreeEntry::new("40000", "pkg", pkg_id),
  ]).0.to_hex()
  let reversed_root = @git.create_tree([
    @git.TreeEntry::new("40000", "pkg", pkg_id),
    @git.TreeEntry::new("100644", "README.md", readme_id),
  ]).0.to_hex()
  let ours = directory_fingerprint(fs, root, FingerprintMode::GitCompat, ignore_entries=[
    ".", "..", ".git", ".bit",
  ])
  let ours_with_git = directory_fingerprint(
    fs,
    root,
    FingerprintMode::GitCompat,
    ignore_entries=[".", "..", ".bit"],
  )
  assert_eq(ours == ours_with_git, false)
  let add_code = @process.run("git", ["add", "-A"], inherit_env=true, cwd=root) catch {
    _ => -1
  }
  assert_eq(add_code, 0)
  let (write_tree_code, out, _) = @process.collect_output(
    "git",
    ["write-tree"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => {
      cleanup_tmp_dir(root)
      assert_eq(1, 0)
      return
    }
  }
  assert_eq(write_tree_code, 0)
  let (readme_code, readme_out, _) = @process.collect_output(
    "git",
    ["hash-object", "README.md"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => {
      cleanup_tmp_dir(root)
      assert_eq(1, 0)
      return
    }
  }
  assert_eq(readme_code, 0)
  let readme_expected = readme_out.text() catch { _ => "" }
  let readme_expected = readme_expected.trim_end().to_string()
  assert_eq(readme_blob, readme_expected)
  let (mod_code, mod_out, _) = @process.collect_output(
    "git",
    ["hash-object", "pkg/mod.txt"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => {
      cleanup_tmp_dir(root)
      assert_eq(1, 0)
      return
    }
  }
  assert_eq(mod_code, 0)
  let mod_expected = mod_out.text() catch { _ => "" }
  let mod_expected = mod_expected.trim_end().to_string()
  assert_eq(mod_blob, mod_expected)
  let (pkg_code, pkg_out, _) = @process.collect_output(
    "git",
    ["write-tree", "--prefix=pkg"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => {
      cleanup_tmp_dir(root)
      assert_eq(1, 0)
      return
    }
  }
  assert_eq(pkg_code, 0)
  let pkg_expected = pkg_out.text() catch { _ => "" }
  let pkg_expected = pkg_expected.trim_end().to_string()
  assert_eq(pkg_tree, pkg_expected)
  let expected = out.text() catch { _ => "" }
  let expected = expected.trim_end().to_string()
  assert_eq(canonical_root, expected)
  assert_eq(reversed_root == expected, false)
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
