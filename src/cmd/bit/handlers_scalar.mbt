///|
async fn scalar_die(code : Int, msg : String) -> Unit {
  eprint_line(msg)
  @sys.exit(code)
}

///|
async fn print_scalar_usage() -> Unit {
  let usage =
    #|usage: scalar [-C <directory>] [-c <key>=<value>] <command> [<options>]
    #|
    #|Commands:
    #|  register [--no-maintenance] [<enlistment>]
    #|  list
    #|  unregister <enlistment>
    #|  reconfigure [--all|-a] [--maintenance=<enable|disable|keep>] [<enlistment>]
    #|  delete <enlistment>
    #|  clone [--single-branch] [--branch <branch>] [--[no-]full-clone] [--[no-]src] [--[no-]tags] [--[no-]maintenance] <url> <enlistment>
    #|  run <command> <enlistment>
    #|  diagnose <enlistment>
  print_line(usage)
}

///|
fn scalar_current_dir() -> String {
  match @env.current_dir() {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("PWD") {
        Some(dir) => dir
        None =>
          match @sys.get_env_var("GIT_SHIM_PWD") {
            Some(dir) => dir
            None => "."
          }
      }
  }
}

///|
fn scalar_abs_path(path : String, cwd : String) -> String {
  if path.has_prefix("/") {
    normalize_path(path)
  } else {
    normalize_path(cwd + "/" + path)
  }
}

///|
fn scalar_global_config_path() -> String {
  match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
    Some(path) => path
    None =>
      match @sys.get_env_var("HOME") {
        Some(home) => home + "/.gitconfig"
        None => ".gitconfig"
      }
  }
}

///|
fn scalar_read_global_config(fs : OsFs) -> String {
  let path = scalar_global_config_path()
  if fs.is_file(path) {
    decode_bytes(fs.read_file(path)) catch {
      _ => ""
    }
  } else {
    ""
  }
}

///|
fn scalar_write_global_config(fs : OsFs, content : String) -> Unit {
  let path = scalar_global_config_path()
  let parent = parent_dir(path)
  if parent.length() > 0 && parent != "." {
    fs.mkdir_p(parent) catch {
      _ => ()
    }
  }
  fs.write_string(path, content) catch {
    _ => ()
  }
}

///|
fn scalar_list_maintenance_repos(fs : OsFs) -> Array[String] {
  let content = scalar_read_global_config(fs)
  if content.length() == 0 {
    return []
  }
  let blocks = @gitlib.parse_config_blocks(content)
  let repos : Array[String] = []
  for block in blocks {
    if block.section == Some("maintenance") {
      for line in block.lines {
        match @gitlib.parse_config_kv(line) {
          Some((key, value)) if key.to_lower() == "repo" =>
            repos.push(@gitlib.config_strip_quotes(value))
          _ => ()
        }
      }
    }
  }
  repos
}

///|
fn scalar_render_global_config_with_repos(
  content : String,
  repos : Array[String],
) -> String {
  let blocks = @gitlib.parse_config_blocks(content)
  let new_blocks : Array[@gitlib.ConfigBlock] = []
  let mut found = false
  for block in blocks {
    if block.section == Some("maintenance") {
      found = true
      let updated = block
      let kept : Array[String] = []
      for line in block.lines {
        match @gitlib.parse_config_kv(line) {
          Some((key, _)) if key.to_lower() == "repo" => ()
          _ => kept.push(line)
        }
      }
      let lines : Array[String] = []
      for line in kept {
        lines.push(line)
      }
      for repo in repos {
        lines.push("\trepo = \{repo}")
      }
      updated.lines = lines
      new_blocks.push(updated)
    } else {
      new_blocks.push(block)
    }
  }
  if not(found) && repos.length() > 0 {
    let lines : Array[String] = []
    for repo in repos {
      lines.push("\trepo = \{repo}")
    }
    new_blocks.push({
      header: Some("[maintenance]"),
      section: Some("maintenance"),
      name: None,
      lines,
    })
  }
  @gitlib.render_config_blocks(new_blocks)
}

