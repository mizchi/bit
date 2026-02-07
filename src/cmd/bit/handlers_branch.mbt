///| Branch handlers: branch, checkout, switch, reset, rebase, stash, cherry-pick

///|
async fn handle_branch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let mut list_mode = true
  let mut new_branch : String? = None
  let mut delete_branch : String? = None
  let mut rename_from : String? = None
  let mut rename_to : String? = None
  let mut rename_force = false
  let mut force_delete = false
  let mut show_all = false
  let mut show_remotes = false
  let mut verbose = false
  let mut set_upstream_to : String? = None
  let mut track_upstream = false
  let mut start_point : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "-M" if i + 2 < args.length() => {
        rename_from = Some(args[i + 1])
        rename_to = Some(args[i + 2])
        rename_force = arg == "-M"
        list_mode = false
        i += 3
        continue
      }
      "-d" | "--delete" if i + 1 < args.length() => {
        delete_branch = Some(args[i + 1])
        list_mode = false
        i += 2
        continue
      }
      "-D" if i + 1 < args.length() => {
        force_delete = true
        delete_branch = Some(args[i + 1])
        list_mode = false
        i += 2
        continue
      }
      "-a" | "--all" => show_all = true
      "-r" | "--remotes" => show_remotes = true
      "-v" | "--verbose" => verbose = true
      "-t" | "--track" => {
        track_upstream = true
        list_mode = false
        i += 1
        continue
      }
      "--set-upstream-to" if i + 1 < args.length() => {
        set_upstream_to = Some(args[i + 1])
        list_mode = false
        i += 2
        continue
      }
      _ if arg.has_prefix("--set-upstream-to=") => {
        let value = String::unsafe_substring(arg, start=18, end=arg.length())
        set_upstream_to = Some(value)
        list_mode = false
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) => {
        if new_branch is None {
          new_branch = Some(arg)
        } else if start_point is None {
          start_point = Some(arg)
        }
        list_mode = false
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("branch", arg)
      _ => ()
    }
    i += 1
  }
  match set_upstream_to {
    Some(upstream) => {
      let branch_name = match new_branch {
        Some(n) => n
        None => get_current_branch(fs, git_dir)
      }
      let mut remote_name = "origin"
      let mut merge_ref = upstream
      if upstream.has_prefix("refs/") {
        merge_ref = upstream
      } else {
        match upstream.find("/") {
          Some(idx) => {
            remote_name = String::unsafe_substring(upstream, start=0, end=idx)
            let name = String::unsafe_substring(
              upstream,
              start=idx + 1,
              end=upstream.length(),
            )
            merge_ref = "refs/heads/" + name
          }
          None => merge_ref = "refs/heads/" + upstream
        }
      }
      @gitlib.set_config_key(
        fs, fs, git_dir, "branch", branch_name, "remote", remote_name,
      )
      @gitlib.set_config_key(
        fs, fs, git_dir, "branch", branch_name, "merge", merge_ref,
      )
      return
    }
    None => ()
  }
  match delete_branch {
    Some(name) => {
      @gitlib.delete_branch(fs, fs, root, name, force=force_delete)
      print_line("Deleted branch \{name}")
    }
    None =>
      match rename_from {
        Some(from_name) =>
          match rename_to {
            Some(to_name) =>
              @gitlib.rename_branch(
                fs,
                fs,
                root,
                from_name,
                to_name,
                force=rename_force,
              )
            None => ()
          }
        None =>
          match new_branch {
            Some(name) => {
              match start_point {
                Some(sp) => {
                  let commit_id = @gitlib.rev_parse(fs, git_dir, sp)
                  guard commit_id is Some(id) else {
                    raise @git.GitError::InvalidObject(
                      "unknown revision: \{sp}",
                    )
                  }
                  @gitlib.create_branch_at(fs, fs, root, name, id)
                }
                None => @gitlib.create_branch(fs, fs, root, name)
              }
              if track_upstream {
                let upstream = match start_point {
                  Some(sp) => sp
                  None => "origin/" + name
                }
                let mut remote_name = "origin"
                let mut merge_ref = upstream
                if upstream.has_prefix("refs/") {
                  merge_ref = upstream
                } else {
                  match upstream.find("/") {
                    Some(idx) => {
                      remote_name = String::unsafe_substring(
                        upstream,
                        start=0,
                        end=idx,
                      )
                      let up_name = String::unsafe_substring(
                        upstream,
                        start=idx + 1,
                        end=upstream.length(),
                      )
                      merge_ref = "refs/heads/" + up_name
                    }
                    None => merge_ref = "refs/heads/" + upstream
                  }
                }
                @gitlib.set_config_key(
                  fs, fs, git_dir, "branch", name, "remote", remote_name,
                )
                @gitlib.set_config_key(
                  fs, fs, git_dir, "branch", name, "merge", merge_ref,
                )
              }
            }
            None =>
              if list_mode {
                // List local branches
                if not(show_remotes) {
                  let lines = if verbose {
                    @gitlib.list_branches_verbose(fs, git_dir)
                  } else {
                    @gitlib.list_branches_text(fs, git_dir)
                  }
                  for line in lines {
                    print_line(line)
                  }
                }
                // List remote branches
                if show_all || show_remotes {
                  let remotes = @gitlib.list_remote_branches(fs, git_dir)
                  for line in remotes {
                    print_line(line)
                  }
                }
              }
          }
      }
  }
}

///|
async fn handle_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
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
        let commit_id = @gitlib.rev_parse(fs, git_dir, ref_name)
        guard commit_id is Some(_) else {
          raise @git.GitError::InvalidObject("unknown revision: \{ref_name}")
        }
        // Checkout the start point first (detached)
        let _ = @gitlib.checkout(fs, fs, root, ref_name, detach=true)
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
      let _ = @gitlib.checkout(fs, fs, root, target)

    } else if is_file {
      // Restore single file
      @gitlib.restore_paths(fs, fs, root, [target])
    } else {
      // Try as branch/commit
      let _ = @gitlib.checkout(fs, fs, root, target)

    }
  } else {
    // Multiple targets: treat as file paths
    @gitlib.restore_paths(fs, fs, root, targets)
  }
}

