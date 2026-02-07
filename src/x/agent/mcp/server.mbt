///|
fn json_get_str(j : Json, field : String) -> String {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
fn json_get_int(j : Json, field : String, default_ : Int) -> Int {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(Number(n, ..)) => n.to_int()
        _ => default_
      }
    _ => default_
  }
}

///|
fn json_get_bool(j : Json, field : String, default_ : Bool) -> Bool {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(True) => true
        Some(False) => false
        _ => default_
      }
    _ => default_
  }
}

///|
fn jsonrpc_response(id : Json, result : Json) -> String {
  let resp : Map[String, Json] = {}
  resp["jsonrpc"] = "2.0".to_json()
  resp["id"] = id
  resp["result"] = result
  Json::object(resp).stringify()
}

///|
fn jsonrpc_error(id : Json, code : Int, message : String) -> String {
  let err : Map[String, Json] = {}
  err["code"] = Json::number(code.to_double())
  err["message"] = message.to_json()
  let resp : Map[String, Json] = {}
  resp["jsonrpc"] = "2.0".to_json()
  resp["id"] = id
  resp["error"] = Json::object(err)
  Json::object(resp).stringify()
}

///|
fn tool_result_text(text : String) -> Json {
  let content : Map[String, Json] = {}
  content["type"] = "text".to_json()
  content["text"] = text.to_json()
  let result : Map[String, Json] = {}
  result["content"] = Json::array([Json::object(content)])
  Json::object(result)
}

///|
fn tool_result_error(text : String) -> Json {
  let content : Map[String, Json] = {}
  content["type"] = "text".to_json()
  content["text"] = text.to_json()
  let result : Map[String, Json] = {}
  result["content"] = Json::array([Json::object(content)])
  result["isError"] = Json::boolean(true)
  Json::object(result)
}

///|
fn handle_initialize(id : Json) -> String {
  let caps : Map[String, Json] = {}
  caps["tools"] = Json::object({})
  let info : Map[String, Json] = {}
  info["name"] = "bit-agent".to_json()
  info["version"] = "0.1.0".to_json()
  let result : Map[String, Json] = {}
  result["protocolVersion"] = "2024-11-05".to_json()
  result["capabilities"] = Json::object(caps)
  result["serverInfo"] = Json::object(info)
  jsonrpc_response(id, Json::object(result))
}

///|
fn build_tool_defs() -> Json {
  let run_agent_schema : Map[String, Json] = {}
  run_agent_schema["type"] = "object".to_json()
  let ra_props : Map[String, Json] = {}
  ra_props["task"] = Json::object({
    "type": "string".to_json(),
    "description": "Task description for the agent".to_json(),
  })
  ra_props["work_dir"] = Json::object({
    "type": "string".to_json(),
    "description": "Working directory (default: cwd)".to_json(),
  })
  ra_props["provider"] = Json::object({
    "type": "string".to_json(),
    "description": "LLM provider: openrouter|anthropic|openai|claude_code".to_json(),
  })
  ra_props["model"] = Json::object({
    "type": "string".to_json(),
    "description": "Model name".to_json(),
  })
  ra_props["max_steps"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max agent steps (default: 20)".to_json(),
  })
  ra_props["no_commit"] = Json::object({
    "type": "boolean".to_json(),
    "description": "Skip auto-commit (default: false)".to_json(),
  })
  run_agent_schema["properties"] = Json::object(ra_props)
  run_agent_schema["required"] = Json::array(["task".to_json()])
  let run_agent_tool : Map[String, Json] = {}
  run_agent_tool["name"] = "run_agent".to_json()
  run_agent_tool["description"] = "Run a coding agent that reads/writes files to complete a task".to_json()
  run_agent_tool["inputSchema"] = Json::object(run_agent_schema)
  // orchestrate tool
  let orch_schema : Map[String, Json] = {}
  orch_schema["type"] = "object".to_json()
  let o_props : Map[String, Json] = {}
  o_props["task"] = Json::object({
    "type": "string".to_json(),
    "description": "High-level task to split into parallel subtasks".to_json(),
  })
  o_props["work_dir"] = Json::object({
    "type": "string".to_json(),
    "description": "Working directory (default: cwd)".to_json(),
  })
  o_props["provider"] = Json::object({
    "type": "string".to_json(),
    "description": "LLM provider".to_json(),
  })
  o_props["model"] = Json::object({
    "type": "string".to_json(),
    "description": "Model name".to_json(),
  })
  o_props["max_workers"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max parallel workers (default: 3)".to_json(),
  })
  orch_schema["properties"] = Json::object(o_props)
  orch_schema["required"] = Json::array(["task".to_json()])
  let orch_tool : Map[String, Json] = {}
  orch_tool["name"] = "run_orchestrator".to_json()
  orch_tool["description"] = "Run parallel coding agents on subtasks with automatic planning and merging".to_json()
  orch_tool["inputSchema"] = Json::object(orch_schema)
  let result : Map[String, Json] = {}
  result["tools"] = Json::array([
    Json::object(run_agent_tool),
    Json::object(orch_tool),
  ])
  Json::object(result)
}

