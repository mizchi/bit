///| E2E tests for run_llm_agent with MockProvider

///|
fn make_e2e_config(
  env : &ToolEnvironment,
  provider : @llmlib.BoxedProvider,
  max_steps? : Int = 20,
  coord_dir? : String = "",
  agent_id? : String = "",
  coord? : &CoordinationBackend? = None,
) -> LlmAgentConfig {
  {
    work_dir: "/test",
    task: "test task",
    branch_name: "test-branch",
    target_branch: "main",
    provider_name: "mock",
    model: "mock",
    max_steps,
    auto_commit: false,
    auto_pr: false,
    pr_title: "",
    verbose: false,
    coord_dir,
    agent_id,
    env: Some(env),
    coord,
    provider: Some(provider),
  }
}

///|
test "e2e agent reads and writes file" {
  let env = TestToolEnvironment::new()
  env.files["src/main.mbt"] = "old content"
  let provider = @llmlib.MockProvider::new([
    // Step 1: read_file
    [
      @llmlib.MessageStart,
      @llmlib.ToolCallStart(id="call_1", name="read_file"),
      @llmlib.ToolCallEnd(id="call_1", name="read_file", input={
        "path": "src/main.mbt".to_json(),
      }),
      @llmlib.MessageEnd(finish_reason=@llmlib.ToolUse, usage=None),
    ],
    // Step 2: write_file
    [
      @llmlib.MessageStart,
      @llmlib.ToolCallStart(id="call_2", name="write_file"),
      @llmlib.ToolCallEnd(id="call_2", name="write_file", input={
        "path": "src/main.mbt".to_json(),
        "content": "new content".to_json(),
      }),
      @llmlib.MessageEnd(finish_reason=@llmlib.ToolUse, usage=None),
    ],
    // Step 3: text only (done)
    [
      @llmlib.MessageStart,
      @llmlib.TextDelta("Done!"),
      @llmlib.MessageEnd(finish_reason=@llmlib.Stop, usage=None),
    ],
  ])
  let output = StringBuilder::new()
  run_llm_agent(make_e2e_config(env, provider.boxed()), on_output=fn(s) {
    output.write_string(s)
  })
  assert_eq(env.files.get("src/main.mbt"), Some("new content"))
  assert_true(output.to_string().contains("no_tool_calls"))
}

///|
test "e2e agent hits max steps" {
  let env = TestToolEnvironment::new()
  env.files["a.mbt"] = "content"
  let make_read : () -> Array[@llmlib.StreamEvent] = fn() {
    [
      @llmlib.MessageStart,
      @llmlib.ToolCallStart(id="call_1", name="read_file"),
      @llmlib.ToolCallEnd(id="call_1", name="read_file", input={
        "path": "a.mbt".to_json(),
      }),
      @llmlib.MessageEnd(finish_reason=@llmlib.ToolUse, usage=None),
    ]
  }
  let provider = @llmlib.MockProvider::new([
    make_read(),
    make_read(),
    make_read(),
  ])
  let done_reason = Ref::new("")
  run_llm_agent(make_e2e_config(env, provider.boxed(), max_steps=2), on_output=fn(
    s,
  ) {
    if s.contains("[done]") {
      done_reason.val = s
    }
  })
  assert_true(done_reason.val.contains("max_steps"))
}

///|
test "e2e agent loop detection nudge" {
  let env = TestToolEnvironment::new()
  env.files["src/main.mbt"] = "content"
  // Same read_file 4 times to trigger loop detection (threshold = 3)
  let make_same_read : () -> Array[@llmlib.StreamEvent] = fn() {
    [
      @llmlib.MessageStart,
      @llmlib.ToolCallStart(id="call_1", name="read_file"),
      @llmlib.ToolCallEnd(id="call_1", name="read_file", input={
        "path": "src/main.mbt".to_json(),
      }),
      @llmlib.MessageEnd(finish_reason=@llmlib.ToolUse, usage=None),
    ]
  }
  let provider = @llmlib.MockProvider::new([
    make_same_read(),
    make_same_read(),
    make_same_read(),
    make_same_read(),
    // After nudge, respond with text only
    [
      @llmlib.MessageStart,
      @llmlib.TextDelta("OK"),
      @llmlib.MessageEnd(finish_reason=@llmlib.Stop, usage=None),
    ],
  ])
  let config = make_e2e_config(env, provider.boxed(), max_steps=10)
  let output = StringBuilder::new()
  run_llm_agent(config, on_output=fn(s) { output.write_string(s) })
  // The test verifies that the agent completed without hanging
  assert_true(output.to_string().contains("no_tool_calls"))
}

