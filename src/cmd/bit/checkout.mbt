///|
async fn handle_checkout(args : Array[String]) -> Unit raise Error {
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
    return ()
  }
  // If -- was used, treat all targets as file paths
  if saw_separator {
    @gitlib.restore_paths(fs, fs, root, targets)
    return ()
  }
  // Single target: determine if it's a branch or file
  if targets.length() == 1 {
    let target = targets[0]
    let is_file = fs.is_file(root + "/" + target)
    let is_branch = @gitlib.resolve_ref(fs, git_dir, "refs/heads/" + target)
      is Some(_)
    if is_file && is_branch {
      // Ambiguous - default to branch (like git)
      let _ = checkout_with_promisor_retry(fs, root, target)
    } else if is_file {
      // Restore single file
      @gitlib.restore_paths(fs, fs, root, [target])
    } else {
      // Try as branch/commit
      let _ = checkout_with_promisor_retry(fs, root, target)
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
  let mut promisor_db : @gitlib.PromisorDb? = None
  let mut attempts = 0
  while attempts < 16 {
    let result : Result[@git.ObjectId, Error] = try? @gitlib.checkout(
      fs,
      fs,
      root,
      spec,
      detach=detach,
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
            attempts += 1
          }
          None => raise err
        }
    }
  }
  raise @git.GitError::InvalidObject("checkout lazy-fetch retry limit exceeded")
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
          return Some(@git.ObjectId::from_hex(trim_string(hex))) catch { _ => None }
        }
      }
      None
    }
    _ => None
  }
}

///|
