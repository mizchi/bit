///| Tests for merge

///|
fn setup_repo_merge() -> @git.TestFs {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs
}

///|
test "merge: file-level merge without conflicts" {
  let fs = setup_repo_merge()
  fs.write_string("/repo/a.txt", "base\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(commit(fs, fs, "/repo", "base\n", "Test <t@example.com>", 1700000000L))
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  fs.write_string("/repo/b.txt", "feature\n")
  add_paths(fs, fs, "/repo", ["b.txt"])
  let feature_commit = commit(
    fs, fs, "/repo", "feature\n", "Test <t@example.com>", 1700000001L,
  )
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  fs.write_string("/repo/a.txt", "main\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let main_commit = commit(
    fs, fs, "/repo", "main\n", "Test <t@example.com>", 1700000002L,
  )
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge\n", "Test <t@example.com>", 1700000003L,
  )
  match result.status {
    Merged => ()
    Conflicted => {
      println("CONFLICT: \{result.conflicts}")
      assert_true(false)
    }
    AlreadyUpToDate => {
      println("AlreadyUpToDate merge")
      assert_true(false)
    }
    FastForward => {
      println("FastForward merge")
      assert_true(false)
    }
  }
  let head = fs.read_string("/repo/.git/refs/heads/main")
  match result.commit_id {
    None => assert_true(false)
    Some(id) => assert_true(head.contains(id.to_hex()))
  }
  let content_a = fs.read_string("/repo/a.txt")
  let content_b = fs.read_string("/repo/b.txt")
  assert_true(content_a == "main\n")
  assert_true(content_b == "feature\n")
  let db = ObjectDb::load(fs, "/repo/.git")
  match result.commit_id {
    None => ()
    Some(id) => {
      let obj = db.get(fs, id)
      match obj {
        None => assert_true(false)
        Some(o) => {
          let info = @git.parse_commit(o.data)
          assert_true(info.parents.length() == 2)
          assert_true(info.parents.contains(main_commit))
          assert_true(info.parents.contains(feature_commit))
        }
      }
    }
  }
}