///|
test "e2e agent with coordination" {
  let env = TestToolEnvironment::new()
  env.files["src/main.mbt"] = "old"
  let provider = @llmlib.MockProvider::new([
    // Step 1: write_file
    [
      @llmlib.MessageStart,
      @llmlib.ToolCallStart(id="call_1", name="write_file"),
      @llmlib.ToolCallEnd(id="call_1", name="write_file", input={
        "path": "src/main.mbt".to_json(),
        "content": "new".to_json(),
      }),
      @llmlib.MessageEnd(finish_reason=@llmlib.ToolUse, usage=None),
    ],
    // Step 2: done
    [
      @llmlib.MessageStart,
      @llmlib.TextDelta("Done"),
      @llmlib.MessageEnd(finish_reason=@llmlib.Stop, usage=None),
    ],
  ])
  // Use a simple in-memory coordination backend
  let coord = TestCoordinationBackend::new()
  let coord_ref : &CoordinationBackend = coord
  let config = make_e2e_config(
    env,
    provider.boxed(),
    coord_dir="test-session",
    agent_id="agent-0",
    coord=Some(coord_ref),
  )
  let output = StringBuilder::new()
  run_llm_agent(config, on_output=fn(s) { output.write_string(s) })
  assert_eq(env.files.get("src/main.mbt"), Some("new"))
  // Verify coordination events were written
  assert_true(coord.events.length() > 0)
  let has_file_changed = coord.events
    .iter()
    .any(fn(e) { e.contains("file_changed") })
  assert_true(has_file_changed)
  let has_step = coord.events.iter().any(fn(e) { e.contains("step_completed") })
  assert_true(has_step)
  let has_finished = coord.events.iter().any(fn(e) { e.contains("finished") })
  assert_true(has_finished)
}

///|
test "e2e agent no tool calls" {
  let env = TestToolEnvironment::new()
  let provider = @llmlib.MockProvider::new([
    [
      @llmlib.MessageStart,
      @llmlib.TextDelta("I have completed the task."),
      @llmlib.MessageEnd(finish_reason=@llmlib.Stop, usage=None),
    ],
  ])
  let output = StringBuilder::new()
  run_llm_agent(make_e2e_config(env, provider.boxed()), on_output=fn(s) {
    output.write_string(s)
  })
  let out = output.to_string()
  assert_true(out.contains("no_tool_calls"))
  assert_true(out.contains("I have completed the task."))
}

///|
/// In-memory coordination backend for testing
priv struct TestCoordinationBackend {
  statuses : Map[String, AgentStatus]
  steps : Map[String, Int]
  events : Array[String]
}

///|
fn TestCoordinationBackend::new() -> TestCoordinationBackend {
  { statuses: {}, steps: {}, events: [] }
}

///|
impl CoordinationBackend for TestCoordinationBackend with init_session(
  _self,
  session_id,
) {
  session_id
}

///|
impl CoordinationBackend for TestCoordinationBackend with init_agent(
  _self,
  _dir,
  _agent_id,
) {

}

///|
impl CoordinationBackend for TestCoordinationBackend with write_status(
  self,
  _dir,
  agent_id,
  status,
) {
  self.statuses[agent_id] = status
}

///|
impl CoordinationBackend for TestCoordinationBackend with write_step(
  self,
  _dir,
  agent_id,
  step,
) {
  self.steps[agent_id] = step
}

///|
impl CoordinationBackend for TestCoordinationBackend with write_pid(
  _self,
  _dir,
  _agent_id,
  _pid,
) {

}

///|
impl CoordinationBackend for TestCoordinationBackend with write_branch(
  _self,
  _dir,
  _agent_id,
  _branch,
) {

}

///|
impl CoordinationBackend for TestCoordinationBackend with append_event(
  self,
  _dir,
  _agent_id,
  event,
) {
  self.events.push(coord_event_to_json(event))
}

///|
impl CoordinationBackend for TestCoordinationBackend with read_status(
  self,
  _dir,
  agent_id,
) {
  match self.statuses.get(agent_id) {
    Some(s) => s
    None => Pending
  }
}

///|
impl CoordinationBackend for TestCoordinationBackend with read_all_agents(
  _self,
  _dir,
) {
  []
}

///|
impl CoordinationBackend for TestCoordinationBackend with read_events_since(
  self,
  _dir,
  _agent_id,
  _since,
) {
  self.events.copy()
}

///|
impl CoordinationBackend for TestCoordinationBackend with cleanup(_self, _dir) {

}