///|
async fn handle_switch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut branch : String? = None
  let mut create = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-c" | "--create" => {
        create = true
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          branch = Some(args[i + 1])
          i += 2
          continue
        }
      }
      _ if not(arg.has_prefix("-")) => branch = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("switch", arg)
      _ => ()
    }
    i += 1
  }
  guard branch is Some(name) else {
    raise @git.GitError::InvalidObject("No branch specified")
  }
  @gitlib.switch_branch(fs, fs, root, name, create~)
  if create {
    println("Switched to a new branch '\{name}'")
  } else {
    println("Switched to branch '\{name}'")
  }
}

///|
async fn handle_reset(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut mode : @gitlib.ResetMode = @gitlib.ResetMode::Mixed
  let mut rev = "HEAD"
  for arg in args {
    match arg {
      "--soft" => mode = @gitlib.ResetMode::Soft
      "--mixed" => mode = @gitlib.ResetMode::Mixed
      "--hard" => mode = @gitlib.ResetMode::Hard
      _ if not(arg.has_prefix("-")) => rev = arg
      _ if arg.has_prefix("-") => warn_unimplemented_arg("reset", arg)
      _ => ()
    }
  }
  let commit_id = @gitlib.reset(fs, fs, root, rev, mode)
  let short_id = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
  println("HEAD is now at \{short_id}")
}

///|
async fn handle_rebase(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  // Parse arguments
  let mut do_continue = false
  let mut do_abort = false
  let mut do_skip = false
  let mut interactive = false
  let mut onto : String? = None
  let mut upstream : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--continue" => {
        do_continue = true
        i += 1
      }
      "--abort" => {
        do_abort = true
        i += 1
      }
      "--skip" => {
        do_skip = true
        i += 1
      }
      "-i" | "--interactive" => {
        interactive = true
        i += 1
      }
      "--onto" if i + 1 < args.length() => {
        onto = Some(args[i + 1])
        i += 2
      }
      _ if not(arg.has_prefix("-")) => {
        upstream = Some(arg)
        i += 1
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("rebase", arg)
        i += 1
      }
      _ => i += 1
    }
  }
  // Check if this is a subdir-clone and handle specially
  if is_subdir_clone(fs, git_dir) {
    handle_subdir_rebase(fs, root, git_dir, upstream) catch {
      e => raise e
    }
    return
  }
  // Handle --continue (works for both regular and interactive)
  if do_continue {
    // Check if interactive rebase is in progress
    let rebase_merge_dir = git_dir + "/rebase-merge"
    if rfs.is_dir(rebase_merge_dir) {
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    } else {
      let result = @gitlib.rebase_continue(fs, fs, root)
      print_rebase_result(result)
    }
    return ()
  }
  // Handle --abort
  if do_abort {
    let rebase_merge_dir = git_dir + "/rebase-merge"
    if rfs.is_dir(rebase_merge_dir) {
      interactive_rebase_abort(wfs, rfs, root, git_dir)
    } else {
      @gitlib.rebase_abort(fs, fs, root)
    }
    print_line("Rebase aborted")
    return ()
  }
  // Handle --skip
  if do_skip {
    let rebase_merge_dir = git_dir + "/rebase-merge"
    if rfs.is_dir(rebase_merge_dir) {
      interactive_rebase_skip(wfs, rfs, root, git_dir)
    } else {
      let result = @gitlib.rebase_skip(fs, fs, root)
      print_rebase_result(result)
    }
    return ()
  }
  // Start new rebase
  guard upstream is Some(ref_name) else {
    raise @git.GitError::InvalidObject("usage: git rebase [-i] <upstream>")
  }
  let upstream_id = @gitlib.rev_parse(fs, git_dir, ref_name)
  guard upstream_id is Some(id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{ref_name}")
  }
  if interactive {
    // Interactive rebase
    let onto_id = match onto {
      Some(o) => {
        let oid = @gitlib.rev_parse(rfs, git_dir, o)
        match oid {
          Some(x) => x
          None => id
        }
      }
      None => id
    }
    interactive_rebase_start(wfs, rfs, root, git_dir, id, onto_id)
  } else {
    let result = @gitlib.rebase_start(fs, fs, root, id)
    print_rebase_result(result)
  }
}