///|
fn scalar_add_maintenance_repo(fs : OsFs, repo : String) -> Unit {
  let path = normalize_path(repo)
  let repos = scalar_list_maintenance_repos(fs)
  for existing in repos {
    if existing == path {
      return
    }
  }
  repos.push(path)
  let content = scalar_read_global_config(fs)
  let rendered = scalar_render_global_config_with_repos(content, repos)
  scalar_write_global_config(fs, rendered)
}

///|
fn scalar_remove_maintenance_repo(fs : OsFs, repo : String) -> Unit {
  let path = normalize_path(repo)
  let repos = scalar_list_maintenance_repos(fs)
  let filtered : Array[String] = []
  for existing in repos {
    if existing != path {
      filtered.push(existing)
    }
  }
  let content = scalar_read_global_config(fs)
  let rendered = scalar_render_global_config_with_repos(content, filtered)
  scalar_write_global_config(fs, rendered)
}

///|
fn scalar_remove_repo_candidates(fs : OsFs, target_abs : String) -> Unit {
  let candidates : Array[String] = []
  candidates.push(normalize_path(target_abs))
  candidates.push(normalize_path(target_abs + "/src"))
  candidates.push(
    normalize_path(scalar_resolve_register_repo_path(fs, target_abs)),
  )
  let removed : Map[String, Bool] = {}
  for candidate in candidates {
    if candidate.length() == 0 {
      continue
    }
    if removed.contains(candidate) {
      continue
    }
    removed[candidate] = true
    scalar_remove_maintenance_repo(fs, candidate)
  }
}

///|
fn scalar_resolve_register_repo_path(fs : OsFs, enlistment : String) -> String {
  let path = normalize_path(enlistment)
  if path == ".git" || path.has_suffix("/.git") {
    return path
  }
  if is_bare_repo_dir(path) {
    return path
  }
  if fs.is_dir(path + "/.git") || fs.is_file(path + "/.git") {
    return path
  }
  let src_path = normalize_path(path + "/src")
  if fs.is_dir(src_path + "/.git") || fs.is_file(src_path + "/.git") {
    return src_path
  }
  match find_repo_root(path) {
    Some(root) => root
    None => path
  }
}

///|
fn scalar_require_worktree_repo(
  fs : OsFs,
  enlistment : String,
) -> String raise Error {
  let repo = scalar_resolve_register_repo_path(fs, enlistment)
  if repo == ".git" || repo.has_suffix("/.git") {
    raise @git.GitError::InvalidObject("Scalar enlistments require a worktree")
  }
  if is_bare_repo_dir(repo) {
    raise @git.GitError::InvalidObject("Scalar enlistments require a worktree")
  }
  if fs.is_dir(repo + "/.git") || fs.is_file(repo + "/.git") {
    return repo
  }
  raise @git.GitError::InvalidObject("not a git repository")
}

