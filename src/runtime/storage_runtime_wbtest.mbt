///|
fn storage_runtime_wbtest_decode_bytes(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn storage_runtime_wbtest_trim(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn storage_runtime_wbtest_has_line(
  lines : Array[String],
  expected : String,
) -> Bool {
  for line in lines {
    if line == expected {
      return true
    }
  }
  false
}

///|
fn restore_env_var_for_storage_runtime_wbtest(
  name : String,
  prev : String?,
) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
fn setup_storage_runtime_quiet_for_wbtest() -> String? {
  let prev = @sys.get_env_var("BIT_STORAGE_RUNTIME_QUIET")
  @sys.set_env_var("BIT_STORAGE_RUNTIME_QUIET", "1")
  prev
}

///|
fn setup_identity_for_storage_runtime_wbtest() -> (
  String?,
  String?,
  String?,
  String?,
) {
  let prev_author_name = @sys.get_env_var("GIT_AUTHOR_NAME")
  let prev_author_email = @sys.get_env_var("GIT_AUTHOR_EMAIL")
  let prev_committer_name = @sys.get_env_var("GIT_COMMITTER_NAME")
  let prev_committer_email = @sys.get_env_var("GIT_COMMITTER_EMAIL")
  @sys.set_env_var("GIT_AUTHOR_NAME", "Storage Test")
  @sys.set_env_var("GIT_AUTHOR_EMAIL", "storage@example.com")
  @sys.set_env_var("GIT_COMMITTER_NAME", "Storage Test")
  @sys.set_env_var("GIT_COMMITTER_EMAIL", "storage@example.com")
  (
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
}

///|
fn restore_identity_for_storage_runtime_wbtest(
  prev_author_name : String?,
  prev_author_email : String?,
  prev_committer_name : String?,
  prev_committer_email : String?,
) -> Unit {
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_AUTHOR_NAME", prev_author_name,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_AUTHOR_EMAIL", prev_author_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_COMMITTER_NAME", prev_committer_name,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_COMMITTER_EMAIL", prev_committer_email,
  )
}

///|
test "storage runtime: init/add/commit/status/log on TestFs" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-basic"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, "init", ["-q"]) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "hello\n")
  run_storage_command(fs, fs, root, "add", ["a.txt"]) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(fs, fs, root, "commit", ["-q", "-m", "first commit"]) catch {
    err => fail("commit failed: \{err}")
  }
  let git_dir = root + "/.git"
  assert_true(fs.is_file(git_dir + "/refs/heads/main"))
  run_storage_command(fs, fs, root, "status", ["--porcelain"]) catch {
    err => fail("status failed: \{err}")
  }
  run_storage_command(fs, fs, root, "log", ["--oneline", "-1"]) catch {
    err => fail("log failed: \{err}")
  }
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: hash-object -w and write-tree work on TestFs" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-objects"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  run_storage_command(fs, fs, root, "init", ["-q"]) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/blob.txt", "blob-data\n")
  run_storage_command(fs, fs, root, "add", ["blob.txt"]) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(fs, fs, root, "hash-object", ["-w", "blob.txt"]) catch {
    err => fail("hash-object failed: \{err}")
  }
  let blob_id = @git.hash_object_content(
    @git.ObjectType::Blob,
    fs.read_file(root + "/blob.txt"),
  )
  let blob_hex = blob_id.to_hex()
  let dir = (try! blob_hex[:2]).to_string()
  let rest = (try! blob_hex[2:]).to_string()
  let object_path = root + "/.git/objects/" + dir + "/" + rest
  assert_true(fs.is_file(object_path))
  run_storage_command(fs, fs, root, "write-tree", []) catch {
    err => fail("write-tree failed: \{err}")
  }
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: update-ref create and delete on TestFs" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-update-ref"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, "init", ["-q"]) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "hello\n")
  run_storage_command(fs, fs, root, "add", ["a.txt"]) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(fs, fs, root, "commit", ["-q", "-m", "base"]) catch {
    err => fail("commit failed: \{err}")
  }
  let git_dir = root + "/.git"
  let head_id = match @gitrepo.rev_parse(fs, git_dir, "HEAD") {
    Some(id) => id
    None => {
      fail("HEAD not found")
      @git.ObjectId::zero()
    }
  }
  run_storage_command(fs, fs, root, "update-ref", [
    "refs/heads/storage",
    head_id.to_hex(),
  ]) catch {
    err => fail("update-ref create failed: \{err}")
  }
  let created = storage_runtime_wbtest_trim(
    storage_runtime_wbtest_decode_bytes(
      fs.read_file(git_dir + "/refs/heads/storage"),
    ),
  )
  assert_eq(created, head_id.to_hex())
  run_storage_command(fs, fs, root, "update-ref", [
    "-d",
    "refs/heads/storage",
    head_id.to_hex(),
  ]) catch {
    err => fail("update-ref delete failed: \{err}")
  }
  assert_false(fs.is_file(git_dir + "/refs/heads/storage"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: unsupported command is rejected" {
  let fs = @git.TestFs::new()
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let mut failed = false
  run_storage_command(fs, fs, "/repo-storage-runtime-unsupported", "clone", []) catch {
    _ => failed = true
  }
  assert_true(failed)
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: commit without message is rejected" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-no-message"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  run_storage_command(fs, fs, root, "init", ["-q"]) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "hello\n")
  run_storage_command(fs, fs, root, "add", ["a.txt"]) catch {
    err => fail("add failed: \{err}")
  }
  let mut failed = false
  run_storage_command(fs, fs, root, "commit", []) catch {
    _ => failed = true
  }
  assert_true(failed)
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain lines report unstaged and untracked" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-lines"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, "init", ["-q"]) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  run_storage_command(fs, fs, root, "add", ["a.txt"]) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(fs, fs, root, "commit", ["-q", "-m", "base"]) catch {
    err => fail("commit failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "changed\n")
  fs.write_string(root + "/b.txt", "new\n")
  let lines = storage_status_porcelain_lines(fs, root, false) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(storage_runtime_wbtest_has_line(lines, " M a.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "?? b.txt"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain branch line" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-branch"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, "init", ["-q"]) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  run_storage_command(fs, fs, root, "add", ["a.txt"]) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(fs, fs, root, "commit", ["-q", "-m", "base"]) catch {
    err => fail("commit failed: \{err}")
  }
  let lines = storage_status_porcelain_lines(fs, root, true) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "## main")
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain lines report staged add modify delete" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-staged"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, "init", ["-q"]) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  fs.write_string(root + "/c.txt", "remove\n")
  run_storage_command(fs, fs, root, "add", ["a.txt", "c.txt"]) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(fs, fs, root, "commit", ["-q", "-m", "base"]) catch {
    err => fail("commit failed: \{err}")
  }

  fs.write_string(root + "/a.txt", "changed\n")
  run_storage_command(fs, fs, root, "add", ["a.txt"]) catch {
    err => fail("stage modified failed: \{err}")
  }
  fs.write_string(root + "/b.txt", "new\n")
  run_storage_command(fs, fs, root, "add", ["b.txt"]) catch {
    err => fail("stage added failed: \{err}")
  }
  fs.remove_file(root + "/c.txt") catch {
    err => fail("remove file failed: \{err}")
  }
  run_storage_command(fs, fs, root, "add", ["c.txt"]) catch {
    err => fail("stage deleted failed: \{err}")
  }

  let lines = storage_status_porcelain_lines(fs, root, false) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(storage_runtime_wbtest_has_line(lines, "M  a.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "A  b.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "D  c.txt"))

  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}