///|
async fn interactive_rebase_start(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  upstream : @git.ObjectId,
  onto : @git.ObjectId,
) -> Unit raise Error {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  // Get HEAD
  let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else {
    raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  // Collect commits to rebase
  let commits = collect_rebase_commits(db, rfs, h, upstream)
  if commits.length() == 0 {
    print_line("Current branch is up to date.")
    return
  }
  // Create rebase-merge directory
  let rebase_dir = git_dir + "/rebase-merge"
  wfs.mkdir_p(rebase_dir)
  // Save state
  wfs.write_string(rebase_dir + "/head-name", get_current_branch(rfs, git_dir))
  wfs.write_string(rebase_dir + "/orig-head", h.to_hex() + "\n")
  wfs.write_string(rebase_dir + "/onto", onto.to_hex() + "\n")
  // Generate todo file
  let todo = generate_rebase_todo(db, rfs, commits)
  let todo_path = rebase_dir + "/git-rebase-todo"
  wfs.write_string(todo_path, todo)
  // Also save done file (empty initially)
  wfs.write_string(rebase_dir + "/done", "")
  // Checkout onto
  ignore(@gitlib.checkout(wfs, rfs, root, onto.to_hex(), detach=true))
  let edited = edit_rebase_todo(todo_path)
  if edited {
    interactive_rebase_continue(wfs, rfs, root, git_dir)
    return
  }
  print_line("Interactive rebase started.")
  print_line("")
  print_line("Edit the todo file at: \{todo_path}")
  print_line("")
  print_line("Commands:")
  print_line(" p, pick   = use commit")
  print_line(" r, reword = use commit, but edit commit message")
  print_line(" e, edit   = use commit, but stop for amending")
  print_line(" s, squash = use commit, but meld into previous commit")
  print_line(" f, fixup  = like squash, but discard commit message")
  print_line(" d, drop   = remove commit")
  print_line("")
  print_line(
    "Set GIT_SEQUENCE_EDITOR (or EDITOR), then run 'git rebase --continue'.",
  )
}

///|
fn collect_rebase_commits(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  head : @git.ObjectId,
  upstream : @git.ObjectId,
) -> Array[@git.ObjectId] raise Error {
  let result : Array[@git.ObjectId] = []
  let upstream_hex = upstream.to_hex()
  let mut current = head
  while current.to_hex() != upstream_hex {
    result.push(current)
    let obj = db.get(rfs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data)
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get chronological order (oldest first)
  result.rev_in_place()
  result
}

///|
fn generate_rebase_todo(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commits : Array[@git.ObjectId],
) -> String raise Error {
  let sb = StringBuilder::new()
  for commit in commits {
    let full_hex = commit.to_hex()
    let obj = db.get(rfs, commit)
    let subject = match obj {
      Some(o) => {
        let msg = extract_commit_message(o.data)
        get_first_line(msg)
      }
      None => "???"
    }
    sb.write_string("pick ")
    sb.write_string(full_hex)
    sb.write_string(" ")
    sb.write_string(subject)
    sb.write_string("\n")
  }
  sb.write_string("\n")
  sb.write_string("# Rebase commands:\n")
  sb.write_string("# p, pick = use commit\n")
  sb.write_string("# r, reword = use commit, but edit the commit message\n")
  sb.write_string("# e, edit = use commit, but stop for amending\n")
  sb.write_string("# s, squash = use commit, but meld into previous commit\n")
  sb.write_string(
    "# f, fixup = like squash, but discard this commit's log message\n",
  )
  sb.write_string("# d, drop = remove commit\n")
  sb.write_string("#\n")
  sb.write_string("# Lines starting with '#' will be ignored.\n")
  sb.to_string()
}

///|
fn get_current_branch(rfs : &@git.RepoFileSystem, git_dir : String) -> String {
  let head_path = git_dir + "/HEAD"
  if rfs.is_file(head_path) {
    let content = trim_string(
      decode_bytes(rfs.read_file(head_path) catch { _ => return "HEAD" }),
    )
    if content.has_prefix("ref: refs/heads/") {
      return String::unsafe_substring(content, start=16, end=content.length())
    }
  }
  "HEAD"
}

///|
async fn interactive_rebase_continue(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
) -> Unit raise Error {
  let rebase_dir = git_dir + "/rebase-merge"
  let todo_path = rebase_dir + "/git-rebase-todo"
  let done_path = rebase_dir + "/done"
  // Read todo file
  let todo_content = if rfs.is_file(todo_path) {
    decode_bytes(rfs.read_file(todo_path))
  } else {
    ""
  }
  // Parse todo entries
  let entries = parse_rebase_todo(todo_content)
  if entries.length() == 0 {
    // Rebase complete
    interactive_rebase_finish(wfs, rfs, root, git_dir)
    return
  }
  // Process first entry
  let entry = entries[0]
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  match entry.command {
    "pick" | "p" => {
      // Cherry-pick the commit
      let result = cherry_pick_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
      )
      if result.has_conflict {
        print_line(
          "CONFLICT: Resolve conflicts then run 'git rebase --continue'",
        )
        return
      }
      // Move to done
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      // Continue with next
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "reword" | "r" => {
      // Cherry-pick then prompt for new message
      let result = cherry_pick_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
      )
      if result.has_conflict {
        print_line(
          "CONFLICT: Resolve conflicts then run 'git rebase --continue'",
        )
        return
      }
      // For reword, we need to amend with new message
      // In non-interactive mode, just use original message
      print_line("Reword: commit \{entry.commit_ref}")
      print_line(
        "(In this implementation, edit the commit message manually with 'git commit --amend')",
      )
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "edit" | "e" => {
      // Cherry-pick then stop
      let result = cherry_pick_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
      )
      if result.has_conflict {
        print_line(
          "CONFLICT: Resolve conflicts then run 'git rebase --continue'",
        )
        return
      }
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      print_line("Stopped at \{entry.commit_ref}")
      print_line(
        "You can amend the commit now, then run 'git rebase --continue'",
      )
    }
    "squash" | "s" => {
      // Cherry-pick and squash into previous
      squash_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
        author,
        timestamp,
        false,
      )
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "fixup" | "f" => {
      // Cherry-pick and fixup (squash without message)
      squash_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
        author,
        timestamp,
        true,
      )
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "drop" | "d" => {
      // Skip this commit
      print_line("Dropping \{entry.commit_ref}")
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    _ => {
      // Unknown command, skip
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
  }
  ignore(done_path)
}

///|
struct RebaseTodoEntry {
  command : String
  commit_ref : String
  message : String
}

///|
fn parse_rebase_todo(content : String) -> Array[RebaseTodoEntry] {
  let result : Array[RebaseTodoEntry] = []
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    // Skip comments and empty lines
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    // Parse "command commit message"
    let parts = split_whitespace(line, 3)
    if parts.length() >= 2 {
      result.push({
        command: parts[0],
        commit_ref: parts[1],
        message: if parts.length() > 2 {
          parts[2]
        } else {
          ""
        },
      })
    }
  }
  result
}

///|
fn split_whitespace(s : String, max_parts : Int) -> Array[String] {
  let result : Array[String] = []
  let current = StringBuilder::new()
  let mut in_word = false
  for c in s {
    if c == ' ' || c == '\t' {
      if in_word {
        result.push(current.to_string())
        if result.length() >= max_parts - 1 {
          // Rest of string goes into last part
          let rest = get_rest_after_parts(s, result.length())
          if rest.length() > 0 {
            result.push(rest)
          }
          return result
        }
        current.reset()
        in_word = false
      }
    } else {
      current.write_char(c)
      in_word = true
    }
  }
  if in_word {
    result.push(current.to_string())
  }
  result
}

///|
fn get_rest_after_parts(s : String, num_parts : Int) -> String {
  let mut parts_found = 0
  let mut i = 0
  let mut in_word = false
  while i < s.length() {
    let c = s[i]
    if c == ' ' || c == '\t' {
      if in_word {
        parts_found += 1
        if parts_found >= num_parts {
          // Skip whitespace and return rest
          while i < s.length() && (s[i] == ' ' || s[i] == '\t') {
            i += 1
          }
          return String::unsafe_substring(s, start=i, end=s.length())
        }
        in_word = false
      }
    } else {
      in_word = true
    }
    i += 1
  }
  ""
}

///|
fn move_todo_to_done(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  rebase_dir : String,
  entry : RebaseTodoEntry,
) -> Unit {
  let todo_path = rebase_dir + "/git-rebase-todo"
  let done_path = rebase_dir + "/done"
  // Append to done
  let done_content = if rfs.is_file(done_path) {
    decode_bytes(rfs.read_file(done_path) catch { _ => return })
  } else {
    ""
  }
  let new_done = done_content +
    entry.command +
    " " +
    entry.commit_ref +
    " " +
    entry.message +
    "\n"
  wfs.write_string(done_path, new_done) catch {
    _ => ()
  }
  // Remove first line from todo
  let todo_content = if rfs.is_file(todo_path) {
    decode_bytes(rfs.read_file(todo_path) catch { _ => return })
  } else {
    ""
  }
  let new_todo = remove_first_non_comment_line(todo_content)
  wfs.write_string(todo_path, new_todo) catch {
    _ => ()
  }
}

///|
fn remove_first_non_comment_line(content : String) -> String {
  let lines : Array[String] = []
  let mut skipped_first = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if not(skipped_first) {
      let trimmed = trim_string(line)
      if trimmed.length() > 0 && not(trimmed.has_prefix("#")) {
        skipped_first = true
        continue
      }
    }
    lines.push(line)
  }
  lines.join("\n")
}

///|
struct CherryPickResult {
  has_conflict : Bool
}

///|
async fn cherry_pick_commit(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  db : @gitlib.ObjectDb,
  commit_ref : String,
) -> CherryPickResult raise Error {
  // Resolve commit
  let commit_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("Cannot resolve: \{commit_ref}")
  }
  let obj = db.get(rfs, cid)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Cannot read commit: \{commit_ref}")
  }
  let info = @git.parse_commit(o.data)
  let message = extract_commit_message(o.data)
  let author_line = extract_author_line_from_bytes(o.data)
  let timestamp = get_commit_timestamp()
  // Simple cherry-pick: apply changes from commit
  // For now, create a new commit with the same tree
  // (This is simplified - real cherry-pick should apply diff)
  let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else {
    raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  // Create commit
  let commit = @git.Commit::new(
    info.tree,
    [h],
    author_line,
    timestamp,
    "+0000",
    author_line,
    timestamp,
    "+0000",
    message,
  )
  let (new_commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  // Update HEAD
  wfs.write_string(git_dir + "/HEAD", new_commit_id.to_hex() + "\n")
  // Checkout the tree
  ignore(@gitlib.checkout(wfs, rfs, root, new_commit_id.to_hex(), detach=true))
  let short = String::unsafe_substring(new_commit_id.to_hex(), start=0, end=7)
  print_line("[\{short}] \{get_first_line(message)}")
  { has_conflict: false }
}

///|
async fn squash_commit(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  db : @gitlib.ObjectDb,
  commit_ref : String,
  author : String,
  timestamp : Int64,
  fixup : Bool,
) -> Unit raise Error {
  // Get commit to squash
  let commit_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else { return }
  let obj = db.get(rfs, cid)
  guard obj is Some(o) else { return }
  let info = @git.parse_commit(o.data)
  let squash_msg = extract_commit_message(o.data)
  // Get current HEAD
  let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else { return }
  let head_obj = db.get(rfs, h)
  guard head_obj is Some(ho) else { return }
  let head_info = @git.parse_commit(ho.data)
  let head_msg = extract_commit_message(ho.data)
  // New message: combine or just use head's
  let new_msg = if fixup { head_msg } else { head_msg + "\n\n" + squash_msg }
  // Create new commit with squashed changes
  // Use squashed commit's tree (simplified)
  let commit = @git.Commit::new(
    info.tree,
    head_info.parents,
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    new_msg,
  )
  let (new_commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  // Update HEAD
  wfs.write_string(git_dir + "/HEAD", new_commit_id.to_hex() + "\n")
  ignore(@gitlib.checkout(wfs, rfs, root, new_commit_id.to_hex(), detach=true))
  let short = String::unsafe_substring(new_commit_id.to_hex(), start=0, end=7)
  if fixup {
    print_line("[\{short}] fixup")
  } else {
    print_line("[\{short}] squash")
  }
}

///|
fn interactive_rebase_abort(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
) -> Unit raise Error {
  let rebase_dir = git_dir + "/rebase-merge"
  let orig_head_path = rebase_dir + "/orig-head"
  let head_name_path = rebase_dir + "/head-name"
  // Restore original HEAD
  if rfs.is_file(orig_head_path) {
    let orig_hex = rfs.read_file(orig_head_path) |> decode_bytes |> trim_string
    ignore(@gitlib.checkout(wfs, rfs, root, orig_hex, detach=true))
    // Restore branch if was on one
    if rfs.is_file(head_name_path) {
      let branch = rfs.read_file(head_name_path) |> decode_bytes |> trim_string
      if branch != "HEAD" {
        wfs.write_string(git_dir + "/refs/heads/" + branch, orig_hex + "\n")
        wfs.write_string(git_dir + "/HEAD", "ref: refs/heads/" + branch + "\n")
      }
    }
  }
  // Clean up rebase directory
  cleanup_rebase_dir(wfs, rfs, rebase_dir)
}

///|
async fn interactive_rebase_skip(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
) -> Unit raise Error {
  let rebase_dir = git_dir + "/rebase-merge"
  let todo_path = rebase_dir + "/git-rebase-todo"
  // Read and skip first entry
  let todo_content = if rfs.is_file(todo_path) {
    decode_bytes(rfs.read_file(todo_path))
  } else {
    ""
  }
  let entries = parse_rebase_todo(todo_content)
  if entries.length() > 0 {
    move_todo_to_done(wfs, rfs, rebase_dir, entries[0])
    print_line("Skipping \{entries[0].commit_ref}")
  }
  // Continue
  interactive_rebase_continue(wfs, rfs, root, git_dir)
}

///|
async fn interactive_rebase_finish(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  _root : String,
  git_dir : String,
) -> Unit raise Error {
  let rebase_dir = git_dir + "/rebase-merge"
  let head_name_path = rebase_dir + "/head-name"
  // Get current HEAD
  let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else { return }
  // Restore branch pointer
  if rfs.is_file(head_name_path) {
    let branch = rfs.read_file(head_name_path) |> decode_bytes |> trim_string
    if branch != "HEAD" {
      wfs.write_string(git_dir + "/refs/heads/" + branch, h.to_hex() + "\n")
      wfs.write_string(git_dir + "/HEAD", "ref: refs/heads/" + branch + "\n")
    }
  }
  // Clean up
  cleanup_rebase_dir(wfs, rfs, rebase_dir)
  print_line("Successfully rebased.")
}

///|
fn cleanup_rebase_dir(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  rebase_dir : String,
) -> Unit {
  let files = rfs.readdir(rebase_dir) catch { _ => return }
  for file in files {
    wfs.remove_file(rebase_dir + "/" + file) catch {
      _ => ()
    }
  }
  wfs.remove_file(rebase_dir) catch {
    _ => ()
  }
}

///|
async fn print_rebase_result(result : @gitlib.RebaseResult) -> Unit {
  match result.status {
    @gitlib.RebaseStatus::Complete =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Successfully rebased and updated refs. [\{short}]")
        }
        None => print_line("Successfully rebased.")
      }
    @gitlib.RebaseStatus::NothingToRebase =>
      print_line("Current branch is up to date.")
    @gitlib.RebaseStatus::Conflict => {
      print_line("CONFLICT: Merge conflict in:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("")
      print_line("Resolve all conflicts, then run \"git rebase --continue\".")
      print_line(
        "To abort and return to the original state, run \"git rebase --abort\".",
      )
      print_line("To skip this commit, run \"git rebase --skip\".")
    }
  }
}

///|
async fn handle_stash(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Determine subcommand (default: push if args are empty or start with -)
  let subcmd = if args.length() == 0 {
    "push"
  } else {
    let first = args[0]
    if first.has_prefix("-") {
      "push"
    } else {
      first
    }
  }
  let rest : Array[String] = if args.length() > 0 &&
    not(args[0].has_prefix("-")) {
    args.iter().drop(1).collect()
  } else {
    args.iter().collect()
  }
  match subcmd {
    "push" | "save" => {
      // Parse message option
      let mut message = ""
      let mut i = 0
      while i < rest.length() {
        let arg = rest[i]
        match arg {
          "-m" | "--message" if i + 1 < rest.length() => {
            message = rest[i + 1]
            i += 2
            continue
          }
          _ => ()
        }
        i += 1
      }
      let author = get_author_string()
      let timestamp = get_commit_timestamp()
      let result = @gitlib.stash_push(fs, fs, root, message, author, timestamp)
      match result {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Saved working directory and index state [\{short}]")
        }
        None => print_line("No local changes to save")
      }
    }
    "list" => {
      let entries = @gitlib.stash_list(fs, git_dir)
      for i, entry in entries {
        let short = String::unsafe_substring(entry.id.to_hex(), start=0, end=7)
        print_line("stash@{" + i.to_string() + "}: \{entry.message} [\{short}]")
      }
    }
    "pop" => {
      let index = parse_stash_index(rest)
      @gitlib.stash_apply(fs, fs, root, index, true)
      print_line("Dropped stash@{" + index.to_string() + "}")
    }
    "apply" => {
      let index = parse_stash_index(rest)
      @gitlib.stash_apply(fs, fs, root, index, false)
      print_line("Applied stash@{" + index.to_string() + "}")
    }
    "drop" => {
      let index = parse_stash_index(rest)
      @gitlib.stash_drop(fs, fs, root, index)
      print_line("Dropped stash@{" + index.to_string() + "}")
    }
    "clear" => {
      // Remove all stash entries
      let stash_ref = git_dir + "/refs/stash"
      let reflog_path = git_dir + "/logs/refs/stash"
      if fs.is_file(stash_ref) {
        fs.remove_file(stash_ref)
      }
      if fs.is_file(reflog_path) {
        fs.remove_file(reflog_path)
      }
      print_line("Cleared all stash entries")
    }
    _ =>
      raise @git.GitError::InvalidObject("Unknown stash subcommand: \{subcmd}")
  }
}