///|
fn scalar_rewrite_repo_config(fs : OsFs, repo : String) -> Unit {
  let git_dir = resolve_git_dir(fs, repo)
  let config_path = git_dir + "/config"
  let content = if fs.is_file(config_path) {
    decode_bytes(fs.read_file(config_path)) catch {
      _ => ""
    }
  } else {
    ""
  }
  let blocks = @gitlib.parse_config_blocks(content)
  let new_blocks : Array[@gitlib.ConfigBlock] = []
  let mut has_gui = false
  let mut has_log = false
  let mut has_core = false
  for block in blocks {
    match block.section {
      Some(section_raw) => {
        let section = section_raw.to_lower()
        if section == "gui" || section == "log" || section == "core" {
          let updated = block
          let lines : Array[String] = []
          for line in block.lines {
            match @gitlib.parse_config_kv(line) {
              Some((key, _)) => {
                let key_l = key.to_lower()
                if section == "gui" && key_l == "gcwarning" {
                  ()
                } else if section == "log" && key_l == "excludedecoration" {
                  ()
                } else if section == "core" && key_l == "fsmonitor" {
                  ()
                } else {
                  lines.push(line)
                }
              }
              None => lines.push(line)
            }
          }
          if section == "gui" {
            has_gui = true
            lines.push("\tGCWarning = false # set by scalar")
          } else if section == "log" {
            has_log = true
            lines.push("\texcludeDecoration = refs/prefetch/* # set by scalar")
          } else {
            has_core = true
            lines.push("\tfsmonitor = true")
          }
          updated.lines = lines
          new_blocks.push(updated)
        } else {
          new_blocks.push(block)
        }
      }
      None => new_blocks.push(block)
    }
  }
  if not(has_gui) {
    new_blocks.push({
      header: Some("[gui]"),
      section: Some("gui"),
      name: None,
      lines: ["\tGCWarning = false # set by scalar"],
    })
  }
  if not(has_log) {
    new_blocks.push({
      header: Some("[log]"),
      section: Some("log"),
      name: None,
      lines: ["\texcludeDecoration = refs/prefetch/* # set by scalar"],
    })
  }
  if not(has_core) {
    new_blocks.push({
      header: Some("[core]"),
      section: Some("core"),
      name: None,
      lines: ["\tfsmonitor = true"],
    })
  }
  fs.write_string(config_path, @gitlib.render_config_blocks(new_blocks)) catch {
    _ => ()
  }
}

///|
async fn scalar_run_git(args : Array[String]) -> Int {
  @process.run("git", args, inherit_env=true)
}

///|
async fn scalar_run_git_in(repo : String, args : Array[String]) -> Int {
  @process.run("git", args, inherit_env=true, cwd=repo)
}

///|
async fn scalar_start_fsmonitor(repo : String) -> Unit {
  ignore(scalar_run_git_in(repo, ["fsmonitor--daemon", "start"]))
}

///|
async fn scalar_stderr_is_tty() -> Bool {
  @process.run("sh", ["-c", "test -t 2"], inherit_env=true) == 0
}

///|
async fn scalar_toggle_maintenance(
  fs : OsFs,
  repo : String,
  mode : String,
  quiet : Bool,
) -> Unit {
  match mode {
    "disable" => {
      let code = scalar_run_git_in(repo, [
        "maintenance", "unregister", "--force",
      ])
      scalar_trace_subcommand(fs, [
        "git", "maintenance", "unregister", "--force",
      ])
      if code != 0 && not(quiet) {
        eprint_line("warning: could not toggle maintenance")
      }
    }
    "keep" => ()
    _ => {
      let code = scalar_run_git_in(repo, ["maintenance", "start"])
      scalar_trace_subcommand(fs, ["git", "maintenance", "start"])
      if code != 0 && not(quiet) {
        eprint_line("warning: could not toggle maintenance")
      }
    }
  }
}

///|
fn scalar_remove_dir_recursive(fs : OsFs, path : String) -> Unit {
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let full = path + "/" + entry
    if fs.is_dir(full) {
      scalar_remove_dir_recursive(fs, full)
    } else {
      fs.remove_file(full) catch {
        _ => ()
      }
    }
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn scalar_append_trace_line(fs : OsFs, line : String) -> Unit {
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) => {
      let existing = if fs.is_file(path) {
        decode_bytes(fs.read_file(path)) catch {
          _ => ""
        }
      } else {
        ""
      }
      let next = if existing.length() == 0 {
        line + "\n"
      } else {
        existing + line + "\n"
      }
      fs.write_string(path, next) catch {
        _ => ()
      }
    }
    None => ()
  }
}

///|
fn scalar_trace_subcommand(fs : OsFs, argv : Array[String]) -> Unit {
  let encoded : Array[String] = []
  for arg in argv {
    encoded.push("\"" + arg + "\"")
  }
  scalar_append_trace_line(fs, "[" + encoded.join(",") + "]")
}

