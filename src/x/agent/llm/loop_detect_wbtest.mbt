///| Tests for loop detection

///|
test "LoopTracker detects repeated calls" {
  let tracker = LoopTracker::new()
  let input : Json = { "path": "src/main.mbt" }
  let r1 = tracker.check_and_record("list_directory", input)
  assert_eq(r1, "")
  let r2 = tracker.check_and_record("list_directory", input)
  assert_eq(r2, "")
  let r3 = tracker.check_and_record("list_directory", input)
  assert_true(r3.contains("Loop detected"))
  assert_true(r3.contains("write_file"))
}

///|
test "LoopTracker resets on different tool" {
  let tracker = LoopTracker::new()
  let input : Json = { "path": "src/main.mbt" }
  let _ = tracker.check_and_record("list_directory", input)
  let _ = tracker.check_and_record("list_directory", input)
  // Interject with a different tool
  let _ = tracker.check_and_record("read_file", { "path": "other.mbt" })
  // Resume list_directory — count should reset
  let r = tracker.check_and_record("list_directory", input)
  assert_eq(r, "")
}

///|
test "LoopTracker resets on different key" {
  let tracker = LoopTracker::new()
  let _ = tracker.check_and_record("read_file", { "path": "a.mbt" })
  let _ = tracker.check_and_record("read_file", { "path": "a.mbt" })
  // Same tool, different key — should not trigger
  let _ = tracker.check_and_record("read_file", { "path": "b.mbt" })
  let r = tracker.check_and_record("read_file", { "path": "a.mbt" })
  assert_eq(r, "")
}

///|
test "extract_tool_key for file tools" {
  let input : Json = { "path": "src/lib.mbt" }
  assert_eq(extract_tool_key("read_file", input), "src/lib.mbt")
  assert_eq(extract_tool_key("write_file", input), "src/lib.mbt")
  assert_eq(extract_tool_key("list_directory", input), "src/lib.mbt")
  assert_eq(extract_tool_key("remove_file", input), "src/lib.mbt")
  assert_eq(extract_tool_key("list_files_recursive", input), "src/lib.mbt")
}

///|
test "extract_tool_key for search and command" {
  assert_eq(
    extract_tool_key("search_text", { "pattern": "fn main" }),
    "fn main",
  )
  assert_eq(
    extract_tool_key("run_command", { "command": "moon test" }),
    "moon test",
  )
}

///|
test "progress nudge after threshold without write_file" {
  let tracker = LoopTracker::new(write_nudge_threshold=5)
  // 5 read-only calls without write_file
  for i = 0; i < 4; i = i + 1 {
    let r = tracker.check_and_record("read_file", {
      "path": "file" + i.to_string() + ".mbt",
    })
    assert_eq(r, "")
  }
  // 5th call triggers progress nudge
  let r = tracker.check_and_record("search_text", { "pattern": "test" })
  assert_true(r.contains("No progress"))
  assert_true(r.contains("write_file"))
}

///|
test "progress nudge resets after write_file" {
  let tracker = LoopTracker::new(write_nudge_threshold=3)
  let _ = tracker.check_and_record("read_file", { "path": "a.mbt" })
  let _ = tracker.check_and_record("read_file", { "path": "b.mbt" })
  // write_file resets the counter
  let _ = tracker.check_and_record("write_file", {
    "path": "c.mbt",
    "content": "x",
  })
  // 2 more read-only calls — should not trigger (only 2, threshold is 3)
  let r1 = tracker.check_and_record("read_file", { "path": "d.mbt" })
  assert_eq(r1, "")
  let r2 = tracker.check_and_record("read_file", { "path": "e.mbt" })
  assert_eq(r2, "")
}

///|
test "progress nudge does not fire on non-read-only tools" {
  let tracker = LoopTracker::new(write_nudge_threshold=3)
  for i = 0; i < 3; i = i + 1 {
    let _ = tracker.check_and_record("run_command", {
      "command": "cmd" + i.to_string(),
    })

  }
  // run_command is not read-only, so no progress nudge
  let r = tracker.check_and_record("run_command", { "command": "cmd4" })
  assert_eq(r, "")
}

///|
test "is_read_only_tool classification" {
  assert_true(is_read_only_tool("read_file"))
  assert_true(is_read_only_tool("list_directory"))
  assert_true(is_read_only_tool("list_files_recursive"))
  assert_true(is_read_only_tool("search_text"))
  assert_false(is_read_only_tool("write_file"))
  assert_false(is_read_only_tool("run_command"))
  assert_false(is_read_only_tool("remove_file"))
}