///|
fn parse_stash_index(args : Array[String]) -> Int {
  for arg in args {
    // Parse stash@{N} or just a number
    if arg.has_prefix("stash@{") && arg.has_suffix("}") {
      let num_str = String::unsafe_substring(arg, start=7, end=arg.length() - 1)
      let n = @strconv.parse_int(num_str) catch { _ => continue }
      return n
    }
    let n = @strconv.parse_int(arg) catch { _ => continue }
    return n
  }
  0 // Default to first stash entry
}

///|

///|
/// Show branches and their commits (git show-branch)
async fn handle_show_branches(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse arguments
  let mut show_all = false
  let mut max_count = 10
  let mut show_remotes = false
  let specific_branches : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-a" | "--all" => show_all = true
      "-r" | "--remotes" => show_remotes = true
      "--more" if i + 1 < args.length() => {
        max_count = @strconv.parse_int(args[i + 1]) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => 10
        }
        i += 2
        continue
      }
      _ if arg.has_prefix("--more=") => {
        let val = String::unsafe_substring(arg, start=7, end=arg.length())
        max_count = @strconv.parse_int(val) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => 10
        }
      }
      _ if not(arg.has_prefix("-")) => specific_branches.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("show-branch", arg)
      _ => ()
    }
    i += 1
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  // Get branches to show
  let (head_ref, all_branches) = @gitlib.list_branches(fs, git_dir)
  let branches_to_show : Array[@gitlib.BranchInfo] = if specific_branches.length() >
    0 {
    all_branches.filter(b => specific_branches.contains(b.name))
  } else {
    all_branches
  }
  if branches_to_show.length() == 0 {
    return
  }
  // Print branch headers
  let branch_chars = "!*+-o=#@%&"
  for idx, branch in branches_to_show {
    let marker = if idx < branch_chars.length() {
      branch_chars[idx].to_string()
    } else {
      "!"
    }
    let current_marker = if branch.current { "*" } else { " " }
    // Get commit message
    let msg = show_branch_get_subject(db, fs, branch.id)
    print_line("\{current_marker} [\{branch.name}] \{msg}")
    ignore(marker)
  }
  print_line("---")
  // Print commits with branch indicators
  let displayed : Map[String, Bool] = {}
  for branch_idx, branch in branches_to_show {
    let commits = show_branch_collect_commits(db, fs, branch.id, max_count, {})
    for commit_pair in commits {
      let (commit_id, msg) = commit_pair
      let hex = commit_id.to_hex()
      if displayed.contains(hex) {
        continue
      }
      displayed[hex] = true
      // Build indicator line
      let indicators = StringBuilder::new()
      for i = 0; i < branches_to_show.length(); i = i + 1 {
        if i == branch_idx {
          let ch = if i < branch_chars.length() {
            branch_chars[i].to_string()
          } else {
            "+"
          }
          indicators.write_string(ch)
        } else {
          // Check if this commit is reachable from branch i
          let reachable = show_branch_is_reachable(
            db,
            fs,
            commit_id,
            branches_to_show[i].id,
            max_count * 2,
          )
          if reachable {
            let ch = if i < branch_chars.length() {
              branch_chars[i].to_string()
            } else {
              "+"
            }
            indicators.write_string(ch)
          } else {
            indicators.write_string(" ")
          }
        }
      }
      let short_id = String::unsafe_substring(hex, start=0, end=7)
      print_line("\{indicators.to_string()} [\{short_id}] \{msg}")
    }
  }
  ignore(show_all)
  ignore(show_remotes)
  ignore(head_ref)
}

