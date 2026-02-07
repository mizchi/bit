///|
priv struct WorkerTask {
  task : String
  work_dir : String
  branch : String
  agent_id : String
}

///|
priv struct SubtaskPlan {
  task : String
  files : Array[String] // file scope for this subtask
}

///|
pub(all) struct OrchestratorConfig {
  work_dir : String
  task : String
  provider_name : String
  model : String
  max_workers : Int
  target_branch : String
  auto_pr : Bool
  verbose : Bool
  in_process : Bool // true = run agents in-process (sequential), false = spawn processes
}

///|
/// Abstraction for how agents are executed
pub(open) trait AgentRunner {
  /// Spawn an agent. Returns a handle identifier (e.g., PID string or agent_id).
  spawn_agent(Self, config : LlmAgentConfig, log_file : String) -> String
  /// Wait for all spawned agents to complete. Polls/blocks until done or timeout.
  wait_all(
    Self,
    session_dir : String,
    timeout_seconds : Int,
    log : (String) -> Unit,
  ) -> Unit
  /// Cancel a specific agent by its handle/id.
  cancel_agent(Self, handle : String) -> Unit
}

///|
/// Runs agents as separate OS processes via nohup
priv struct ProcessAgentRunner {
  bit_binary : String
  provider_name : String
  model : String
  verbose : Bool
}

///|
fn ProcessAgentRunner::new(
  provider_name : String,
  model : String,
  verbose : Bool,
) -> ProcessAgentRunner {
  { bit_binary: find_bit_binary(), provider_name, model, verbose }
}

///|
impl AgentRunner for ProcessAgentRunner with spawn_agent(self, config, log_file) {
  let cmd = "nohup " +
    shell_escape(self.bit_binary) +
    " agent llm" +
    " --task " +
    shell_escape(config.task) +
    " --work-dir " +
    shell_escape(config.work_dir) +
    " --branch " +
    shell_escape(config.branch_name) +
    " --provider " +
    shell_escape(self.provider_name) +
    (if self.model.is_empty() {
      ""
    } else {
      " --model " + shell_escape(self.model)
    }) +
    " --coord-dir " +
    shell_escape(config.coord_dir) +
    " --agent-id " +
    shell_escape(config.agent_id) +
    " --no-commit" +
    " > " +
    shell_escape(log_file) +
    " 2>&1 & echo $!"
  strip_trailing_whitespace(exec(cmd))
}

///|
impl AgentRunner for ProcessAgentRunner with wait_all(
  self,
  session_dir,
  timeout_seconds,
  log,
) {
  let max_iterations = timeout_seconds / 2
  let mut iteration = 0
  while iteration < max_iterations {
    ignore(exec("sleep 2"))
    iteration += 1
    let snapshots = coord_read_all_agents(session_dir)
    let now_str = strip_trailing_whitespace(exec("date +%s"))
    let now = (@strconv.parse_int(now_str) catch { _ => 0 }).to_int64()
    let decision = evaluate_progress(snapshots, session_dir, now, log)
    match decision {
      AllDone => {
        if self.verbose {
          log("[orchestrator] All agents completed.")
        }
        break
      }
      CancelAgent(id~, reason~) => {
        if self.verbose {
          log("[orchestrator] Cancelling " + id + ": " + reason)
        }
        for s in snapshots {
          if s.agent_id == id && s.pid > 0 {
            ignore(exec("kill " + s.pid.to_string() + " 2>/dev/null"))
            coord_write_status(session_dir, id, Cancelled)
          }
        }
      }
      Continue =>
        if self.verbose && iteration % 5 == 0 {
          for s in snapshots {
            let elapsed = if s.last_step_time > 0L && now > s.last_step_time {
              " elapsed=" + (now - s.last_step_time).to_string() + "s"
            } else {
              ""
            }
            log(
              "  " +
              s.agent_id +
              ": " +
              s.status.to_string() +
              " step=" +
              s.step.to_string() +
              elapsed,
            )
          }
        }
    }
  }
  if iteration >= max_iterations {
    log("[orchestrator] Timeout reached, killing remaining agents...")
    let snapshots = coord_read_all_agents(session_dir)
    for s in snapshots {
      if s.status == Running && s.pid > 0 {
        ignore(exec("kill " + s.pid.to_string() + " 2>/dev/null"))
        coord_write_status(session_dir, s.agent_id, Cancelled)
      }
    }
  }
}

///|
impl AgentRunner for ProcessAgentRunner with cancel_agent(_self, handle) {
  ignore(exec("kill " + handle + " 2>/dev/null"))
}

///|
/// Runs agents in-process sequentially (no OS process spawn)
priv struct InProcessAgentRunner {
  verbose : Bool
  results : Map[String, Bool] // agent_id -> completed
  cancelled : Map[String, Bool]
}

