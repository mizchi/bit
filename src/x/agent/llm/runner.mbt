///|
pub(all) struct LlmAgentConfig {
  work_dir : String
  task : String
  branch_name : String
  target_branch : String
  provider_name : String
  model : String
  max_steps : Int
  auto_commit : Bool
  auto_pr : Bool
  pr_title : String
  verbose : Bool
  coord_dir : String // empty = no coordination
  agent_id : String // empty = no coordination
  env : &ToolEnvironment? // None = use NativeToolEnvironment
  coord : &CoordinationBackend? // None = use FileCoordinationBackend
  provider : @llmlib.BoxedProvider? // None = create_provider(provider_name, model, ...)
}

///|
fn detect_project_hints(work_dir : String) -> String {
  let has_moon = strip_trailing_whitespace(
    exec(
      "test -f " +
      shell_escape(work_dir + "/moon.mod.json") +
      " && echo yes || echo no",
    ),
  )
  if has_moon == "yes" {
    return "## Project: MoonBit\n- Type check: `moon check --deny-warn`\n- Test: `moon test`\n- Format: `moon fmt`\n- Always run `moon check --deny-warn` after writing code to catch errors early.\n"
  }
  ""
}

///|
fn build_system_prompt(work_dir : String, task : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("You are a coding agent working in: ")
  buf.write_string(work_dir)
  buf.write_string("\n\nTask: ")
  buf.write_string(task)
  let workflow =
    #|
    #|
    #|## Workflow (follow these phases in order)
    #|
    #|Phase 1 - Explore: Understand the codebase structure.
    #|  - Call `list_files_recursive` ONCE to get an overview.
    #|  - Use `search_text` to find relevant code by pattern.
    #|  - Use `read_file` to read specific files you need to understand.
    #|
    #|Phase 2 - Plan: Decide what changes to make.
    #|  - Identify which files to create or modify.
    #|  - Read each file you plan to modify BEFORE writing.
    #|
    #|Phase 3 - Implement: Make changes using `write_file`.
    #|  - You MUST call `write_file` to make progress. Exploring alone is not progress.
    #|  - Write complete file contents. Do NOT leave placeholders.
    #|
    #|Phase 4 - Verify: Run checks and tests.
    #|  - Use `run_command` to run the project's type checker and tests.
    #|  - If errors occur, read the error output, fix with `write_file`, and re-verify.
    #|
    #|Phase 5 - Complete: Stop calling tools and summarize what you did.
    #|
    #|## Anti-patterns (Do NOT do these)
    #|
    #|- Do NOT call `list_directory` on the same path more than once.
    #|- Do NOT call `list_files_recursive` on the same path more than once.
    #|- Do NOT keep exploring without writing code. If you have read enough, start writing.
    #|- Do NOT call `read_file` on the same file repeatedly. Read once, then modify.
    #|- Do NOT run the same failing command without changing code first.
    #|
    #|## Tool selection guide
    #|
    #|- To find code by content: use `search_text` (regex, fast).
    #|- To understand project structure: use `list_files_recursive` once.
    #|- To read a specific file: use `read_file`.
    #|- To make changes: use `write_file` (REQUIRED for progress).
    #|- To verify: use `run_command`.
  buf.write_string(workflow)
  let hints = detect_project_hints(work_dir)
  if not(hints.is_empty()) {
    buf.write_string("\n")
    buf.write_string(hints)
  }
  buf.to_string()
}

