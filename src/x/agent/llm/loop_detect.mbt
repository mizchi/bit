///| Loop detection for agent tool calls

///|
priv struct LoopTracker {
  history : Array[(String, String)] // (tool_name, key_arg)
  max_repeat : Int // default 3
  mut calls_since_write : Int // tool calls since last write_file
  write_nudge_threshold : Int // default 10
}

///|
fn LoopTracker::new(
  max_repeat? : Int = 3,
  write_nudge_threshold? : Int = 10,
) -> LoopTracker {
  { history: [], max_repeat, calls_since_write: 0, write_nudge_threshold }
}

///|
fn extract_tool_key(name : String, input : Json) -> String {
  match name {
    "read_file"
    | "write_file"
    | "remove_file"
    | "list_directory"
    | "list_files_recursive" => json_get_str(input, "path")
    "search_text" => json_get_str(input, "pattern")
    "run_command" => json_get_str(input, "command")
    _ => ""
  }
}

///|
fn is_read_only_tool(name : String) -> Bool {
  match name {
    "read_file" | "list_directory" | "list_files_recursive" | "search_text" =>
      true
    _ => false
  }
}

///|
fn LoopTracker::check_and_record(
  self : LoopTracker,
  name : String,
  input : Json,
) -> String {
  let key = extract_tool_key(name, input)
  self.history.push((name, key))
  // Track calls since last write_file
  if name == "write_file" {
    self.calls_since_write = 0
  } else {
    self.calls_since_write = self.calls_since_write + 1
  }
  // Progress nudge: too many calls without write_file
  if self.calls_since_write >= self.write_nudge_threshold &&
    is_read_only_tool(name) {
    return "[No progress] You have made " +
      self.calls_since_write.to_string() +
      " tool calls without using write_file. Stop exploring and start implementing. Use write_file to make changes now."
  }
  // Count consecutive identical (name, key) pairs from the end
  let len = self.history.length()
  let mut count = 0
  for i = len - 1; i >= 0; i = i - 1 {
    let (n, k) = self.history[i]
    if n == name && k == key {
      count = count + 1
    } else {
      break
    }
  }
  if count >= self.max_repeat {
    return nudge_message(name)
  }
  ""
}

///|
fn nudge_message(name : String) -> String {
  match name {
    "list_directory" | "list_files_recursive" =>
      "[Loop detected] You have called " +
      name +
      " on the same path multiple times. Stop exploring and use write_file to make changes."
    "read_file" =>
      "[Loop detected] You have read the same file multiple times. You have enough information. Use write_file to make your changes now."
    "run_command" =>
      "[Loop detected] The same command keeps producing the same result. Read the error output carefully and use write_file to fix the code before running again."
    "search_text" =>
      "[Loop detected] You have searched the same pattern multiple times. Use read_file on relevant results, then write_file to make changes."
    _ =>
      "[Loop detected] You are repeating the same action. Try a different approach or use write_file to make progress."
  }
}

///|
fn tracked_handler(
  tracker : LoopTracker,
  name : String,
  handler : (Json) -> String,
) -> (Json) -> String {
  fn(input) {
    let nudge = tracker.check_and_record(name, input)
    if not(nudge.is_empty()) {
      return nudge
    }
    handler(input)
  }
}