///|
fn InProcessAgentRunner::new(
  _provider_name : String,
  _model : String,
  verbose : Bool,
) -> InProcessAgentRunner {
  { verbose, results: {}, cancelled: {} }
}

///|
impl AgentRunner for InProcessAgentRunner with spawn_agent(
  self,
  config,
  _log_file,
) {
  let agent_id = config.agent_id
  // Run the agent immediately (blocking) with cancellation support
  run_llm_agent(config, on_output=fn(s) { if self.verbose { ignore(s) } }, should_cancel=fn() {
    self.cancelled.get(agent_id) == Some(true)
  })
  self.results[agent_id] = true
  agent_id
}

///|
impl AgentRunner for InProcessAgentRunner with wait_all(
  _self,
  _session_dir,
  _timeout_seconds,
  _log,
) {
  // All agents already completed in spawn_agent (synchronous)
}

///|
impl AgentRunner for InProcessAgentRunner with cancel_agent(self, handle) {
  self.cancelled[handle] = true
}

///|
fn extract_subtask_plans(text : String) -> Array[SubtaskPlan] {
  // Try to find JSON array in the text
  let chars : Array[Char] = []
  for ch in text {
    chars.push(ch)
  }
  let mut start = -1
  let mut end_ = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '[' && start < 0 {
      start = i
    }
    if chars[i] == ']' {
      end_ = i
    }
  }
  if start < 0 || end_ < 0 {
    return []
  }
  let buf = StringBuilder::new()
  for i = start; i <= end_; i = i + 1 {
    buf.write_char(chars[i])
  }
  let json = @json.parse(buf.to_string()) catch { _ => return [] }
  let plans : Array[SubtaskPlan] = []
  match json {
    Array(items) =>
      for item in items {
        match item {
          // New format: {"task": "...", "files": ["..."]}
          Object(m) => {
            let task = match m.get("task") {
              Some(String(s)) => s
              _ => continue
            }
            let files : Array[String] = []
            match m.get("files") {
              Some(Array(arr)) =>
                for f in arr {
                  match f {
                    String(s) => files.push(s)
                    _ => ()
                  }
                }
              _ => ()
            }
            plans.push({ task, files })
          }
          // Legacy format: plain string
          String(s) => plans.push({ task: s, files: [] })
          _ => ()
        }
      }
    _ => ()
  }
  plans
}

///|
fn validate_file_overlap(plans : Array[SubtaskPlan]) -> Array[String] {
  let seen : Map[String, Int] = {}
  let conflicts : Array[String] = []
  for i, plan in plans {
    for file in plan.files {
      match seen.get(file) {
        Some(prev) =>
          conflicts.push(
            file +
            " (subtask " +
            prev.to_string() +
            " and " +
            i.to_string() +
            ")",
          )
        None => seen[file] = i
      }
    }
  }
  conflicts
}

///|
fn plan_subtasks(
  config : OrchestratorConfig,
  log : (String) -> Unit,
) -> Array[String] {
  let file_listing = exec(
    "find " +
    shell_escape(config.work_dir) +
    " -maxdepth 3 -not -path '*/.*' -type f | head -200",
  )
  let system_prompt =
    #|You are a task planner for a coding project.
    #|Break down the given task into independent subtasks that can be executed in parallel by coding agents.
    #|Each subtask MUST be independent — no file overlap between subtasks.
    #|
    #|Respond with ONLY a JSON array of objects. Each object has:
    #|- "task": description of the subtask
    #|- "files": array of file paths this subtask will modify (write-scope)
    #|
    #|Example:
    #|[
    #|  {"task": "Add tests for math module", "files": ["src/math_test.mbt"]},
    #|  {"task": "Add tests for string module", "files": ["src/string_test.mbt"]}
    #|]
    #|
    #|CRITICAL: No two subtasks may list the same file. If tasks share dependencies, combine them into one subtask.
  let provider = create_provider(
    config.provider_name,
    config.model,
    system_prompt,
  )
  let user_msg = "Project files:\n" +
    file_listing +
    "\n\nTask: " +
    config.task +
    "\n\nPlan " +
    config.max_workers.to_string() +
    " or fewer subtasks."
  let messages : Array[@llmlib.Message] = [@llmlib.Message::user(user_msg)]
  let response = @llmlib.collect_text(provider.inner, messages)
  if config.verbose {
    log("[planner] LLM response:\n" + response)
  }
  let plans = extract_subtask_plans(response)
  if plans.is_empty() {
    return [config.task]
  }
  // Validate file overlap
  let conflicts = validate_file_overlap(plans)
  if not(conflicts.is_empty()) {
    if config.verbose {
      log(
        "[planner] File overlap detected, falling back to single task: " +
        conflicts.iter().map(fn(s) { s }).collect().join(", "),
      )
    }
    return [config.task]
  }
  // Build task descriptions with file scope hints
  let tasks : Array[String] = []
  for plan in plans {
    if plan.files.is_empty() {
      tasks.push(plan.task)
    } else {
      tasks.push(plan.task + " (files: " + plan.files.join(", ") + ")")
    }
  }
  tasks
}

