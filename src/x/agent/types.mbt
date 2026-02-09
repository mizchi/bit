///|
/// Agent configuration for P2P hub workflow
pub struct AgentConfig {
  agent_id : String
  remote_url : String
  target_branch : String
  validation_cmd : String
  auto_merge : Bool
  poll_interval_ms : Int
}

///|
pub fn AgentConfig::new(
  agent_id : String,
  remote_url : String,
  target_branch? : String = "main",
  validation_cmd? : String = "",
  auto_merge? : Bool = false,
  poll_interval_ms? : Int = 5000,
) -> AgentConfig {
  {
    agent_id,
    remote_url,
    target_branch,
    validation_cmd,
    auto_merge,
    poll_interval_ms,
  }
}

///|
/// A file edit operation
pub(all) enum FileEdit {
  Write(String, Bytes)
  Delete(String)
}

///|
/// A task for an agent to execute
pub struct AgentTask {
  id : String
  description : String
  edits : Array[FileEdit]
  pr_title : String
  pr_body : String
  source_branch : String
}

///|
pub fn AgentTask::new(
  id : String,
  description : String,
  edits : Array[FileEdit],
  pr_title : String,
  pr_body : String,
  source_branch : String,
) -> AgentTask {
  { id, description, edits, pr_title, pr_body, source_branch }
}

///|
/// Result of executing a task
pub(all) enum TaskResult {
  PrCreated(String)
  PrMerged(String)
  PrRejected(String, String)
  ValidationFailed(String)
  Error(String)
} derive(Show, Eq)

///|
/// Result of reviewing/validating a PR
pub(all) enum ReviewResult {
  Approved
  Rejected(String)
  ValidationError(String)
} derive(Show, Eq)