///|
pub fn create_provider(
  name : String,
  model : String,
  system_prompt : String,
) -> @llmlib.BoxedProvider {
  match name {
    "anthropic" => {
      let api_key = @ffi.get_env("ANTHROPIC_API_KEY")
      let m = if model.is_empty() {
        @llmlib.default_anthropic_model
      } else {
        model
      }
      let provider = @anthropic.AnthropicProvider::new(
        api_key,
        model=m,
        system_prompt~,
        max_tokens=8192,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    "openai" => {
      let api_key = @ffi.get_env("OPENAI_API_KEY")
      let m = if model.is_empty() {
        @llmlib.default_openai_model
      } else {
        model
      }
      let provider = @openai.OpenAIProvider::new(
        api_key,
        model=m,
        system_prompt~,
        max_tokens=8192,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    "openrouter" => {
      let api_key = @ffi.get_env("OPENROUTER_API_KEY")
      let m = if model.is_empty() {
        @llmlib.default_openrouter_model
      } else {
        model
      }
      let provider = @openai.OpenAIProvider::new(
        api_key,
        endpoint=OpenRouter,
        model=m,
        system_prompt~,
        max_tokens=8192,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    "claude_code" => {
      let m = if model.is_empty() { "" } else { model }
      let provider = @claude_code.ClaudeCodeProvider::new(
        model=m,
        system_prompt~,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    _ => create_provider("anthropic", model, system_prompt)
  }
}

///|
pub fn run_llm_agent(
  config : LlmAgentConfig,
  on_output~ : (String) -> Unit,
  should_cancel? : () -> Bool = fn() { false },
) -> Unit {
  let log = fn(s : String) { on_output(s + "\n") }
  let system_prompt = build_system_prompt(config.work_dir, config.task)
  let provider = match config.provider {
    Some(p) => p
    None => create_provider(config.provider_name, config.model, system_prompt)
  }
  let env : &ToolEnvironment = match config.env {
    Some(e) => e
    None => native_tool_env(config.work_dir)
  }
  let registry = create_tool_registry(env)
  let messages : Array[@llmlib.Message] = [@llmlib.Message::user(config.task)]
  let verbose = config.verbose
  let has_coord = not(config.coord_dir.is_empty()) &&
    not(config.agent_id.is_empty())
  let coord : &CoordinationBackend? = if has_coord {
    match config.coord {
      Some(c) => Some(c)
      None => Some(file_coordination_backend(""))
    }
  } else {
    None
  }
  if has_coord {
    guard coord is Some(c) else { () }
    c.write_status(config.coord_dir, config.agent_id, Running)
  }
  if verbose {
    log("[agent] provider=" + config.provider_name + " model=" + config.model)
    log("[agent] work_dir=" + config.work_dir)
    log("[agent] task=" + config.task)
    log("")
  }
  let text_buf = StringBuilder::new()
  let mut tools_in_step = 0
  @llmlib.run_agent_cancellable(
    provider,
    registry,
    messages,
    @llmlib.StopCondition::MaxSteps(config.max_steps),
    should_cancel,
    fn(event) {
      match event {
        Stream(stream_event) =>
          match stream_event {
            TextDelta(s) => text_buf.write_string(s)
            _ => ()
          }
        ToolExecute(name~, input~) =>
          if verbose {
            let text = text_buf.to_string()
            if not(text.is_empty()) {
              on_output(text)
              text_buf.reset()
            }
            log("\n[tool] " + name + " " + input.stringify())
          }
        ToolResult(name~, result~, is_error~) => {
          tools_in_step += 1
          if has_coord {
            guard coord is Some(c) else { () }
            if name == "write_file" {
              c.append_event(
                config.coord_dir,
                config.agent_id,
                FileChanged(path=result),
              )
            }
            if is_error {
              c.append_event(
                config.coord_dir,
                config.agent_id,
                Error(message=name + ": " + result),
              )
            }
          }
          if verbose {
            let status = if is_error { " ERROR" } else { " ok" }
            let preview = if result.length() > 200 {
              let buf = StringBuilder::new()
              let rchars : Array[Char] = []
              for ch in result {
                rchars.push(ch)
              }
              for j = 0; j < 200; j = j + 1 {
                buf.write_char(rchars[j])
              }
              buf.write_string("...")
              buf.to_string()
            } else {
              result
            }
            log("[result] " + name + status + ": " + preview)
          }
        }
        StepComplete(step~) => {
          if has_coord {
            guard coord is Some(c) else { () }
            c.write_step(config.coord_dir, config.agent_id, step)
            c.append_event(
              config.coord_dir,
              config.agent_id,
              StepCompleted(step~, tools_called=tools_in_step),
            )
          }
          tools_in_step = 0
          let text = text_buf.to_string()
          if not(text.is_empty()) {
            on_output(text)
            text_buf.reset()
          }
          if verbose {
            log("[step " + step.to_string() + " complete]")
          }
        }
        Done(reason~) => {
          if has_coord {
            guard coord is Some(c) else { () }
            c.write_status(config.coord_dir, config.agent_id, Done)
            c.append_event(
              config.coord_dir,
              config.agent_id,
              Finished(summary=reason),
            )
          }
          let text = text_buf.to_string()
          if not(text.is_empty()) {
            on_output(text)
          }
          log("\n[done] " + reason)
        }
      }
    },
  )
  // Auto-commit
  if config.auto_commit {
    let branch = config.branch_name
    let wd = config.work_dir
    if verbose {
      log("[git] creating branch: " + branch)
    }
    ignore(
      exec(
        "cd " + shell_escape(wd) + " && git checkout -b " + shell_escape(branch),
      ),
    )
    ignore(exec("cd " + shell_escape(wd) + " && git add -A"))
    let msg = "agent: " + config.task
    ignore(
      exec("cd " + shell_escape(wd) + " && git commit -m " + shell_escape(msg)),
    )
    if verbose {
      log("[git] committed on branch: " + branch)
    }
  }
  // Auto-PR
  if config.auto_pr {
    let wd = config.work_dir
    let branch = config.branch_name
    let title = if config.pr_title.is_empty() {
      "agent: " + config.task
    } else {
      config.pr_title
    }
    ignore(
      exec_with_timeout(
        "cd " +
        shell_escape(wd) +
        " && git push -u origin " +
        shell_escape(branch),
        60000,
      ),
    )
    let result = exec_with_timeout(
      "cd " +
      shell_escape(wd) +
      " && gh pr create --title " +
      shell_escape(title) +
      " --body 'Created by bit agent' --base " +
      shell_escape(config.target_branch),
      60000,
    )
    log("[pr] " + result)
  }
}
