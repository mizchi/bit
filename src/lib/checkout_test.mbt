///| Tests for checkout

///|
fn setup_repo_checkout() -> @git.TestFs {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs
}

///|
test "checkout: switch back to main" {
  let fs = setup_repo_checkout()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <t@example.com>", 1700000000L,
  )
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  fs.write_string("/repo/a.txt", "two\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <t@example.com>", 1700000001L),
  )
  let target = checkout(fs, fs, "/repo", "main")
  assert_true(target == first)
  let head = fs.read_string("/repo/.git/HEAD")
  assert_true(head.contains("refs/heads/main"))
  let content = fs.read_string("/repo/a.txt")
  assert_true(content == "one\n")
}