///|
/// Find the bit binary path for spawning sub-agents
fn find_bit_binary() -> String {
  let env = @ffi.get_env("BIT_PATH")
  if not(env.is_empty()) {
    return env
  }
  let which = strip_trailing_whitespace(exec("which bit 2>/dev/null"))
  if not(which.is_empty()) {
    return which
  }
  "bit"
}

///|
/// Monitor decision
priv enum MonitorDecision {
  Continue
  CancelAgent(id~ : String, reason~ : String)
  AllDone
}

///|
/// Evaluate progress of all agents and decide next action
fn evaluate_progress(
  snapshots : Array[AgentSnapshot],
  session_dir : String,
  now : Int64,
  _log : (String) -> Unit,
) -> MonitorDecision {
  let mut all_done = true
  for s in snapshots {
    match s.status {
      Running | Pending => {
        all_done = false
        // Check for excessive errors (3+ consecutive error events)
        let events = coord_read_events_since(session_dir, s.agent_id, 0)
        let mut consecutive_errors = 0
        for ev in events {
          if ev.contains("\"type\":\"error\"") {
            consecutive_errors += 1
          } else {
            consecutive_errors = 0
          }
        }
        if consecutive_errors >= 3 {
          return CancelAgent(
            id=s.agent_id,
            reason="3+ consecutive errors detected",
          )
        }
        // Check for stall: no progress for 5 minutes
        if s.step > 0 && s.last_step_time > 0L && now - s.last_step_time > 300L {
          return CancelAgent(
            id=s.agent_id,
            reason="stalled: no progress for 5 minutes",
          )
        }
      }
      _ => ()
    }
  }
  if all_done {
    return AllDone
  }
  Continue
}

