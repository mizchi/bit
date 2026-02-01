///| Worktree handlers: worktree list/add/remove/prune/lock/unlock/move/repair

///|
/// Get absolute work root path for worktree operations
fn get_absolute_work_root() -> String {
  let root = get_work_root()
  if root == "." {
    // Use GIT_SHIM_PWD if available
    match @sys.get_env_var("GIT_SHIM_PWD") {
      Some(pwd) => pwd
      None => "."
    }
  } else if root.has_prefix("/") {
    root
  } else {
    // Relative path, try to make it absolute
    match @sys.get_env_var("GIT_SHIM_PWD") {
      Some(pwd) => pwd + "/" + root
      None => root
    }
  }
}

///|
async fn handle_worktree(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    show_worktree_help()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_worktree_list(rest)
    "add" => handle_worktree_add(rest)
    "remove" => handle_worktree_remove(rest)
    "prune" => handle_worktree_prune(rest)
    "lock" => handle_worktree_lock(rest)
    "unlock" => handle_worktree_unlock(rest)
    "move" => handle_worktree_move(rest)
    "repair" => handle_worktree_repair(rest)
    _ => {
      eprint_line("Unknown worktree subcommand: \{subcmd}")
      show_worktree_help()
      @sys.exit(1)
    }
  }
}

///|
async fn show_worktree_help() -> Unit {
  let help =
    #|usage: git worktree <command> [<args>]
    #|
    #|Commands:
    #|   list          List all worktrees
    #|   add           Create a new worktree
    #|   remove        Remove a worktree
    #|   prune         Prune worktree information
    #|   lock          Lock a worktree
    #|   unlock        Unlock a worktree
    #|   move          Move a worktree
    #|   repair        Repair worktree administrative files
    #|
    #|See 'git worktree <command> -h' for more information.
  print_line(help)
}

///|
async fn handle_worktree_list(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut porcelain = false
  let mut nul_terminated = false
  let mut verbose = false
  for arg in args {
    match arg {
      "--porcelain" => porcelain = true
      "-z" => nul_terminated = true
      "--verbose" | "-v" => verbose = true
      _ => ()
    }
  }
  // -z requires --porcelain
  if nul_terminated && not(porcelain) {
    eprint_line("fatal: -z requires --porcelain")
    @sys.exit(1)
  }
  // --verbose and --porcelain are mutually exclusive
  if verbose && porcelain {
    eprint_line("fatal: --verbose and --porcelain are mutually exclusive")
    @sys.exit(1)
  }
  let worktrees = @gitlib.list_worktrees(fs, root)
  if porcelain {
    for wt in worktrees {
      let sep = if nul_terminated { "\u{00}" } else { "\n" }
      let end = if nul_terminated { "\u{00}" } else { "\n" }
      print_str("worktree \{wt.path}\{sep}")
      match wt.head_id {
        Some(id) => print_str("HEAD \{id.to_hex()}\{sep}")
        None => ()
      }
      match wt.branch {
        Some(b) => print_str("branch refs/heads/\{b}\{sep}")
        None => if wt.head_id is Some(_) { print_str("detached\{sep}") }
      }
      if wt.locked {
        // Get lock reason if available
        let reason = @gitlib.get_worktree_lock_reason(fs, root, wt.path)
        match reason {
          Some(r) =>
            if r.length() > 0 {
              // Escape newlines in reason
              let escaped = escape_lock_reason(r)
              print_str("locked \"\{escaped}\"\{sep}")
            } else {
              print_str("locked\{sep}")
            }
          None => print_str("locked\{sep}")
        }
      }
      // Check if prunable
      if not(wt.is_main) {
        let prunable = @gitlib.get_worktree_prunable_reason(fs, root, wt.path)
        match prunable {
          Some(r) => print_str("prunable \{r}\{sep}")
          None => ()
        }
      }
      print_str(end)
    }
  } else if verbose {
    // Verbose format with locked/prunable reasons on separate lines
    for wt in worktrees {
      let commit_str = match wt.head_id {
        Some(id) => (try! id.to_hex()[:7]).to_string()
        None => "0000000"
      }
      let branch_str = match wt.branch {
        Some(b) => "[\{b}]"
        None => "(detached HEAD)"
      }
      let locked_str = if wt.locked { " locked" } else { "" }
      print_line("\{wt.path}  \{commit_str} \{branch_str}\{locked_str}")
      // Print lock reason on next line if locked
      if wt.locked {
        let reason = @gitlib.get_worktree_lock_reason(fs, root, wt.path)
        match reason {
          Some(r) => if r.length() > 0 { print_line("\tlocked: \{r}") }
          None => ()
        }
      }
      // Print prunable reason if applicable
      if not(wt.is_main) {
        let prunable = @gitlib.get_worktree_prunable_reason(fs, root, wt.path)
        match prunable {
          Some(r) => print_line("\tprunable: \{r}")
          None => ()
        }
      }
    }
  } else {
    // Default format: path commit [branch]
    for wt in worktrees {
      let commit_str = match wt.head_id {
        Some(id) => (try! id.to_hex()[:7]).to_string()
        None => "0000000"
      }
      let branch_str = match wt.branch {
        Some(b) => "[\{b}]"
        None => "(detached HEAD)"
      }
      let mut suffix = ""
      if wt.locked {
        suffix = suffix + " locked"
      }
      if not(wt.is_main) {
        let prunable = @gitlib.get_worktree_prunable_reason(fs, root, wt.path)
        if prunable is Some(_) {
          suffix = suffix + " prunable"
        }
      }
      print_line("\{wt.path}  \{commit_str} \{branch_str}\{suffix}")
    }
  }
}