///|
fn handle_tools_list(id : Json) -> String {
  jsonrpc_response(id, build_tool_defs())
}

///|
fn get_work_dir(args : Json) -> String {
  let wd = json_get_str(args, "work_dir")
  if wd.is_empty() {
    @agent_llm.strip_trailing_whitespace(@llm_ffi.exec_sync("pwd", 5000))
  } else {
    wd
  }
}

///|
fn handle_tools_call(id : Json, params : Json) -> String {
  let name = json_get_str(params, "name")
  let arguments = match params {
    Object(m) =>
      match m.get("arguments") {
        Some(obj) => obj
        _ => Json::object({})
      }
    _ => Json::object({})
  }
  match name {
    "run_agent" => handle_run_agent(id, arguments)
    "run_orchestrator" => handle_run_orchestrator(id, arguments)
    _ => jsonrpc_error(id, -32601, "Unknown tool: " + name)
  }
}

///|
fn handle_run_agent(id : Json, args : Json) -> String {
  let task = json_get_str(args, "task")
  if task.is_empty() {
    return jsonrpc_response(id, tool_result_error("task is required"))
  }
  let work_dir = get_work_dir(args)
  let provider = json_get_str(args, "provider")
  let model = json_get_str(args, "model")
  let max_steps = json_get_int(args, "max_steps", 20)
  let no_commit = json_get_bool(args, "no_commit", false)
  let ts = @agent_llm.strip_trailing_whitespace(
    @llm_ffi.exec_sync("date +%s", 5000),
  )
  let config : @agent_llm.LlmAgentConfig = {
    work_dir,
    task,
    branch_name: "agent/" + ts,
    target_branch: "main",
    provider_name: if provider.is_empty() {
      "openrouter"
    } else {
      provider
    },
    model,
    max_steps,
    auto_commit: not(no_commit),
    auto_pr: false,
    pr_title: "",
    verbose: true,
    coord_dir: "",
    agent_id: "",
    env: None,
    coord: None,
    provider: None,
  }
  let buf = StringBuilder::new()
  log("[mcp] Running agent: task=" + task)
  @agent_llm.run_llm_agent(config, on_output=fn(s) {
    buf.write_string(s)
    log("[agent] " + s)
  })
  jsonrpc_response(id, tool_result_text(buf.to_string()))
}

///|
fn handle_run_orchestrator(id : Json, args : Json) -> String {
  let task = json_get_str(args, "task")
  if task.is_empty() {
    return jsonrpc_response(id, tool_result_error("task is required"))
  }
  let work_dir = get_work_dir(args)
  let provider = json_get_str(args, "provider")
  let model = json_get_str(args, "model")
  let max_workers = json_get_int(args, "max_workers", 3)
  let config : @agent_llm.OrchestratorConfig = {
    work_dir,
    task,
    provider_name: if provider.is_empty() {
      "openrouter"
    } else {
      provider
    },
    model,
    max_workers,
    target_branch: "main",
    auto_pr: false,
    verbose: true,
    in_process: false,
  }
  let buf = StringBuilder::new()
  log("[mcp] Orchestrating: task=" + task)
  @agent_llm.run_orchestrator(config, on_output=fn(s) {
    buf.write_string(s)
    log("[orch] " + s)
  })
  jsonrpc_response(id, tool_result_text(buf.to_string()))
}

///|
pub fn run_mcp_server() -> Unit {
  log("[mcp] bit-agent MCP server started")
  while true {
    let msg = read_message()
    if msg.is_empty() {
      break
    }
    let json = @json.parse(msg) catch {
      _ => {
        log("[mcp] Failed to parse JSON: " + msg)
        continue
      }
    }
    let meth = json_get_str(json, "method")
    let id = match json {
      Object(m) =>
        match m.get("id") {
          Some(v) => v
          _ => Json::null()
        }
      _ => Json::null()
    }
    let params = match json {
      Object(m) =>
        match m.get("params") {
          Some(v) => v
          _ => Json::object({})
        }
      _ => Json::object({})
    }
    log("[mcp] method=" + meth)
    if meth == "notifications/initialized" || meth == "initialized" {
      continue
    }
    let response = match meth {
      "initialize" => handle_initialize(id)
      "tools/list" => handle_tools_list(id)
      "tools/call" => handle_tools_call(id, params)
      _ => jsonrpc_error(id, -32601, "Method not found: " + meth)
    }
    write_message(response)
  }
  log("[mcp] Server stopped")
}
