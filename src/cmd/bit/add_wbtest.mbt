///|
test "add: sha256 repository requires standalone error" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tobjectformat = sha256\n",
  )
  assert_true(add_repo_requires_standalone_error(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[core]\n\trepositoryformatversion = 0\n",
  )
  assert_false(add_repo_requires_standalone_error(fs, "/repo/.git"))
}

///|
test "add: compatobjectformat=sha256 requires standalone error" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha256\n",
  )
  assert_true(add_repo_requires_standalone_error(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha1\n",
  )
  assert_false(add_repo_requires_standalone_error(fs, "/repo/.git"))
}
