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
