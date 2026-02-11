///|
test "helpers: resolve_git_dir falls back to bare repo when GIT_DIR points missing .git" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-resolve-git-dir-bare-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/objects")
  fs.write_string(root + "/HEAD", "ref: refs/heads/main\n")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  @sys.set_env_var("GIT_DIR", root + "/.git")
  let resolved = resolve_git_dir(fs, root)
  assert_eq(resolved, root)
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  fs.remove_file(root + "/HEAD") catch {
    _ => ()
  }
  fs.remove_dir(root + "/objects") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "helpers: find_repo_root detects .bit repository marker" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-find-repo-root-bit-" +
    get_current_timestamp().to_string()
  let nested = root + "/a/b/c"
  fs.mkdir_p(root + "/.bit/objects")
  fs.write_string(root + "/.bit/HEAD", "ref: refs/heads/main\n")
  fs.mkdir_p(nested)
  let found = find_repo_root(nested)
  match found {
    Some(path) => assert_eq(path, root)
    None => fail("expected .bit repo root")
  }
  fs.remove_file(root + "/.bit/HEAD") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/objects") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root + "/a/b/c") catch {
    _ => ()
  }
  fs.remove_dir(root + "/a/b") catch {
    _ => ()
  }
  fs.remove_dir(root + "/a") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "helpers: resolve_git_dir prefers .bit when present" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-resolve-git-dir-bit-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.bit")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_DIR")
  let resolved = resolve_git_dir(fs, root)
  assert_eq(resolved, root + "/.bit")
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "helpers: resolve_git_dir keeps explicit GIT_DIR even if .bit exists" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-resolve-git-dir-explicit-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.bit")
  fs.mkdir_p(root + "/custom-meta")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  @sys.set_env_var("GIT_DIR", root + "/custom-meta")
  let resolved = resolve_git_dir(fs, root)
  assert_eq(resolved, root + "/custom-meta")
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  fs.remove_dir(root + "/custom-meta") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "helpers: parse_run_git_invocation maps --version to internal version command" {
  let parsed = parse_run_git_invocation(["--version"], None)
  match parsed {
    Some(invocation) => {
      assert_eq(invocation.cmd, "version")
      assert_eq(invocation.rest.length(), 0)
    }
    None => fail("expected parsed invocation")
  }
}

///|
test "helpers: parse_run_git_invocation keeps unknown command token for dispatch" {
  let parsed = parse_run_git_invocation(["unknown-bit-dispatch"], None)
  match parsed {
    Some(invocation) => {
      assert_eq(invocation.cmd, "unknown-bit-dispatch")
      assert_eq(invocation.rest.length(), 0)
    }
    None => fail("expected parsed invocation")
  }
}

///|
test "helpers: parse_git_env_timestamp supports timezone suffix" {
  assert_eq(parse_git_env_timestamp("1234567890 -0700"), Some(1234567890L))
  assert_eq(parse_git_env_timestamp("@1234567890 +0900"), Some(1234567890L))
}

///|
test "helpers: parse_git_env_timezone extracts timezone token" {
  assert_eq(parse_git_env_timezone("1234567890 -0700"), Some("-0700"))
  assert_eq(parse_git_env_timezone("@1234567890 +0900"), Some("+0900"))
}

///|
test "helpers: get_commit_timestamp parses git-style committer date" {
  let prev = @sys.get_env_var("GIT_COMMITTER_DATE")
  @sys.set_env_var("GIT_COMMITTER_DATE", "1234567890 -0700")
  assert_eq(get_commit_timestamp(), 1234567890L)
  match prev {
    Some(value) => @sys.set_env_var("GIT_COMMITTER_DATE", value)
    None => @sys.unset_env_var("GIT_COMMITTER_DATE")
  }
}

///|
test "helpers: get_commit_timezone parses git-style committer date" {
  let prev = @sys.get_env_var("GIT_COMMITTER_DATE")
  @sys.set_env_var("GIT_COMMITTER_DATE", "1234567890 -0700")
  assert_eq(get_commit_timezone(), "-0700")
  match prev {
    Some(value) => @sys.set_env_var("GIT_COMMITTER_DATE", value)
    None => @sys.unset_env_var("GIT_COMMITTER_DATE")
  }
}

///|
test "main: resolve_global_path uses GIT_SHIM_PWD when available" {
  let prev = @sys.get_env_var("GIT_SHIM_PWD")
  @sys.set_env_var("GIT_SHIM_PWD", "/tmp/bit-main-wbtest")
  let resolved = resolve_global_path("dest", None)
  assert_eq(resolved, "/tmp/bit-main-wbtest/dest")
  match prev {
    Some(value) => @sys.set_env_var("GIT_SHIM_PWD", value)
    None => @sys.unset_env_var("GIT_SHIM_PWD")
  }
}

///|
test "main: resolve_global_path resolves relative path without GIT_SHIM_PWD" {
  let prev = @sys.get_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_SHIM_PWD")
  let resolved = resolve_global_path("dest", None)
  assert_true(resolved.has_prefix("/"))
  assert_true(resolved.has_suffix("/dest"))
  match prev {
    Some(value) => @sys.set_env_var("GIT_SHIM_PWD", value)
    None => @sys.unset_env_var("GIT_SHIM_PWD")
  }
}

///|
test "main: parse_global_options resolves -C relative path without GIT_SHIM_PWD" {
  let prev = @sys.get_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_SHIM_PWD")
  let opts = parse_global_options(["bit", "-C", "dest", "status"])
  assert_eq(opts.subcmd, Some("status"))
  match opts.cwd {
    Some(path) => {
      assert_true(path.has_prefix("/"))
      assert_true(path.has_suffix("/dest"))
    }
    None => fail("expected cwd to be resolved")
  }
  match prev {
    Some(value) => @sys.set_env_var("GIT_SHIM_PWD", value)
    None => @sys.unset_env_var("GIT_SHIM_PWD")
  }
}

///|
async test "main: show_command_help supports pr alias" {
  let ok = show_command_help("pr")
  assert_true(ok)
}

///|
async test "main: show_command_help supports issue alias" {
  let ok = show_command_help("issue")
  assert_true(ok)
}

///|
async test "main: show_command_help supports hub command" {
  let ok = show_command_help("hub")
  assert_true(ok)
}

///|
test "main: command_handles_builtin_help allows agent subcommand-specific help" {
  assert_true(command_handles_builtin_help("agent"))
}

test "main: normalize_dispatch_command maps ws to workspace" {
  assert_eq(normalize_dispatch_command("ws"), "workspace")
}
