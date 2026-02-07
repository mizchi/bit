///|
test "interactive: detect add patch mode" {
  assert_true(has_interactive_add_flag(["-p"]))
  assert_true(has_interactive_add_flag(["--patch", "README.md"]))
  assert_false(has_interactive_add_flag(["README.md"]))
}

///|
async test "interactive: add patch runner callback is invoked" {
  let called : Array[String] = []
  let runner = Some(async fn(args : Array[String]) -> Int noraise {
    for arg in args {
      called.push(arg)
    }
    0
  })
  run_add_interactive(["-p", "README.md"], runner~)
  assert_eq(called.length(), 2)
  assert_eq(called[0], "-p")
  assert_eq(called[1], "README.md")
}

///|
async test "interactive: rebase todo editor callback is invoked" {
  let edited_paths : Array[String] = []
  let editor = Some(async fn(path : String) -> Bool noraise {
    edited_paths.push(path)
    true
  })
  let edited = edit_rebase_todo("/tmp/git-rebase-todo", editor~)
  assert_true(edited)
  assert_eq(edited_paths.length(), 1)
  assert_eq(edited_paths[0], "/tmp/git-rebase-todo")
}

///|
test "interactive: resolve commit editor precedence" {
  @sys.set_env_var("EDITOR", "vi")
  @sys.set_env_var("VISUAL", "nvim")
  @sys.set_env_var("GIT_EDITOR", "hx")
  let selected = resolve_commit_editor()
  match selected {
    Some(cmd) => assert_eq(cmd, "hx")
    None => fail("expected editor")
  }
  @sys.unset_env_var("GIT_EDITOR")
  @sys.unset_env_var("VISUAL")
  @sys.unset_env_var("EDITOR")
}

///|
test "interactive: normalize commit edit buffer removes comments" {
  let raw =
    #|
    #|# Please enter the commit message
    #|feat: add x
    #|
    #|body line
    #|# end
  let msg = normalize_commit_edit_buffer(raw)
  match msg {
    Some(text) => assert_eq(text, "feat: add x\n\nbody line")
    None => fail("expected commit message")
  }
}

///|
async test "interactive: commit message editor callback is invoked" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-commit-editor-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.git")
  let edited_paths : Array[String] = []
  let editor = Some(async fn(path : String) -> Bool raise Error {
    edited_paths.push(path)
    fs.write_string(path, "feat: from editor\n\n# comment\nbody\n")
    true
  })
  let message = read_commit_message_from_editor(fs, root, editor~)
  match message {
    Some(text) => assert_eq(text, "feat: from editor\n\nbody")
    None => fail("expected commit message")
  }
  assert_eq(edited_paths.length(), 1)
  assert_eq(edited_paths[0], root + "/.git/COMMIT_EDITMSG")
  fs.remove_file(root + "/.git/COMMIT_EDITMSG") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.git") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}