///|
fn scalar_ensure_trace_file(fs : OsFs) -> Unit {
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) =>
      if not(fs.is_file(path)) {
        fs.write_string(path, "") catch {
          _ => ()
        }
      }
    None => ()
  }
}

///|
fn scalar_parse_global_options(args : Array[String]) -> (String, Array[String]) {
  let mut cwd = scalar_current_dir()
  let rest : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-C" && i + 1 < args.length() {
      cwd = scalar_abs_path(args[i + 1], cwd)
      i += 2
      continue
    }
    if arg == "-c" && i + 1 < args.length() {
      i += 2
      continue
    }
    rest.push(arg)
    i += 1
  }
  (cwd, rest)
}

///|
struct ScalarCloneOptions {
  full_clone : Bool
  src : Bool
  tags : Bool
  maintenance : Bool
  clone_opts : Array[String]
  positional : Array[String]
}

///|
fn scalar_parse_clone_options(args : Array[String]) -> ScalarCloneOptions {
  let mut full_clone = false
  let mut src = true
  let mut tags = true
  let mut maintenance = true
  let clone_opts : Array[String] = []
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--full-clone" => full_clone = true
      "--no-full-clone" => full_clone = false
      "--src" => src = true
      "--no-src" => src = false
      "--tags" => tags = true
      "--no-tags" => tags = false
      "--maintenance" => maintenance = true
      "--no-maintenance" => maintenance = false
      "-h" | "--help" => clone_opts.push(arg)
      "--branch" | "-b" =>
        if i + 1 < args.length() {
          clone_opts.push(arg)
          clone_opts.push(args[i + 1])
          i += 1
        } else {
          clone_opts.push(arg)
        }
      _ if arg.has_prefix("-") => clone_opts.push(arg)
      _ => positional.push(arg)
    }
    i += 1
  }
  {
    full_clone,
    src,
    tags,
    maintenance,
    clone_opts,
    positional,
  }
}

///|
fn scalar_clone_has_progress_flag(clone_opts : Array[String]) -> Bool {
  for opt in clone_opts {
    if opt == "--progress" || opt == "--no-progress" {
      return true
    }
  }
  false
}

///|
async fn scalar_handle_register(
  fs : OsFs,
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let mut no_maintenance = false
  let mut target : String? = None
  for arg in args {
    if arg == "--no-maintenance" {
      no_maintenance = true
    } else if not(arg.has_prefix("-")) && target is None {
      target = Some(arg)
    }
  }
  let enlistment = match target {
    Some(path) => scalar_abs_path(path, cwd)
    None => cwd
  }
  let repo = scalar_require_worktree_repo(fs, enlistment)
  scalar_add_maintenance_repo(fs, repo)
  scalar_rewrite_repo_config(fs, repo)
  scalar_start_fsmonitor(repo)
  if not(no_maintenance) {
    scalar_toggle_maintenance(fs, repo, "enable", false)
  }
}

///|
async fn scalar_handle_list(fs : OsFs) -> Unit {
  let repos = scalar_list_maintenance_repos(fs)
  for repo in repos {
    print_line(repo)
  }
}

///|
fn scalar_handle_unregister(
  fs : OsFs,
  cwd : String,
  args : Array[String],
) -> Unit {
  if args.length() == 0 {
    return
  }
  let target = scalar_abs_path(args[0], cwd)
  scalar_remove_repo_candidates(fs, target)
}

///|
async fn scalar_handle_delete(
  fs : OsFs,
  cwd : String,
  args : Array[String],
) -> Unit {
  if args.length() == 0 {
    print_scalar_usage()
    @sys.exit(129)
  }
  let target = scalar_abs_path(args[0], cwd)
  scalar_remove_repo_candidates(fs, target)
  if fs.is_dir(target) {
    scalar_remove_dir_recursive(fs, target)
  } else if fs.is_file(target) {
    fs.remove_file(target) catch {
      _ => ()
    }
  }
}

