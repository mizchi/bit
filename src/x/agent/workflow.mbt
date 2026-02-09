///| Pure orchestration: execute a task by applying edits, creating a commit, and opening a PR.

///|
pub fn execute_task(
  task : AgentTask,
  config : AgentConfig,
  hub : @hub.Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  tree : &@lib.WorkingTree,
) -> TaskResult {
  // 1. Apply edits to working tree
  for edit in task.edits {
    match edit {
      Write(path, content) => tree.write_file(path, content)
      Delete(path) => tree.remove_file(path)
    }
  }
  // 2. Snapshot to create a commit
  let commit_id = tree.snapshot(task.description, config.agent_id, clock.now()) catch {
    err => return TaskResult::Error(err.to_string())
  }
  // 3. Create source branch ref
  refs.update("refs/heads/" + task.source_branch, Some(commit_id)) catch {
    err => return TaskResult::Error(err.to_string())
  }
  // 4. Create PR via hub
  let pr = hub.create_pr(
    objects,
    refs,
    clock,
    task.pr_title,
    task.pr_body,
    "refs/heads/" + task.source_branch,
    "refs/heads/" + config.target_branch,
    config.agent_id,
  ) catch {
    err => return TaskResult::Error(err.to_string())
  }
  TaskResult::PrCreated(pr.id())
}

///|
/// Check if a PR is approved and merge it.
pub fn check_and_merge(
  pr_id : String,
  config : AgentConfig,
  hub : @hub.Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
) -> TaskResult {
  // 1. Check approval
  if not(hub.is_approved(objects, pr_id)) {
    return TaskResult::PrRejected(pr_id, "not approved")
  }
  // 2. Merge
  let result = hub.merge_pr(objects, refs, clock, pr_id, config.agent_id) catch {
    err => return TaskResult::Error(err.to_string())
  }
  if result.success() {
    TaskResult::PrMerged(pr_id)
  } else {
    TaskResult::PrRejected(pr_id, result.message())
  }
}
