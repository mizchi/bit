///|
async fn handle_checkout(args : Array[String]) -> Unit raise Error {
  if is_real_git_delegate_enabled() {
    delegate_to_real_git("checkout", args)
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  // Parse arguments
  let mut saw_separator = false
  let mut create_branch = false
  let mut force_create = false
  let targets : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--" => saw_separator = true
      "-b" => create_branch = true
      "-B" => {
        create_branch = true
        force_create = true
      }
      "-" => targets.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("checkout", arg)
      _ => targets.push(arg)
    }
    i += 1
  }
  if targets.length() == 0 {
    raise @git.GitError::InvalidObject("No target specified for checkout")
  }
  // git checkout -b <branch> [start-point]
  if create_branch {
    let previous_location = current_checkout_location(rfs, git_dir)
    let branch_name = targets[0]
    let start_point = if targets.length() > 1 { Some(targets[1]) } else { None }
    // Check if branch already exists
    let branch_exists = @gitlib.resolve_ref(
        fs,
        git_dir,
        "refs/heads/" + branch_name,
      )
      is Some(_)
    if branch_exists && not(force_create) {
      raise @git.GitError::InvalidObject(
        "branch '\{branch_name}' already exists",
      )
    }
    // For start point, first checkout to that commit, then create branch
    match start_point {
      Some(ref_name) => {
        let commit_id = @gitrepo.rev_parse(fs, git_dir, ref_name)
        guard commit_id is Some(_) else {
          raise @git.GitError::InvalidObject("unknown revision: \{ref_name}")
        }
        // Checkout the start point first (detached)
        let _ = checkout_with_promisor_retry(fs, root, ref_name, detach=true)
        // Then create and switch to new branch
        @gitlib.switch_branch(fs, fs, root, branch_name, create=true)
      }
      None =>
        // Use switch_branch which handles both atomically
        @gitlib.switch_branch(fs, fs, root, branch_name, create=true)
    }
    save_previous_checkout_location(fs, git_dir, previous_location)
    return ()
  }
  // If -- was used, treat all targets as file paths
  if saw_separator {
    @gitlib.restore_paths(fs, fs, root, targets)
    return ()
  }
  // Single target: determine if it's a branch or file
  if targets.length() == 1 {
    let target = resolve_checkout_target(rfs, git_dir, targets[0])
    let previous_location = current_checkout_location(rfs, git_dir)
    let is_file = fs.is_file(root + "/" + target)
    let is_branch = @gitlib.resolve_ref(fs, git_dir, "refs/heads/" + target)
      is Some(_)
    let mut switched_head = false
    if is_file && is_branch {
      // Ambiguous - default to branch (like git)
      let _ = checkout_with_promisor_retry(fs, root, target)
      switched_head = true
    } else if is_file {
      // Restore single file
      @gitlib.restore_paths(fs, fs, root, [target])
    } else {
      // Try as branch/commit
      let _ = checkout_with_promisor_retry(fs, root, target)
      switched_head = true
    }
    if switched_head {
      save_previous_checkout_location(fs, git_dir, previous_location)
    }
  } else {
    // Multiple targets: treat as file paths
    @gitlib.restore_paths(fs, fs, root, targets)
  }
}

///|
async fn checkout_with_promisor_retry(
  fs : OsFs,
  root : String,
  spec : String,
  detach? : Bool = false,
) -> @git.ObjectId raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let mut checkout_spec = spec
  let mut checkout_detach = detach
  let mut resolved_target : @git.ObjectId? = None
  if spec.contains("^") || spec.contains("~") {
    match @gitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => {
        resolved_target = Some(id)
        checkout_spec = id.to_hex()
        checkout_detach = true
      }
      None => ()
    }
  }
  let mut promisor_db : @gitlib.PromisorDb? = None
  let mut wrote_trace_round = false
  match resolved_target {
    Some(target_id) => {
      let pdb = @gitlibnative.native_promisor_db(fs, git_dir)
      if pdb.has_promisor() {
        let missing_ids = collect_missing_checkout_blob_ids(
          fs, git_dir, target_id,
        )
        if missing_ids.length() > 0 {
          ignore(pdb.fetch_missing(fs, missing_ids))
          if not(wrote_trace_round) {
            append_checkout_fetch_trace(fs)
            wrote_trace_round = true
          }
        }
        promisor_db = Some(pdb)
      }
    }
    None => ()
  }
  let mut attempts = 0
  while attempts < 16 {
    let result : Result[@git.ObjectId, Error] = try? @gitlib.checkout(
      fs,
      fs,
      root,
      checkout_spec,
      detach=checkout_detach,
    )
    match result {
      Ok(id) => return id
      Err(err) =>
        match parse_checkout_missing_object_id(err) {
          Some(missing_id) => {
            let pdb = match promisor_db {
              Some(db) => db
              None => {
                let db = @gitlibnative.native_promisor_db(fs, git_dir)
                if not(db.has_promisor()) {
                  raise err
                }
                promisor_db = Some(db)
                db
              }
            }
            let fetched = pdb.fetch_missing(fs, [missing_id])
            if fetched.length() == 0 {
              raise err
            }
            if not(wrote_trace_round) {
              append_checkout_fetch_trace(fs)
              wrote_trace_round = true
            }
            attempts += 1
          }
          None => raise err
        }
    }
  }
  raise @git.GitError::InvalidObject("checkout lazy-fetch retry limit exceeded")
}

