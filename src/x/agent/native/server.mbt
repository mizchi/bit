///| Polling daemon for agent PR review and merge

///|
/// Run one cycle of the agent polling loop.
pub async fn poll_once(
  config : @agent.AgentConfig,
  git_dir : String,
) -> Unit raise @git.GitError {
  let osfs = @osfs.OsFs::new()
  let fs : &@git.FileSystem = osfs
  let rfs : &@git.RepoFileSystem = osfs
  // 1. Fetch hub notes from remote
  let hub = @hub.Hub::load(
    make_obj_store(rfs, fs, git_dir),
    make_ref_store(fs, rfs, git_dir),
  )
  ignore(@hub_native.hub_fetch(hub, fs, rfs, git_dir, config.remote_url))
  // Reload after fetch
  hub.reload_store(
    make_obj_store(rfs, fs, git_dir),
    make_ref_store(fs, rfs, git_dir),
  )
  let objects = make_obj_store(rfs, fs, git_dir)
  let refs = make_ref_store(fs, rfs, git_dir)
  let clock : NativeClock = { _dummy: 0 }
  // 2. List open PRs
  let prs = hub.list_prs(objects, state=Some(@hub.PrState::Open))
  for pr in prs {
    // 3. Check if we should review this PR
    if not(@agent.should_auto_review(pr, config)) {
      continue
    }
    // Check if already reviewed by us
    let reviews = hub.list_reviews(objects, pr.id())
    let already_reviewed = reviews
      .iter()
      .any(fn(r) { r.author() == config.agent_id })
    if already_reviewed {
      continue
    }
    // 4. Validate and submit review
    let result = validate_pr(pr, config, git_dir) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise @git.GitError::IoError(err.to_string())
        }
        @agent.ReviewResult::ValidationError(err.to_string())
      }
    }
    @agent.submit_validation_review(
      hub,
      objects,
      refs,
      clock,
      pr.id(),
      config.agent_id,
      result,
      pr.source_commit(),
    )
  }
  // 5. Auto-merge approved PRs if enabled
  if config.auto_merge {
    // Re-list to get fresh state
    let objects2 = make_obj_store(rfs, fs, git_dir)
    let refs2 = make_ref_store(fs, rfs, git_dir)
    let open_prs = hub.list_prs(objects2, state=Some(@hub.PrState::Open))
    for pr in open_prs {
      if pr.target_branch() != "refs/heads/" + config.target_branch {
        continue
      }
      if hub.is_approved(objects2, pr.id()) {
        let merge_result = @agent.check_and_merge(
          pr.id(),
          config,
          hub,
          objects2,
          refs2,
          clock,
        )
        match merge_result {
          @agent.TaskResult::PrMerged(_) => {
            // Push the updated target branch
            let target_ref = "refs/heads/" + config.target_branch
            let commit_id = refs2.resolve(target_ref)
            match commit_id {
              Some(id) => {
                let db = @lib.ObjectDb::load(rfs, git_dir)
                let reachable = @lib.collect_reachable_objects(db, rfs, id)
                let pack = @pack.create_packfile(reachable)
                let remote = @protocol.Remote::new(config.remote_url)
                let req = @protocol.PushRequest::new(
                  @git.ObjectId::zero(),
                  id,
                  target_ref,
                  pack,
                )
                ignore(@gitnative.push(remote, req))
              }
              None => ()
            }
          }
          _ => ()
        }
      }
    }
  }
  // 6. Push hub notes
  ignore(@hub_native.hub_push(hub, rfs, git_dir, config.remote_url))
}

///|
/// Start the polling daemon.
pub async fn serve(
  config : @agent.AgentConfig,
  git_dir : String,
) -> Unit raise @git.GitError {
  while true {
    poll_once(config, git_dir) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise @git.GitError::IoError(err.to_string())
        }
        ()
      }
    }
    // Sleep using process
    let interval_secs = config.poll_interval_ms / 1000
    let secs = if interval_secs < 1 { 1 } else { interval_secs }
    ignore(@process.run("sleep", [secs.to_string()], inherit_env=true)) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise @git.GitError::IoError(err.to_string())
        }
        ()
      }
    }
  }
}

///|
fn make_obj_store(
  rfs : &@git.RepoFileSystem,
  fs : &@git.FileSystem,
  git_dir : String,
) -> &@lib.ObjectStore {
  let store : NativeObjectStore = { rfs, fs, git_dir }
  store
}

///|
fn make_ref_store(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> &@lib.RefStore {
  let store : NativeRefStore = { fs, rfs, git_dir }
  store
}