///|
pub fn run_orchestrator(
  config : OrchestratorConfig,
  on_output~ : (String) -> Unit,
) -> Unit {
  let verbose = config.verbose
  let wd = config.work_dir
  let log = fn(s : String) { on_output(s + "\n") }
  // Step 1: Plan subtasks
  if verbose {
    log("[orchestrator] Planning subtasks...")
  }
  let subtasks = plan_subtasks(config, log)
  if verbose {
    log(
      "[orchestrator] Planned " + subtasks.length().to_string() + " subtasks:",
    )
    for i, task in subtasks {
      log("  " + (i + 1).to_string() + ". " + task)
    }
  }
  // If only 1 subtask, run directly (no need for parallel overhead)
  if subtasks.length() == 1 {
    if verbose {
      log("[orchestrator] Single subtask, running directly...")
    }
    let agent_config : LlmAgentConfig = {
      work_dir: wd,
      task: subtasks[0],
      branch_name: "agent/" + strip_trailing_whitespace(exec("date +%s")),
      target_branch: config.target_branch,
      provider_name: config.provider_name,
      model: config.model,
      max_steps: 20,
      auto_commit: true,
      auto_pr: config.auto_pr,
      pr_title: "",
      verbose: config.verbose,
      coord_dir: "",
      agent_id: "",
      env: None,
      coord: None,
      provider: None,
    }
    run_llm_agent(agent_config, on_output~)
    return
  }
  // Step 2: Setup coordination directory + worktrees
  let ts = strip_trailing_whitespace(exec("date +%s"))
  let session_dir = coord_init("/tmp", ts)
  if verbose {
    log("[orchestrator] Coordination dir: " + session_dir)
  }
  let workers : Array[WorkerTask] = []
  for i, task in subtasks {
    let agent_id = "agent-" + i.to_string()
    let branch = "agent/" + ts + "-" + i.to_string()
    let wt_dir = "/tmp/bit-agent-" + ts + "-" + i.to_string()
    coord_init_agent(session_dir, agent_id)
    coord_write_status(session_dir, agent_id, Pending)
    coord_write_branch(session_dir, agent_id, branch)
    ignore(
      exec(
        "git -C " +
        shell_escape(wd) +
        " worktree add " +
        shell_escape(wt_dir) +
        " -b " +
        shell_escape(branch) +
        " 2>&1",
      ),
    )
    workers.push({ task, work_dir: wt_dir, branch, agent_id })
    if verbose {
      log("[orchestrator] Worktree: " + wt_dir + " -> " + branch)
    }
  }
  // Step 3: Select runner and spawn agents
  let runner : &AgentRunner = if config.in_process {
    let r = InProcessAgentRunner::new(
      config.provider_name,
      config.model,
      config.verbose,
    )
    let tr : &AgentRunner = r
    tr
  } else {
    let r = ProcessAgentRunner::new(
      config.provider_name,
      config.model,
      config.verbose,
    )
    let tr : &AgentRunner = r
    tr
  }
  let mode = if config.in_process { "in-process" } else { "process" }
  if verbose {
    log(
      "\n[orchestrator] Spawning " +
      workers.length().to_string() +
      " agents (" +
      mode +
      ")...",
    )
  }
  for w in workers {
    let log_file = session_dir + "/agents/" + w.agent_id + "/log.txt"
    let agent_config : LlmAgentConfig = {
      work_dir: w.work_dir,
      task: w.task,
      branch_name: w.branch,
      target_branch: config.target_branch,
      provider_name: config.provider_name,
      model: config.model,
      max_steps: 20,
      auto_commit: false,
      auto_pr: false,
      pr_title: "",
      verbose: config.verbose,
      coord_dir: session_dir,
      agent_id: w.agent_id,
      env: None,
      coord: None,
      provider: None,
    }
    let handle = runner.spawn_agent(agent_config, log_file)
    if not(config.in_process) {
      let pid = @strconv.parse_int(handle) catch { _ => 0 }
      coord_write_pid(session_dir, w.agent_id, pid)
    }
    if verbose {
      log("[orchestrator] Spawned " + w.agent_id + ": " + w.task)
    }
  }
  // Step 4: Wait for all agents
  if verbose {
    log("\n[orchestrator] Monitoring agents...")
  }
  runner.wait_all(session_dir, 1200, log)
  // Step 5: Commit changes in each completed worktree
  for w in workers {
    let status = coord_read_status(session_dir, w.agent_id)
    if status != Done && status != Running {
      if verbose {
        log(
          "[orchestrator] Skipping " +
          w.agent_id +
          " (status: " +
          status.to_string() +
          ")",
        )
      }
      continue
    }
    let changes = exec(
      "cd " +
      shell_escape(w.work_dir) +
      " && git status --porcelain 2>/dev/null",
    )
    if not(changes.is_empty()) {
      ignore(exec("cd " + shell_escape(w.work_dir) + " && git add -A"))
      ignore(
        exec(
          "cd " +
          shell_escape(w.work_dir) +
          " && git commit -m " +
          shell_escape("agent: " + w.task),
        ),
      )
      if verbose {
        log("[orchestrator] Committed on " + w.branch)
      }
    } else if verbose {
      log("[orchestrator] No changes on " + w.branch)
    }
  }
  // Step 6: Merge all branches
  let merge_branch = "agent/combined-" + ts
  ignore(
    exec(
      "cd " +
      shell_escape(wd) +
      " && git checkout -b " +
      shell_escape(merge_branch),
    ),
  )
  for w in workers {
    let status = coord_read_status(session_dir, w.agent_id)
    if status != Done && status != Running {
      continue
    }
    let result = exec(
      "cd " +
      shell_escape(wd) +
      " && git merge --no-edit " +
      shell_escape(w.branch) +
      " 2>&1",
    )
    if verbose {
      log("[orchestrator] Merge " + w.branch + ": " + result)
    }
  }
  // Step 7: Cleanup worktrees + coordination dir
  for w in workers {
    ignore(
      exec(
        "git -C " +
        shell_escape(wd) +
        " worktree remove --force " +
        shell_escape(w.work_dir) +
        " 2>/dev/null",
      ),
    )
    ignore(
      exec(
        "git -C " +
        shell_escape(wd) +
        " branch -d " +
        shell_escape(w.branch) +
        " 2>/dev/null",
      ),
    )
  }
  coord_cleanup(session_dir)
  if verbose {
    log("[orchestrator] Cleaned up worktrees and coordination dir")
  }
  // Step 8: PR
  if config.auto_pr {
    ignore(
      exec_with_timeout(
        "cd " +
        shell_escape(wd) +
        " && git push -u origin " +
        shell_escape(merge_branch),
        60000,
      ),
    )
    let result = exec_with_timeout(
      "cd " +
      shell_escape(wd) +
      " && gh pr create --title " +
      shell_escape("agent: " + config.task) +
      " --body 'Created by bit orchestrator' --base " +
      shell_escape(config.target_branch),
      60000,
    )
    log("[pr] " + result)
  }
  log("\n[orchestrator] Done. Branch: " + merge_branch)
}
