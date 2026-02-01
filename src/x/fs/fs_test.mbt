///|
/// Fs blackbox tests
test "bitfs: empty filesystem" {
  let bitfs = Fs::empty("/repo/.git")
  assert_eq(bitfs.is_dirty(), false)
  assert_eq(bitfs.base_tree(), @git.ObjectId::zero())
  assert_eq(bitfs.base_commit(), None)
}

///|
test "bitfs: write and read file in working layer" {
  let bitfs = Fs::empty("/repo/.git")
  bitfs.write_string("/file.txt", "hello\n")
  assert_eq(bitfs.is_dirty(), true)
  let files = bitfs.get_working_files()
  assert_eq(files, ["file.txt"])
}

///|
test "bitfs: mkdir_p creates directory hierarchy" {
  let bitfs = Fs::empty("/repo/.git")
  bitfs.mkdir_p("a/b/c")
  assert_eq(bitfs.is_dirty(), true)
}

///|
test "bitfs: remove_file marks file as deleted" {
  let bitfs = Fs::empty("/repo/.git")
  bitfs.write_string("file.txt", "content")
  bitfs.remove_file("file.txt")
  let files = bitfs.get_working_files()
  assert_eq(files, [])
  let deleted = bitfs.get_deleted_files()
  assert_eq(deleted, ["file.txt"])
}

///|
test "bitfs: rollback clears working layer" {
  let bitfs = Fs::empty("/repo/.git")
  bitfs.write_string("file.txt", "content")
  assert_eq(bitfs.is_dirty(), true)
  bitfs.rollback()
  assert_eq(bitfs.is_dirty(), false)
  assert_eq(bitfs.get_working_files(), [])
}

///|
test "bitfs: config defaults" {
  let config = FsConfig::default()
  assert_eq(config.max_cache_bytes, 64 * 1024 * 1024)
  assert_eq(config.max_cache_entries, 1000)
}

///|
test "bitfs: full workflow with backing fs" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/file.txt", "initial\n")
  @lib.add_paths(fs, fs, "/repo", ["file.txt"])
  let commit1 = @lib.commit(
    fs, fs, "/repo", "Initial commit", "Author <a@b.com>", 1700000000L,
  )
  let bitfs = Fs::from_commit(fs, "/repo/.git", commit1)
  let content = bitfs.read_file(fs, "file.txt")
  assert_eq(@utf8.decode_lossy(content[:]), "initial\n")
  bitfs.write_string("file.txt", "modified\n")
  assert_eq(bitfs.is_dirty(), true)
  let snap = bitfs.snapshot(
    fs, fs, "Snapshot 1", "Author <a@b.com>", 1700001000L,
  )
  assert_eq(bitfs.is_dirty(), false)
  assert_true(snap.commit_id != commit1)
  bitfs.write_string("file.txt", "changed again\n")
  bitfs.rollback()
  let content2 = bitfs.read_file(fs, "file.txt")
  assert_eq(@utf8.decode_lossy(content2[:]), "modified\n")
}

///|
test "bitfs: readdir from base tree" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/a/b.txt", "content\n")
  fs.write_string("/repo/a/c.txt", "content\n")
  fs.write_string("/repo/d.txt", "content\n")
  @lib.add_paths(fs, fs, "/repo", ["a/b.txt", "a/c.txt", "d.txt"])
  let commit = @lib.commit(
    fs, fs, "/repo", "Add files", "Author <a@b.com>", 1700000000L,
  )
  let bitfs = Fs::from_commit(fs, "/repo/.git", commit)
  let root_entries = bitfs.readdir(fs, "")
  assert_true(root_entries.contains("a"))
  assert_true(root_entries.contains("d.txt"))
  let a_entries = bitfs.readdir(fs, "a")
  assert_true(a_entries.contains("b.txt"))
  assert_true(a_entries.contains("c.txt"))
}

///|
test "bitfs: is_dir and is_file" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/dir/file.txt", "content\n")
  @lib.add_paths(fs, fs, "/repo", ["dir/file.txt"])
  let commit = @lib.commit(
    fs, fs, "/repo", "Add file", "Author <a@b.com>", 1700000000L,
  )
  let bitfs = Fs::from_commit(fs, "/repo/.git", commit)
  assert_true(bitfs.is_dir(fs, ""))
  assert_true(bitfs.is_dir(fs, "dir"))
  assert_false(bitfs.is_dir(fs, "dir/file.txt"))
  assert_true(bitfs.is_file(fs, "dir/file.txt"))
  assert_false(bitfs.is_file(fs, "dir"))
  assert_false(bitfs.is_file(fs, "nonexistent"))
}

///|
test "bitfs: layers" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/base.txt", "base\n")
  @lib.add_paths(fs, fs, "/repo", ["base.txt"])
  let commit1 = @lib.commit(
    fs, fs, "/repo", "Base", "Author <a@b.com>", 1700000000L,
  )
  fs.write_string("/repo/layer.txt", "layer\n")
  @lib.add_paths(fs, fs, "/repo", ["layer.txt"])
  let commit2 = @lib.commit(
    fs, fs, "/repo", "Layer", "Author <a@b.com>", 1700001000L,
  )
  let bitfs = Fs::from_commit(fs, "/repo/.git", commit1)
  assert_true(bitfs.is_file(fs, "base.txt"))
  assert_false(bitfs.is_file(fs, "layer.txt"))
  bitfs.add_layer_from_commit(fs, commit2, "overlay")
  assert_true(bitfs.is_file(fs, "layer.txt"))
  assert_true(bitfs.has_layer("overlay"))
  let removed = bitfs.remove_layer("overlay")
  assert_true(removed)
  assert_false(bitfs.has_layer("overlay"))
  assert_false(bitfs.is_file(fs, "layer.txt"))
}
