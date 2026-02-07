///| KV-based CoordinationBackend implementation

///|
/// Abstract KV store for agent coordination (decouples from @kv package)
pub(open) trait KvStore {
  get_string(Self, key : String) -> String
  set_string(Self, key : String, value : String) -> Unit
  delete(Self, key : String) -> Unit
  list(Self, prefix : String) -> Array[String]
  list_recursive(Self, prefix : String) -> Array[String]
  commit(Self, message : String) -> Unit
}

///|
priv struct KvCoordinationBackend {
  node_id : String
  kv_factory : () -> &KvStore
}

///|
pub fn kv_coordination_backend(
  node_id : String,
  kv_factory : () -> &KvStore,
) -> &CoordinationBackend {
  let backend : KvCoordinationBackend = { node_id, kv_factory }
  backend
}

///|
impl CoordinationBackend for KvCoordinationBackend with init_session(
  self,
  session_id,
) {
  let kv = (self.kv_factory)()
  kv.set_string("_meta/created", session_id)
  kv.set_string("_meta/node_id", self.node_id)
  kv.commit("init session")
  session_id
}

///|
impl CoordinationBackend for KvCoordinationBackend with init_agent(
  self,
  _dir,
  agent_id,
) {
  let kv = (self.kv_factory)()
  kv.set_string("agents/" + agent_id + "/status", "pending")
  kv.commit("init agent " + agent_id)
}

///|
impl CoordinationBackend for KvCoordinationBackend with write_status(
  self,
  _dir,
  agent_id,
  status,
) {
  let kv = (self.kv_factory)()
  kv.set_string("agents/" + agent_id + "/status", status.to_string())
  kv.commit("write status")
}

///|
impl CoordinationBackend for KvCoordinationBackend with write_step(
  self,
  _dir,
  agent_id,
  step,
) {
  let kv = (self.kv_factory)()
  kv.set_string("agents/" + agent_id + "/step", step.to_string())
  kv.set_string("agents/" + agent_id + "/step_time", "0")
  kv.commit("write step")
}

///|
impl CoordinationBackend for KvCoordinationBackend with write_pid(
  self,
  _dir,
  agent_id,
  pid,
) {
  let kv = (self.kv_factory)()
  kv.set_string("agents/" + agent_id + "/pid", pid.to_string())
  kv.commit("write pid")
}

///|
impl CoordinationBackend for KvCoordinationBackend with write_branch(
  self,
  _dir,
  agent_id,
  branch,
) {
  let kv = (self.kv_factory)()
  kv.set_string("agents/" + agent_id + "/branch", branch)
  kv.commit("write branch")
}

///|
impl CoordinationBackend for KvCoordinationBackend with read_status(
  self,
  _dir,
  agent_id,
) {
  let kv = (self.kv_factory)()
  let raw = kv.get_string("agents/" + agent_id + "/status")
  AgentStatus::parse(raw)
}

///|
impl CoordinationBackend for KvCoordinationBackend with append_event(
  self,
  _dir,
  agent_id,
  event,
) {
  let kv = (self.kv_factory)()
  let existing = kv.list_recursive("events")
  let seq = existing.length()
  let padded = pad_int(seq, 6)
  let filename = padded + "_" + agent_id
  let json = coord_event_to_json(event)
  kv.set_string("events/" + filename, json)
  kv.commit("append event")
}

///|
impl CoordinationBackend for KvCoordinationBackend with read_all_agents(
  self,
  _dir,
) {
  let kv = (self.kv_factory)()
  let agent_dirs = kv.list("agents")
  let result : Array[AgentSnapshot] = []
  for id in agent_dirs {
    let prefix = "agents/" + id + "/"
    let status_raw = kv.get_string(prefix + "status")
    let pid_raw = kv.get_string(prefix + "pid")
    let step_raw = kv.get_string(prefix + "step")
    let step_time_raw = kv.get_string(prefix + "step_time")
    let branch = kv.get_string(prefix + "branch")
    let pid = @strconv.parse_int(pid_raw) catch { _ => 0 }
    let step = @strconv.parse_int(step_raw) catch { _ => 0 }
    let step_time = (@strconv.parse_int(step_time_raw) catch { _ => 0 }).to_int64()
    result.push({
      agent_id: id,
      status: AgentStatus::parse(status_raw),
      pid,
      step,
      branch,
      last_step_time: step_time,
    })
  }
  result
}

///|
impl CoordinationBackend for KvCoordinationBackend with read_events_since(
  self,
  _dir,
  agent_id,
  since,
) {
  let kv = (self.kv_factory)()
  let all_events = kv.list_recursive("events")
  let result : Array[String] = []
  for key in all_events {
    // key format: "events/000001_agent-0"
    let fname = match key.rev_find("/") {
      Some(idx) =>
        String::unsafe_substring(key, start=idx + 1, end=key.length())
      None => key
    }
    if not(fname.contains("_" + agent_id)) {
      continue
    }
    let seq_str = take_chars(fname, 6)
    let seq = @strconv.parse_int(seq_str) catch { _ => 0 }
    if seq < since {
      continue
    }
    let content = kv.get_string(key)
    if not(content.is_empty()) {
      result.push(content)
    }
  }
  result
}

///|
impl CoordinationBackend for KvCoordinationBackend with cleanup(self, _dir) {
  let kv = (self.kv_factory)()
  let agent_keys = kv.list_recursive("agents")
  for key in agent_keys {
    kv.delete(key)
  }
  let event_keys = kv.list_recursive("events")
  for key in event_keys {
    kv.delete(key)
  }
  let meta_keys = kv.list_recursive("_meta")
  for key in meta_keys {
    kv.delete(key)
  }
  kv.commit("cleanup")
}