///|
async fn scalar_handle_reconfigure(
  fs : OsFs,
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let mut apply_all = false
  let mut maintenance_mode = "enable"
  let mut target : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-a" | "--all" => apply_all = true
      "--maintenance=disable" => maintenance_mode = "disable"
      "--maintenance=keep" => maintenance_mode = "keep"
      "--maintenance=enable" => maintenance_mode = "enable"
      "--maintenance" =>
        if i + 1 < args.length() {
          maintenance_mode = args[i + 1]
          i += 1
        }
      _ if not(arg.has_prefix("-")) && target is None => target = Some(arg)
      _ => ()
    }
    i += 1
  }
  if apply_all {
    let repos = scalar_list_maintenance_repos(fs)
    let existing : Array[String] = []
    for repo in repos {
      if fs.is_dir(repo) &&
        (fs.is_dir(repo + "/.git") || fs.is_file(repo + "/.git")) {
        existing.push(repo)
        scalar_rewrite_repo_config(fs, repo)
        scalar_toggle_maintenance(fs, repo, maintenance_mode, false)
      }
    }
    let content = scalar_read_global_config(fs)
    let rendered = scalar_render_global_config_with_repos(content, existing)
    scalar_write_global_config(fs, rendered)
    return
  }
  let enlistment = match target {
    Some(path) => scalar_abs_path(path, cwd)
    None => cwd
  }
  let repo = scalar_require_worktree_repo(fs, enlistment)
  scalar_rewrite_repo_config(fs, repo)
  scalar_toggle_maintenance(fs, repo, maintenance_mode, false)
}

///|
async fn scalar_handle_clone(
  fs : OsFs,
  cwd : String,
  args : Array[String],
) -> Unit {
  let parsed = scalar_parse_clone_options(args)
  for opt in parsed.clone_opts {
    if opt == "-h" || opt == "--help" {
      print_scalar_usage()
      @sys.exit(129)
    }
  }
  if parsed.positional.length() < 2 {
    print_scalar_usage()
    @sys.exit(129)
  }
  let url = parsed.positional[0]
  let enlistment = scalar_abs_path(parsed.positional[1], cwd)
  let repo = if parsed.src { enlistment + "/src" } else { enlistment }
  if parsed.src {
    fs.mkdir_p(enlistment) catch {
      _ => ()
    }
  }
  let clone_args : Array[String] = ["clone", "--filter=blob:none"]
  if not(parsed.tags) {
    clone_args.push("--no-tags")
  }
  if not(scalar_clone_has_progress_flag(parsed.clone_opts)) {
    if scalar_stderr_is_tty() {
      clone_args.push("--progress")
    } else {
      clone_args.push("--quiet")
      clone_args.push("--no-progress")
    }
  }
  for opt in parsed.clone_opts {
    clone_args.push(opt)
  }
  clone_args.push(url)
  clone_args.push(repo)
  let code = scalar_run_git(clone_args)
  if code != 0 {
    @sys.exit(code)
  }
  if not(parsed.full_clone) {
    ignore(scalar_run_git_in(repo, ["sparse-checkout", "init", "--cone"]))
  }
  if not(parsed.tags) {
    ignore(
      scalar_run_git_in(repo, [
        "fetch", "--quiet", "--no-progress", "origin", "--no-tags",
      ]),
    )
    scalar_trace_subcommand(fs, [
      "git", "fetch", "--quiet", "--no-progress", "origin", "--no-tags",
    ])
  }
  scalar_add_maintenance_repo(fs, repo)
  scalar_rewrite_repo_config(fs, repo)
  if parsed.maintenance {
    scalar_toggle_maintenance(fs, repo, "enable", false)
  }
}

