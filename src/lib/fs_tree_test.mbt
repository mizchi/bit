///| Tests for fs_tree helpers

///|
fn setup_fs_tree() -> @git.TestFs {
  @git.TestFs::new()
}

///|
test "fs_tree: copy_tree copies files and directories" {
  let fs = setup_fs_tree()
  fs.write_string("/src/a.txt", "hello\n")
  fs.write_string("/src/dir/b.txt", "world\n")
  copy_tree(fs, fs, "/src", "/dst")
  assert_true(fs.is_file("/dst/a.txt"))
  assert_true(fs.is_file("/dst/dir/b.txt"))
  assert_eq(fs.read_string("/dst/a.txt"), "hello\n")
  assert_eq(fs.read_string("/dst/dir/b.txt"), "world\n")
}

///|
test "fs_tree: copy_tree does not overwrite existing files" {
  let fs = setup_fs_tree()
  fs.write_string("/src/a.txt", "source\n")
  fs.write_string("/dst/a.txt", "keep\n")
  copy_tree(fs, fs, "/src", "/dst")
  assert_eq(fs.read_string("/dst/a.txt"), "keep\n")
}

///|
test "fs_tree: move_tree_safe handles nested destinations" {
  let fs = setup_fs_tree()
  fs.write_string("/src/a.txt", "hello\n")
  move_tree_safe(fs, fs, "/src", "/src/nested")
  assert_true(fs.is_file("/src/nested/a.txt"))
  assert_true(not(fs.is_file("/src/a.txt")))
}

///|
test "fs_tree: remove_ref_path removes file and directory" {
  let fs = setup_fs_tree()
  fs.write_string("/refs/heads/main", "abc")
  fs.write_string("/refs/tags/v1/tag", "def")
  remove_ref_path(fs, fs, "/refs/heads/main")
  remove_ref_path(fs, fs, "/refs/tags")
  assert_true(not(fs.is_file("/refs/heads/main")))
  assert_true(not(fs.is_dir("/refs/tags")))
}
