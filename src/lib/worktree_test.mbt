///| Tests for worktree status/add/commit

///|
fn setup_repo() -> @git.TestFs {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs
}

///|
async test "worktree: status/add/commit" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  let st1 = status(fs, "/repo")
  assert_true(st1.untracked.contains("a.txt"))
  add_paths(fs, fs, "/repo", ["a.txt"])
  let st2 = status(fs, "/repo")
  assert_true(st2.staged_added.contains("a.txt"))
  assert_true(st2.untracked.length() == 0)
  let commit_id = commit(
    fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L,
  )
  let ref_text = fs.read_string("/repo/.git/refs/heads/main")
  assert_true(ref_text.contains(commit_id.to_hex()))
  let st3 = status(fs, "/repo")
  assert_true(st3.untracked.length() == 0)
  assert_true(st3.unstaged_modified.length() == 0)
  assert_true(st3.staged_added.length() == 0)
}

///|
async test "worktree: modified after commit" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L),
  )
  fs.write_string("/repo/a.txt", "changed\n")
  let st = status(fs, "/repo")
  assert_true(st.unstaged_modified.contains("a.txt"))
}

///|
async test "worktree: staged modified after add" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L),
  )
  fs.write_string("/repo/a.txt", "changed\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let st = status(fs, "/repo")
  assert_true(st.staged_modified.contains("a.txt"))
  assert_true(st.unstaged_modified.length() == 0)
}

///|
async test "worktree: staged deleted after remove and add" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L),
  )
  fs.remove_file("/repo/a.txt")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let st = status(fs, "/repo")
  assert_true(st.staged_deleted.contains("a.txt"))
  assert_true(st.unstaged_deleted.length() == 0)
}

///|
async test "worktree: status text" {
  let fs = setup_repo()
  let text1 = status_text(fs, "/repo")
  assert_true(text1.contains("On branch main"))
  assert_true(text1.contains("No commits yet"))
  assert_true(text1.contains("nothing to commit"))
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let text2 = status_text(fs, "/repo")
  assert_true(text2.contains("Changes to be committed"))
  assert_true(text2.contains("staged: a.txt"))
}

///|
async test "worktree: status text tolerates sha256 ref" {
  let fs = setup_repo()
  fs.write_string(
    "/repo/.git/refs/heads/main", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n",
  )
  let text = status_text(fs, "/repo")
  assert_true(text.contains("On branch main"))
}

///|
async test "worktree: empty commit requires allow_empty" {
  let fs = setup_repo()
  let _ = commit(
    fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L,
  ) catch {
    _ => return ()
  }
  fail("expected empty-index commit to fail without allow_empty")
}

///|
async test "worktree: allow_empty creates initial commit" {
  let fs = setup_repo()
  let allow_empty = true
  let commit_id = commit(
    fs,
    fs,
    "/repo",
    "empty\n",
    "Test <test@example.com>",
    1700000000L,
    allow_empty~,
  )
  let ref_text = fs.read_string("/repo/.git/refs/heads/main")
  assert_true(ref_text.contains(commit_id.to_hex()))
}