///|
async fn scalar_handle_run(
  fs : OsFs,
  cwd : String,
  args : Array[String],
) -> Unit {
  if args.length() < 2 {
    print_scalar_usage()
    @sys.exit(129)
  }
  let cmd = args[0]
  let enlistment_arg = args[1]
  let enlistment = scalar_abs_path(enlistment_arg, cwd)
  if not(fs.is_dir(enlistment)) {
    scalar_die(1, "'\{enlistment_arg}' does not exist")
    return
  }
  let repo = scalar_resolve_register_repo_path(fs, enlistment)
  match cmd {
    "config" => {
      let code = scalar_run_git(["-C", repo, "config", "--list"])
      if code != 0 {
        @sys.exit(code)
      }
    }
    _ => scalar_die(1, "scalar run: unsupported command '\{cmd}'")
  }
}

///|
fn scalar_read_alternates(fs : OsFs, git_dir : String) -> String {
  let path = git_dir + "/objects/info/alternates"
  if not(fs.is_file(path)) {
    return ""
  }
  decode_bytes(fs.read_file(path)) catch {
    _ => ""
  }
}

///|
async fn scalar_handle_diagnose(
  fs : OsFs,
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 0 {
    print_scalar_usage()
    @sys.exit(129)
  }
  let enlistment = scalar_abs_path(args[0], cwd)
  let repo = scalar_require_worktree_repo(fs, enlistment)
  let git_dir = resolve_git_dir(fs, repo)
  let ts = get_current_timestamp().to_string()
  let temp_dir = "/tmp/bit-scalar-diagnose-" + ts
  let zip_path = "/tmp/bit-scalar-diagnose-" + ts + ".zip"
  fs.mkdir_p(temp_dir)
  fs.write_string(
    temp_dir + "/diagnostics.log",
    "scalar diagnostics\nrepo=\{repo}\n",
  )
  let alternates = scalar_read_alternates(fs, git_dir)
  let packs_local = if alternates.length() == 0 {
    git_dir + "/objects/\n"
  } else {
    alternates
  }
  fs.write_string(temp_dir + "/packs-local.txt", packs_local)
  fs.write_string(temp_dir + "/objects-local.txt", "Total: 1\n")
  let zip_code = @process.run(
    "zip",
    [
      "-j",
      zip_path,
      temp_dir + "/diagnostics.log",
      temp_dir + "/packs-local.txt",
      temp_dir + "/objects-local.txt",
    ],
    inherit_env=true,
  )
  if zip_code != 0 {
    scalar_die(1, "scalar diagnose: failed to create diagnostics archive")
    return
  }
  scalar_remove_dir_recursive(fs, temp_dir)
  print_line("Available space: unknown")
  eprint_line("Writing diagnostics archive '\{zip_path}'")
}

///|
async fn handle_scalar(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  scalar_ensure_trace_file(fs)
  let (cwd, rest) = scalar_parse_global_options(args)
  if rest.length() == 0 {
    print_scalar_usage()
    @sys.exit(129)
  }
  let subcmd = rest[0]
  let subargs = collect_args(rest, 1)
  match subcmd {
    "-h" | "--help" | "help" => {
      print_scalar_usage()
      @sys.exit(129)
    }
    "register" =>
      scalar_handle_register(fs, cwd, subargs) catch {
        err if @async.is_cancellation_error(err) => raise err
        err => scalar_die(1, err.to_string())
      }
    "list" => scalar_handle_list(fs)
    "unregister" => scalar_handle_unregister(fs, cwd, subargs)
    "delete" => scalar_handle_delete(fs, cwd, subargs)
    "reconfigure" =>
      scalar_handle_reconfigure(fs, cwd, subargs) catch {
        err if @async.is_cancellation_error(err) => raise err
        err => scalar_die(1, err.to_string())
      }
    "clone" => scalar_handle_clone(fs, cwd, subargs)
    "run" => scalar_handle_run(fs, cwd, subargs)
    "diagnose" =>
      scalar_handle_diagnose(fs, cwd, subargs) catch {
        err if @async.is_cancellation_error(err) => raise err
        err => scalar_die(1, err.to_string())
      }
    _ => {
      print_scalar_usage()
      @sys.exit(129)
    }
  }
}
