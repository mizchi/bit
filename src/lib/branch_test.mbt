///| Tests for git branch listing

///|
fn setup_branch_fs() -> @git.TestFs {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.mkdir_p("/repo/.git/refs/heads")
  fs
}

///|
test "branch: list with current" {
  let fs = setup_branch_fs()
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(
    "/repo/.git/refs/heads/main", "1111111111111111111111111111111111111111\n",
  )
  fs.mkdir_p("/repo/.git/refs/heads/feature")
  fs.write_string(
    "/repo/.git/refs/heads/feature/x", "2222222222222222222222222222222222222222\n",
  )
  fs.write_string(
    "/repo/.git/packed-refs", "# pack-refs with: peeled\n3333333333333333333333333333333333333333 refs/heads/dev\n",
  )
  let lines = list_branches_text(fs, "/repo/.git")
  assert_true(lines.contains("* main"))
  assert_true(lines.contains("  dev"))
  assert_true(lines.contains("  feature/x"))
}

///|
test "branch: detached head" {
  let fs = setup_branch_fs()
  fs.write_string(
    "/repo/.git/HEAD", "4444444444444444444444444444444444444444\n",
  )
  fs.write_string(
    "/repo/.git/refs/heads/main", "1111111111111111111111111111111111111111\n",
  )
  let lines = list_branches_text(fs, "/repo/.git")
  assert_true(lines[0].has_prefix("* (HEAD detached at 4444444"))
  assert_true(lines.contains("  main"))
}

///|
test "branch: create branch" {
  let fs = setup_branch_fs()
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(
    "/repo/.git/refs/heads/main", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
  )
  create_branch(fs, fs, "/repo", "feature")
  let content = fs.read_string("/repo/.git/refs/heads/feature")
  assert_true(content.has_prefix("aaaaaaaaaa"))
}

///|
test "branch: switch branch updates head" {
  let fs = setup_branch_fs()
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(
    "/repo/.git/refs/heads/main", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
  )
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=false)
  let head = fs.read_string("/repo/.git/HEAD")
  assert_true(head.has_prefix("ref: refs/heads/feature"))
  let feature = fs.read_string("/repo/.git/refs/heads/feature")
  assert_true(feature.has_prefix("bbbbbbbbbb"))
}