///|
fn show_branch_get_subject(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> String {
  let obj = db.get(fs, commit_id) catch { _ => return "???" }
  match obj {
    Some(o) => {
      let msg = extract_commit_message(o.data)
      get_first_line(msg)
    }
    None => "???"
  }
}

///|
fn show_branch_collect_commits(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  start : @git.ObjectId,
  max_count : Int,
  skip : Map[String, Bool],
) -> Array[(@git.ObjectId, String)] {
  let result : Array[(@git.ObjectId, String)] = []
  let mut current = start
  let mut count = 0
  while count < max_count {
    let hex = current.to_hex()
    if skip.contains(hex) {
      break
    }
    let obj = db.get(fs, current) catch { _ => break }
    match obj {
      None => break
      Some(o) => {
        let info = @git.parse_commit(o.data) catch { _ => break }
        let msg = extract_commit_message(o.data)
        let subject = get_first_line(msg)
        result.push((current, subject))
        if info.parents.length() == 0 {
          break
        }
        current = info.parents[0]
        count += 1
      }
    }
  }
  result
}

///|
fn show_branch_is_reachable(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  target : @git.ObjectId,
  from : @git.ObjectId,
  max_depth : Int,
) -> Bool {
  let target_hex = target.to_hex()
  let mut current = from
  let mut depth = 0
  while depth < max_depth {
    if current.to_hex() == target_hex {
      return true
    }
    let obj = db.get(fs, current) catch { _ => return false }
    match obj {
      None => return false
      Some(o) => {
        let info = @git.parse_commit(o.data) catch { _ => return false }
        if info.parents.length() == 0 {
          return false
        }
        current = info.parents[0]
        depth += 1
      }
    }
  }
  false
}

///|
/// Handle rebase for subdir-clone repositories
async fn handle_subdir_rebase(
  fs : OsFs,
  root : String,
  git_dir : String,
  upstream : String?,
) -> Unit raise Error {
  // Read subdir metadata
  let (_remote_url, subdir_path, base_hex) = match
    read_subdir_attributes(fs, git_dir) {
    Some(info) => info
    None => {
      print_line("Error: not a subdir-clone repository")
      return
    }
  }
  let target_ref = upstream.unwrap_or("origin/main")
  print_line("Rebasing subdir-clone onto \{target_ref}...")
  print_line("  Subdirectory: \{subdir_path}")
  print_line("  Base commit: \{base_hex}")
  // Step 1: Fetch from origin
  print_line("  Fetching from origin...")
  let _ = @process.run("git", ["-C", root, "fetch", "origin"])
  // Step 2: Resolve upstream ref
  let upstream_path = git_dir + "/refs/remotes/" + target_ref
  let upstream_bytes = fs.read_file(upstream_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => {
      print_line("Error: cannot resolve ref: \{target_ref}")
      print_line("Make sure it exists (e.g., origin/main)")
      return
    }
  }
  let upstream_hex = subdir_bytes_to_string(upstream_bytes)
    .trim(chars=" \n\t")
    .to_string()
  print_line("  Upstream: \{upstream_hex}")
  // Step 3: Find commits affecting subdirectory
  print_line("  Finding changes to \{subdir_path}...")
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  let commits = find_subdir_affecting_commits(
    db, fs, base_hex, upstream_hex, subdir_path,
  ) catch {
    err => raise err
  }
  if commits.length() == 0 {
    print_line("Already up to date. No changes to \{subdir_path}.")
    update_subdir_base(fs, git_dir, upstream_hex)
    return
  }
  print_line("  Found \{commits.length()} commits affecting \{subdir_path}")
  // Step 4: Apply each commit
  for commit_info in commits {
    print_line("  Applying: \{commit_info.message}")
    apply_subdir_change(fs, db, root, git_dir, commit_info) catch {
      err => raise err
    }
  }
  // Step 5: Update base commit
  update_subdir_base(fs, git_dir, upstream_hex)
  // Step 6: Reset index
  let _ = @process.run("git", ["-C", root, "reset", "HEAD"])
  print_line("done.")
  print_line("")
  print_line("Successfully rebased onto \{target_ref}")
}

///|
struct SubdirChangeInfo {
  id : @git.ObjectId
  subdir_tree : @git.ObjectId
  message : String
  author : String
}

///|
fn find_subdir_affecting_commits(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  base_hex : String,
  target_hex : String,
  subdir_path : String,
) -> Array[SubdirChangeInfo] raise @git.GitError {
  let result : Array[SubdirChangeInfo] = []
  let base_id = @git.ObjectId::from_hex(base_hex) catch {
    _ => raise @git.GitError::InvalidObject("Invalid base: " + base_hex)
  }
  let target_id = @git.ObjectId::from_hex(target_hex) catch {
    _ => raise @git.GitError::InvalidObject("Invalid target: " + target_hex)
  }
  // Get base subdir tree
  let base_subdir = get_commit_subdir_tree(db, fs, base_id, subdir_path) catch {
    err => raise err
  }
  // Walk from target to base, collect commits
  let commits_to_check : Array[@git.ObjectId] = []
  let visited : Map[String, Bool] = {}
  let mut current = target_id
  while true {
    let hex = current.to_hex()
    if visited.contains(hex) || hex == base_hex {
      break
    }
    visited[hex] = true
    commits_to_check.push(current)
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { err => raise err }
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Process oldest first
  let mut prev_tree = base_subdir
  let mut i = commits_to_check.length() - 1
  while i >= 0 {
    let commit_id = commits_to_check[i]
    let curr_tree = get_commit_subdir_tree(db, fs, commit_id, subdir_path) catch {
      _ => {
        i -= 1
        continue
      }
    }
    // Check if changed
    let changed = match (prev_tree, curr_tree) {
      (Some(p), Some(c)) => p.to_hex() != c.to_hex()
      (None, Some(_)) => true
      _ => false
    }
    if changed {
      guard curr_tree is Some(tree) else {
        i -= 1
        continue
      }
      // Get commit info
      let obj = db.get(fs, commit_id)
      guard obj is Some(o) else {
        i -= 1
        continue
      }
      let (author, message) = parse_commit_author_message(o.data)
      result.push({ id: commit_id, subdir_tree: tree, message, author })
      prev_tree = curr_tree
    }
    i -= 1
  }
  result
}

///|
fn get_commit_subdir_tree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commit_id : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(fs, commit_id)
  guard obj is Some(o) else { return None }
  let info = @git.parse_commit(o.data) catch { err => raise err }
  find_tree_subtree(db, fs, info.tree, subdir_path) catch {
    err => raise err
  }
}

///|
fn find_tree_subtree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? raise @git.GitError {
  let parts : Array[String] = []
  for p in path.split("/") {
    let s = p.to_string()
    if s.length() > 0 {
      parts.push(s)
    }
  }
  let mut current = tree_id
  for part in parts {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { return None }
    let entries = @git.parse_tree(o.data) catch { err => raise err }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        current = entry.id
        found = true
        break
      }
    }
    if not(found) {
      return None
    }
  }
  Some(current)
}