///|
fn escape_lock_reason(reason : String) -> String {
  let sb = StringBuilder::new()
  for c in reason {
    match c {
      '\n' => {
        sb.write_char('\\')
        sb.write_char('n')
      }
      '\r' => {
        sb.write_char('\\')
        sb.write_char('r')
      }
      '\\' => {
        sb.write_char('\\')
        sb.write_char('\\')
      }
      '"' => {
        sb.write_char('\\')
        sb.write_char('"')
      }
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
async fn handle_worktree_add(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  // Parse arguments
  let mut detach = false
  let mut new_branch : String? = None
  let mut path : String? = None
  let mut commit_ish : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--detach" | "-d" => detach = true
      "-b" if i + 1 < args.length() => {
        new_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "-B" if i + 1 < args.length() => {
        // -B: force create branch (we treat same as -b for now)
        new_branch = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-b") => new_branch = Some((try! arg[2:]).to_string())
      _ if arg.has_prefix("-") => () // Ignore unknown flags
      _ =>
        if path is None {
          path = Some(arg)
        } else if commit_ish is None {
          commit_ish = Some(arg)
        }
    }
    i += 1
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree add [<options>] <path> [<commit-ish>]")
    @sys.exit(1)
  }
  @gitlib.create_worktree(
    fs,
    fs,
    root,
    wt_path,
    commit_ish,
    detach~,
    new_branch~,
  )
  // Print success message
  match (new_branch, detach, commit_ish) {
    (Some(b), _, _) => print_line("Preparing worktree (new branch '\{b}')")
    (None, true, _) => print_line("Preparing worktree (detached HEAD)")
    (None, false, Some(spec)) =>
      print_line("Preparing worktree (checking out '\{spec}')")
    (None, false, None) => print_line("Preparing worktree (HEAD)")
  }
  print_line("HEAD is now at \{wt_path}")
}

///|
async fn handle_worktree_remove(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut force = false
  let mut path : String? = None
  for arg in args {
    match arg {
      "--force" | "-f" => force = true
      _ if not(arg.has_prefix("-")) => path = Some(arg)
      _ => ()
    }
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree remove [--force] <worktree>")
    @sys.exit(1)
  }
  @gitlib.remove_worktree(fs, fs, root, wt_path, force~)
  print_line("Removed worktree '\{wt_path}'")
}

///|
async fn handle_worktree_prune(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut dry_run = false
  let mut verbose = false
  for arg in args {
    match arg {
      "--dry-run" | "-n" => dry_run = true
      "--verbose" | "-v" => verbose = true
      _ => ()
    }
  }
  let pruned = @gitlib.prune_worktrees(fs, fs, root, dry_run~)
  if pruned.length() == 0 {
    if verbose {
      print_line("Nothing to prune")
    }
  } else {
    for name in pruned {
      if dry_run {
        print_line("Would remove worktrees/\{name}")
      } else {
        print_line("Removing worktrees/\{name}")
      }
    }
  }
}

///|
async fn handle_worktree_lock(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut path : String? = None
  let mut reason : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--reason" if i + 1 < args.length() => {
        reason = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--reason=") =>
        reason = Some((try! arg[9:]).to_string())
      _ if not(arg.has_prefix("-")) => path = Some(arg)
      _ => ()
    }
    i += 1
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree lock [--reason <string>] <worktree>")
    @sys.exit(1)
  }
  @gitlib.lock_worktree(fs, fs, root, wt_path, reason~)
}

///|
async fn handle_worktree_unlock(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut path : String? = None
  for arg in args {
    if not(arg.has_prefix("-")) {
      path = Some(arg)
    }
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree unlock <worktree>")
    @sys.exit(1)
  }
  @gitlib.unlock_worktree(fs, fs, root, wt_path)
}

///|
async fn handle_worktree_move(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut force = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "--force" | "-f" => force = true
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => ()
    }
  }
  if positional.length() != 2 {
    eprint_line("usage: git worktree move [--force] <worktree> <new-path>")
    @sys.exit(1)
  }
  let source = positional[0]
  let dest = positional[1]
  @gitlib.move_worktree(fs, fs, root, source, dest, force~)
  print_line("Moving '\{source}' to '\{dest}'")
}

///|
async fn handle_worktree_repair(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let paths : Array[String] = []
  for arg in args {
    if not(arg.has_prefix("-")) {
      paths.push(arg)
    }
  }
  let repaired = @gitlib.repair_worktree(fs, fs, root, worktree_paths=paths)
  if repaired.length() == 0 {
    // No output if nothing to repair (like git)
    ()
  } else {
    for item in repaired {
      print_line("repair: \{item}")
    }
  }
}
