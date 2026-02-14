///|
test "commit: signing options require standalone error" {
  assert_true(commit_args_require_standalone_error(["-S", "-m", "msg"]))
  assert_true(
    commit_args_require_standalone_error(["-S/path/to/key", "-m", "msg"]),
  )
  assert_true(commit_args_require_standalone_error(["--gpg-sign", "-m", "msg"]))
  assert_true(
    commit_args_require_standalone_error(["--gpg-sign=KEY", "-m", "msg"]),
  )
}

///|
test "commit: sha256 repository requires standalone error" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tobjectformat = sha256\n",
  )
  assert_true(commit_repo_requires_standalone_error(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[core]\n\trepositoryformatversion = 0\n",
  )
  assert_false(commit_repo_requires_standalone_error(fs, "/repo/.git"))
}

///|
test "commit: compatobjectformat=sha256 requires standalone error" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha256\n",
  )
  assert_true(commit_repo_requires_standalone_error(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha1\n",
  )
  assert_false(commit_repo_requires_standalone_error(fs, "/repo/.git"))
}

///|
test "commit: no-edit prefers SQUASH_MSG and appends MERGE_MSG comments" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string("/repo/.git/SQUASH_MSG", "squash body\n")
  fs.write_string("/repo/.git/MERGE_MSG", "\n# Conflicts:\n#\tfile\n")
  let msg = resolve_no_edit_commit_message(fs, "/repo", "/repo/.git", false)
  assert_eq(msg, Some("squash body\n\n# Conflicts:\n#\tfile\n"))
}

///|
test "commit: no-edit prefers MERGE_MSG when MERGE_HEAD exists" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/MERGE_HEAD", "1111111111111111111111111111111111111111\n",
  )
  fs.write_string("/repo/.git/SQUASH_MSG", "squash body\n")
  fs.write_string("/repo/.git/MERGE_MSG", "merge body\n")
  let msg = resolve_no_edit_commit_message(fs, "/repo", "/repo/.git", false)
  assert_eq(msg, Some("merge body\n"))
}

///|
test "commit: read MERGE_HEAD supports multiple parents" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/MERGE_HEAD", "1111111111111111111111111111111111111111\n2222222222222222222222222222222222222222\n",
  )
  let merge_heads = read_merge_head_ids(fs, "/repo/.git")
  assert_eq(merge_heads.length(), 2)
  assert_eq(merge_heads[0].to_hex(), "1111111111111111111111111111111111111111")
  assert_eq(merge_heads[1].to_hex(), "2222222222222222222222222222222222222222")
}