///|
fn parse_commit_author_message(content : Bytes) -> (String, String) {
  let text = @utf8.decode_lossy(content[:])
  let mut author = ""
  let mut in_message = false
  let message = StringBuilder::new()
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      message.write_string(line)
      message.write_char('\n')
      continue
    }
    if line.length() == 0 {
      in_message = true
      continue
    }
    if line.has_prefix("author ") {
      author = String::unsafe_substring(line, start=7, end=line.length())
    }
  }
  (author, message.to_string().trim(chars=" \n\t").to_string())
}

///|
fn apply_subdir_change(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  worktree : String,
  git_dir : String,
  info : SubdirChangeInfo,
) -> Unit raise @git.GitError {
  // Clear worktree (keep .git)
  let entries = fs.readdir(worktree) catch { _ => [] }
  for entry in entries {
    if entry == ".git" {
      continue
    }
    let path = worktree + "/" + entry
    if fs.is_dir(path) {
      subdir_clear_dir(fs, path)
    } else {
      fs.remove_file(path) catch {
        _ => ()
      }
    }
  }
  // Write new tree
  subdir_write_tree(db, fs, info.subdir_tree, worktree) catch {
    err => raise err
  }
  // Create commit
  let timestamp = get_current_timestamp()
  let message = info.message + "\n\n(rebased from " + info.id.to_hex() + ")\n"
  // Get current HEAD
  let head_bytes = fs.read_file(git_dir + "/HEAD") catch {
    _ => raise @git.GitError::IoError("Failed to read HEAD")
  }
  let head_text = subdir_bytes_to_string(head_bytes)
    .trim(chars=" \n\t")
    .to_string()
  let parent_id = if head_text.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_text,
      start=5,
      end=head_text.length(),
    )
    let ref_bytes = fs.read_file(git_dir + "/" + ref_name) catch {
      _ => raise @git.GitError::IoError("Failed to read ref")
    }
    let ref_hex = subdir_bytes_to_string(ref_bytes)
      .trim(chars=" \n\t")
      .to_string()
    @git.ObjectId::from_hex(ref_hex) catch {
      _ => raise @git.GitError::InvalidObject("Invalid ref")
    }
  } else {
    @git.ObjectId::from_hex(head_text) catch {
      _ => raise @git.GitError::InvalidObject("Invalid HEAD")
    }
  }
  let commit = @git.Commit::new(
    info.subdir_tree,
    [parent_id],
    info.author,
    timestamp,
    "+0000",
    info.author,
    timestamp,
    "+0000",
    message,
  )
  let (new_id, commit_bytes) = @git.create_commit(commit)
  @gitlib.write_object_bytes(fs, git_dir, new_id, commit_bytes) catch {
    _ => raise @git.GitError::IoError("Failed to write commit")
  }
  // Update HEAD
  let ref_path = git_dir + "/refs/heads/main"
  fs.write_file(ref_path, subdir_string_to_bytes(new_id.to_hex() + "\n")) catch {
    _ => ()
  }
}

