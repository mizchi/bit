///| CLI handlers for bit agent subcommand

///|
fn agent_bytes_to_string(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i in 0..<bytes.length() {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn print_agent_usage() -> Unit {
  println("Usage: bit agent <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  llm     Run LLM-driven coding agent")
  println("  serve   Start polling daemon for PR review/merge")
  println("  run     Execute a task from JSON file")
  println("  status  Show open PRs and agent status")
  println("  help    Show this help")
  println("")
  println("Options:")
  println("  --remote <url>       Remote repository URL")
  println("  --branch <branch>    Target branch (default: main)")
  println("  --validate <cmd>     Validation command to run")
  println("  --auto-merge         Auto-merge approved PRs")
  println(
    "  --interval <ms>      Poll interval in milliseconds (default: 5000)",
  )
  println("  --agent-id <id>      Agent identifier (default: author string)")
}

///|
async fn handle_agent(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_agent_usage()
    return
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "llm" => handle_agent_llm(rest)
    "serve" => handle_agent_serve(rest)
    "run" => handle_agent_run(rest)
    "status" => handle_agent_status(rest)
    "help" | "-h" | "--help" => print_agent_usage()
    _ => {
      println("Unknown agent subcommand: \{subcmd}")
      print_agent_usage()
    }
  }
}

///|
fn parse_agent_config(args : Array[String]) -> @agent.AgentConfig {
  let mut remote_url = ""
  let mut target_branch = "main"
  let mut validation_cmd = ""
  let mut auto_merge = false
  let mut poll_interval_ms = 5000
  let mut agent_id = get_author_string()
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--remote" => {
        i = i + 1
        if i < args.length() {
          remote_url = args[i]
        }
      }
      "--branch" => {
        i = i + 1
        if i < args.length() {
          target_branch = args[i]
        }
      }
      "--validate" => {
        i = i + 1
        if i < args.length() {
          validation_cmd = args[i]
        }
      }
      "--auto-merge" => auto_merge = true
      "--interval" => {
        i = i + 1
        if i < args.length() {
          poll_interval_ms = @strconv.parse_int(args[i]) catch { _ => 5000 }
        }
      }
      "--agent-id" => {
        i = i + 1
        if i < args.length() {
          agent_id = args[i]
        }
      }
      _ => ()
    }
    i = i + 1
  }
  @agent.AgentConfig::new(
    agent_id,
    remote_url,
    target_branch~,
    validation_cmd~,
    auto_merge~,
    poll_interval_ms~,
  )
}