///|
fn collect_missing_checkout_blob_ids(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Array[@git.ObjectId] raise Error {
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  db.set_skip_verify(true)
  let files = @gitlib.collect_tree_files_from_commit(db, fs, commit_id) catch {
    _ => return []
  }
  let missing : Array[@git.ObjectId] = []
  let seen : Map[String, Bool] = {}
  for item in files.to_array() {
    let (_, entry) = item
    if entry.mode == 0o160000 {
      continue
    }
    let hex = entry.id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if db.get(fs, entry.id) is None {
      missing.push(entry.id)
    }
  }
  missing
}

///|
fn append_checkout_fetch_trace(fs : OsFs) -> Unit {
  match @sys.get_env_var("GIT_TRACE_PACKET") {
    Some(path) => append_checkout_trace_line(fs, path, "fetch> done\n")
    None => ()
  }
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) =>
      append_checkout_trace_line(
        fs, path, "{\"event\":\"data\",\"category\":\"fetch\",\"key\":\"total_rounds\",\"value\":\"1\"}\n",
      )
    None => ()
  }
}

///|
fn append_checkout_trace_line(fs : OsFs, path : String, line : String) -> Unit {
  let existing = decode_bytes(fs.read_file(path) catch { _ => b"" })
  fs.write_string(path, existing + line) catch {
    _ => ()
  }
}

///|
fn resolve_checkout_target(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  target : String,
) -> String raise Error {
  if target != "-" {
    return target
  }
  match load_previous_checkout_location(fs, git_dir) {
    Some(prev) => prev
    None =>
      raise @git.GitError::InvalidObject(
        "No previous checkout target available",
      )
  }
}

///|
fn current_checkout_location(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? raise Error {
  let head_path = git_dir + "/HEAD"
  if not(fs.is_file(head_path)) {
    return None
  }
  let head = trim_string(@utf8.decode_lossy(fs.read_file(head_path)[:]))
  if head.length() == 0 {
    return None
  }
  if head.has_prefix("ref: refs/heads/") {
    return Some(String::unsafe_substring(head, start=16, end=head.length()))
  }
  if head.has_prefix("ref: ") {
    return Some(String::unsafe_substring(head, start=5, end=head.length()))
  }
  Some(head)
}

///|
fn checkout_prev_location_path(git_dir : String) -> String {
  git_dir + "/bit-prev-checkout"
}

///|
fn load_previous_checkout_location(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? raise Error {
  let path = checkout_prev_location_path(git_dir)
  if not(fs.is_file(path)) {
    return None
  }
  let prev = trim_string(@utf8.decode_lossy(fs.read_file(path)[:]))
  if prev.length() == 0 {
    None
  } else {
    Some(prev)
  }
}

///|
fn save_previous_checkout_location(
  fs : &@git.FileSystem,
  git_dir : String,
  location : String?,
) -> Unit raise Error {
  match location {
    Some(value) if value.length() > 0 =>
      fs.write_string(checkout_prev_location_path(git_dir), value + "\n")
    _ => ()
  }
}

///|
fn parse_checkout_missing_object_id(err : Error) -> @git.ObjectId? {
  let prefixes = [
    "Missing blob object: ", "Missing tree object: ", "Object not found: ",
  ]
  match err {
    @git.GitError::InvalidObject(msg) => {
      for prefix in prefixes {
        if msg.has_prefix(prefix) {
          let hex = String::unsafe_substring(
            msg,
            start=prefix.length(),
            end=msg.length(),
          )
          return Some(@git.ObjectId::from_hex(trim_string(hex))) catch {
            _ => None
          }
        }
      }
      None
    }
    _ => None
  }
}

///|