///|
fn subdir_clear_dir(fs : OsFs, path : String) -> Unit {
  let entries = fs.readdir(path) catch { _ => return }
  for entry in entries {
    let child = path + "/" + entry
    if fs.is_dir(child) {
      subdir_clear_dir(fs, child)
    } else {
      fs.remove_file(child) catch {
        _ => ()
      }
    }
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn subdir_write_tree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  dir : String,
) -> Unit raise @git.GitError {
  let obj = db.get(fs, tree_id)
  guard obj is Some(o) else { return }
  let entries = @git.parse_tree(o.data) catch { err => raise err }
  for entry in entries {
    let path = dir + "/" + entry.name
    if entry.mode == "40000" || entry.mode == "040000" {
      fs.mkdir_p(path) catch {
        _ => ()
      }
      subdir_write_tree(db, fs, entry.id, path) catch {
        err => raise err
      }
    } else {
      let blob = db.get(fs, entry.id)
      guard blob is Some(b) else { continue }
      fs.write_file(path, b.data) catch {
        _ => ()
      }
    }
  }
}

///|
fn subdir_bytes_to_string(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i in 0..<bytes.length() {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn subdir_string_to_bytes(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
async fn handle_cherry_pick(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse arguments
  let mut commit_spec : String? = None
  for arg in args {
    if not(arg.has_prefix("-")) {
      commit_spec = Some(arg)
      break
    }
    warn_unimplemented_arg("cherry-pick", arg)
  }
  guard commit_spec is Some(spec) else {
    raise @git.GitError::InvalidObject("commit required")
  }
  // Check if subdir-clone and handle specially
  match get_subdir_info(fs, git_dir) {
    Some((_, subdir_path, _)) => {
      handle_subdir_cherry_pick(fs, root, git_dir, spec, subdir_path) catch {
        err => raise err
      }
      return
    }
    None => ()
  }
  // Resolve commit
  let commit_id = @gitlib.rev_parse(fs, git_dir, spec)
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{spec}")
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let result = @gitlib.cherry_pick(fs, fs, root, cid, author, timestamp)
  match result.status {
    @gitlib.CherryPickStatus::Success =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("[\{short}] Cherry-picked from \{spec}")
        }
        None => print_line("Cherry-pick successful")
      }
    @gitlib.CherryPickStatus::Conflict => {
      print_line("CONFLICT: Merge conflict in cherry-pick:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("")
      print_line("After fixing the conflicts, use \"git commit\" to continue.")
    }
  }
}

///|
/// Handle cherry-pick for subdir-clone
async fn handle_subdir_cherry_pick(
  fs : OsFs,
  root : String,
  git_dir : String,
  spec : String,
  subdir_path : String,
) -> Unit raise Error {
  print_line("Cherry-picking from upstream (subdir: \{subdir_path})...")
  // Resolve commit
  let commit_id = resolve_ref_for_subdir(fs, git_dir, spec) catch {
    err => raise err
  }
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{spec}")
  }
  // Load object database
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Get upstream commit's subdir tree
  let upstream_tree = get_subdir_tree_from_commit(db, fs, cid, subdir_path) catch {
    err => raise err
  }
  guard upstream_tree is Some(utree) else {
    raise @git.GitError::InvalidObject(
      "Subdirectory not found in commit: \{subdir_path}",
    )
  }
  // Get upstream commit's parent subdir tree
  let commit_obj = db.get(fs, cid)
  guard commit_obj is Some(co) else {
    raise @git.GitError::InvalidObject("Cannot read commit")
  }
  let commit_info = @git.parse_commit(co.data) catch { err => raise err }
  let parent_tree = if commit_info.parents.length() > 0 {
    get_subdir_tree_from_commit(db, fs, commit_info.parents[0], subdir_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => None
    }
  } else {
    None
  }
  // Check if this commit changes the subdir
  let changed = match parent_tree {
    Some(pt) => pt.to_hex() != utree.to_hex()
    None => true
  }
  if not(changed) {
    print_line("Commit \{spec} does not change \{subdir_path}, skipping.")
    return
  }
  // Apply the subdir change
  let (author, message) = parse_commit_author_message(co.data)
  let change_info : SubdirChangeInfo = {
    id: cid,
    subdir_tree: utree,
    message,
    author,
  }
  apply_subdir_change(fs, db, root, git_dir, change_info) catch {
    err => raise err
  }
  print_line("Cherry-picked: \{message}")
}