///|
async fn handle_agent_serve(args : Array[String]) -> Unit raise Error {
  let config = parse_agent_config(args)
  if config.remote_url == "" {
    println("Error: --remote <url> is required")
    return
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  println(
    "Starting agent daemon (id=\{config.agent_id}, remote=\{config.remote_url}, branch=\{config.target_branch})",
  )
  @agent_native.serve(config, git_dir)
}

///|
async fn handle_agent_run(args : Array[String]) -> Unit raise Error {
  let config = parse_agent_config(args)
  if config.remote_url == "" {
    println("Error: --remote <url> is required")
    return
  }
  // Find --task argument
  let mut task_file = ""
  let mut i = 0
  while i < args.length() {
    if args[i] == "--task" && i + 1 < args.length() {
      task_file = args[i + 1]
      i = i + 2
    } else {
      i = i + 1
    }
  }
  if task_file == "" {
    println("Error: --task <json-file> is required")
    return
  }
  // Read task file
  let osfs = OsFs::new()
  let task_bytes = (osfs : &@git.RepoFileSystem).read_file(task_file)
  let task_json = @json.parse(agent_bytes_to_string(task_bytes)) catch {
    err => {
      println("Error: invalid JSON in task file: \{err}")
      return
    }
  }
  let task = parse_agent_task(task_json) catch {
    err => {
      println("Error: invalid task format: \{err}")
      return
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let result = @agent_native.run_task(task, config, git_dir)
  match result {
    @agent.TaskResult::PrCreated(pr_id) => println("PR created: \{pr_id}")
    @agent.TaskResult::PrMerged(pr_id) => println("PR merged: \{pr_id}")
    @agent.TaskResult::PrRejected(pr_id, reason) =>
      println("PR rejected: \{pr_id} (\{reason})")
    @agent.TaskResult::ValidationFailed(output) =>
      println("Validation failed: \{output}")
    @agent.TaskResult::Error(msg) => println("Error: \{msg}")
  }
}

///|
fn parse_agent_task(json : Json) -> @agent.AgentTask raise @git.GitError {
  guard json is Object(obj) else {
    raise @git.GitError::InvalidObject("expected JSON object")
  }
  let id = match obj.get("id") {
    Some(String(s)) => s
    _ => raise @git.GitError::InvalidObject("missing 'id' field")
  }
  let description = match obj.get("description") {
    Some(String(s)) => s
    _ => ""
  }
  let pr_title = match obj.get("pr_title") {
    Some(String(s)) => s
    _ => id
  }
  let pr_body = match obj.get("pr_body") {
    Some(String(s)) => s
    _ => ""
  }
  let source_branch = match obj.get("source_branch") {
    Some(String(s)) => s
    _ => "agent/" + id
  }
  let edits : Array[@agent.FileEdit] = []
  match obj.get("edits") {
    Some(Array(arr)) =>
      for item in arr {
        guard item is Object(edit_obj) else { continue }
        match edit_obj.get("type") {
          Some(String("write")) => {
            let path = match edit_obj.get("path") {
              Some(String(s)) => s
              _ => continue
            }
            let content = match edit_obj.get("content") {
              Some(String(s)) =>
                Bytes::from_array(
                  s.to_array().map(fn(c) { c.to_int().to_byte() }),
                )
              _ => continue
            }
            edits.push(@agent.FileEdit::Write(path, content))
          }
          Some(String("delete")) => {
            let path = match edit_obj.get("path") {
              Some(String(s)) => s
              _ => continue
            }
            edits.push(@agent.FileEdit::Delete(path))
          }
          _ => continue
        }
      }
    _ => ()
  }
  @agent.AgentTask::new(
    id, description, edits, pr_title, pr_body, source_branch,
  )
}

///|
async fn handle_agent_status(args : Array[String]) -> Unit raise Error {
  let config = parse_agent_config(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  // Fetch if remote specified
  if config.remote_url != "" {
    let osfs = OsFs::new()
    let fs : &@git.FileSystem = osfs
    let rfs : &@git.RepoFileSystem = osfs
    let collab = @collab.Collab::load(objects, refs) catch {
      _ => @collab.Collab::init(objects, refs)
    }
    ignore(
      @collab_native.collab_fetch(collab, fs, rfs, git_dir, config.remote_url),
    ) catch {
      _ => ()
    }
  }
  let collab = @collab.Collab::load(objects, refs) catch {
    _ => {
      println("No collab metadata found. Run 'bit collab init' first.")
      return
    }
  }
  let prs = collab.list_prs(objects)
  if prs.length() == 0 {
    println("No pull requests found.")
    return
  }
  for pr in prs {
    let approved = if collab.is_approved(objects, pr.id()) {
      " [approved]"
    } else {
      ""
    }
    let state = match pr.state() {
      Open => "open"
      Merged => "merged"
      Closed => "closed"
    }
    println(
      "\{pr.id()} [\{state}]\{approved} \{pr.title()} (by \{pr.author()})",
    )
  }
}

///|
fn print_agent_llm_usage() -> Unit {
  println("Usage: bit agent llm --task <text> [options]")
  println("")
  println("Options:")
  println("  --task <text>          Task description (required)")
  println("  --orchestrate          Run as orchestrator (parallel subtasks)")
  println("  --work-dir <path>      Working directory (default: cwd)")
  println("  --provider <name>      openrouter|anthropic|openai|claude_code")
  println("  --model <name>         Model name (default: provider default)")
  println("  --max-steps <n>        Max agent steps (default: 20)")
  println("  --max-workers <n>      Max parallel workers (default: 3)")
  println("  --branch <name>        Git branch (default: agent/<timestamp>)")
  println("  --target-branch <name> PR target branch (default: main)")
  println("  --no-commit            Skip auto-commit")
  println("  --pr                   Create PR after commit")
  println("  --pr-title <text>      PR title")
  println("  --coord-dir <path>     Coordination directory (for orchestrator)")
  println("  --agent-id <id>        Agent ID (for orchestrator)")
  println("  --quiet                Suppress verbose output")
}

///|
fn parse_llm_int(s : String, default_ : Int) -> Int {
  @strconv.parse_int(s) catch {
    _ => default_
  }
}

///|
fn handle_agent_llm(args : Array[String]) -> Unit {
  let mut task = ""
  let mut work_dir = ""
  let mut provider = "openrouter"
  let mut model = ""
  let mut max_steps = 20
  let mut max_workers = 3
  let mut branch = ""
  let mut target_branch = "main"
  let mut auto_commit = true
  let mut auto_pr = false
  let mut pr_title = ""
  let mut verbose = true
  let mut orchestrate = false
  let mut coord_dir = ""
  let mut agent_id_flag = ""
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--orchestrate" => orchestrate = true
      "--task" => {
        i += 1
        if i < args.length() {
          task = args[i]
        }
      }
      "--work-dir" => {
        i += 1
        if i < args.length() {
          work_dir = args[i]
        }
      }
      "--provider" => {
        i += 1
        if i < args.length() {
          provider = args[i]
        }
      }
      "--model" => {
        i += 1
        if i < args.length() {
          model = args[i]
        }
      }
      "--max-steps" => {
        i += 1
        if i < args.length() {
          max_steps = parse_llm_int(args[i], 20)
        }
      }
      "--max-workers" => {
        i += 1
        if i < args.length() {
          max_workers = parse_llm_int(args[i], 3)
        }
      }
      "--branch" => {
        i += 1
        if i < args.length() {
          branch = args[i]
        }
      }
      "--target-branch" => {
        i += 1
        if i < args.length() {
          target_branch = args[i]
        }
      }
      "--no-commit" => auto_commit = false
      "--pr" => auto_pr = true
      "--pr-title" => {
        i += 1
        if i < args.length() {
          pr_title = args[i]
        }
      }
      "--coord-dir" => {
        i += 1
        if i < args.length() {
          coord_dir = args[i]
        }
      }
      "--agent-id" => {
        i += 1
        if i < args.length() {
          agent_id_flag = args[i]
        }
      }
      "--quiet" => verbose = false
      "-h" | "--help" => {
        print_agent_llm_usage()
        return
      }
      _ => ()
    }
    i += 1
  }
  if task.is_empty() {
    print_agent_llm_usage()
    return
  }
  if work_dir.is_empty() {
    work_dir = get_work_root()
  }
  let output = fn(s : String) { println(s) }
  if orchestrate {
    let config : @agent_llm.OrchestratorConfig = {
      work_dir,
      task,
      provider_name: provider,
      model,
      max_workers,
      target_branch,
      auto_pr,
      verbose,
      in_process: false,
    }
    @agent_llm.run_orchestrator(config, on_output=output)
  } else {
    let branch_name = if branch.is_empty() {
      "agent/" +
      @agent_llm.strip_trailing_whitespace(@llm_ffi.exec_sync("date +%s", 5000))
    } else {
      branch
    }
    let config : @agent_llm.LlmAgentConfig = {
      work_dir,
      task,
      branch_name,
      target_branch,
      provider_name: provider,
      model,
      max_steps,
      auto_commit,
      auto_pr,
      pr_title,
      verbose,
      coord_dir,
      agent_id: agent_id_flag,
      env: None,
      coord: None,
      provider: None,
    }
    @agent_llm.run_llm_agent(config, on_output=output)
  }
}
