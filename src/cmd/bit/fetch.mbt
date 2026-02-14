///|
fn resolve_real_git_for_fetch() -> String {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) if path.length() > 0 => path
    _ =>
      match @sys.get_env_var("GIT_SHIM_REAL_GIT") {
        Some(path) if path.length() > 0 => path
        _ => "git"
      }
  }
}

///|
fn is_real_git_delegate_enabled() -> Bool {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) if path.length() > 0 => true
    _ =>
      match @sys.get_env_var("GIT_SHIM_REAL_GIT") {
        Some(path) => path.length() > 0
        None => false
      }
  }
}

///|
fn real_git_delegate_is_available(fs : &@git.RepoFileSystem) -> Bool {
  guard is_real_git_delegate_enabled() else { return false }
  let real_git = resolve_real_git_for_fetch()
  if real_git.length() == 0 {
    return false
  }
  if real_git.has_prefix("/") {
    return fs.is_file(real_git)
  }
  true
}

///|
fn collect_global_config_overrides_for_delegate() -> Array[String] {
  let overrides : Array[String] = []
  match @sys.get_env_var("GIT_CONFIG_OVERRIDES") {
    Some(encoded) =>
      for line_view in encoded.split("\n") {
        let line = line_view.to_string()
        if line.length() == 0 {
          continue
        }
        overrides.push("-c")
        overrides.push(line)
      }
    None => ()
  }
  overrides
}

///|
fn collect_global_path_overrides_for_delegate() -> Array[String] {
  let overrides : Array[String] = []
  let delegate_cwd = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) if dir.length() > 0 => Some(dir)
    _ =>
      match @sys.get_env_var("GIT_SHIM_PWD") {
        Some(dir) if dir.length() > 0 => Some(dir)
        _ => None
      }
  }
  match delegate_cwd {
    Some(dir) => {
      overrides.push("-C")
      overrides.push(dir)
    }
    None => ()
  }
  let explicit_git_dir = match @sys.get_env_var("GIT_SHIM_EXPLICIT_GIT_DIR") {
    Some(value) => value == "1"
    None => false
  }
  if explicit_git_dir {
    match @sys.get_env_var("GIT_DIR") {
      Some(dir) if dir.length() > 0 => overrides.push("--git-dir=" + dir)
      _ => ()
    }
  }
  overrides
}

///|
async fn delegate_to_real_git(
  subcmd : String,
  args : Array[String],
) -> Unit raise Error {
  let real_git = resolve_real_git_for_fetch()
  let delegated_args : Array[String] = []
  delegated_args.append(collect_global_path_overrides_for_delegate())
  delegated_args.append(collect_global_config_overrides_for_delegate())
  delegated_args.push(subcmd)
  delegated_args.append(args)
  let code = @process.run(real_git, delegated_args, inherit_env=true) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => 1
  }
  @sys.exit(code)
}

///|
async fn handle_fetch(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  if real_git_delegate_is_available(rfs) {
    delegate_to_real_git("fetch", args)
    return ()
  }
  let root = get_work_root()
  let git_dir = resolve_git_dir(rfs, root)
  let (remotes, branches) = @gitlib.read_repo_config(fs, git_dir)
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_name = "origin"
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  match @gitlib.read_head_ref(fs, git_dir) {
    @gitlib.HeadRef::Branch(branch_name) =>
      match branches.get(branch_name) {
        Some(branch_config) =>
          match branch_config.remote {
            Some(config_remote) if config_remote.length() > 0 => {
              remote_name = config_remote
              match remotes.get(config_remote) {
                Some(remote_config) =>
                  if remote_config.urls.length() > 0 {
                    remote_url = Some(remote_config.urls[0])
                  }
                None => ()
              }
            }
            _ => ()
          }
        None => ()
      }
    @gitlib.HeadRef::Detached(_) => ()
  }
  let mut explicit_filter_flag = false
  let mut explicit_no_filter = false
  let mut filter = @protocol.FilterSpec::NoFilter
  let mut refetch = false
  let mut update_head_ok = false
  let mut quiet = false
  let positional_args : Array[String] = []
  // Override with command line argument
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--filter" && i + 1 < args.length() {
      explicit_filter_flag = true
      filter = parse_filter_spec(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--filter=") {
      explicit_filter_flag = true
      let filter_spec = String::unsafe_substring(arg, start=9, end=arg.length())
      filter = parse_filter_spec(filter_spec)
      i += 1
      continue
    }
    if arg == "--no-filter" {
      explicit_filter_flag = true
      explicit_no_filter = true
      filter = @protocol.FilterSpec::NoFilter
      i += 1
      continue
    }
    if arg == "--refetch" {
      refetch = true
      i += 1
      continue
    }
    if arg == "--no-ipv4" || arg == "--no-ipv6" {
      raise @git.GitError::InvalidObject(
        "unknown option '" + option_name_without_prefix(arg) + "'",
      )
    }
    if not(arg.has_prefix("-")) {
      positional_args.push(arg)
      i += 1
      continue
    }
    if arg == "-u" || arg == "--update-head-ok" {
      update_head_ok = true
      i += 1
      continue
    }
    if arg == "-q" || arg == "--quiet" {
      quiet = true
      i += 1
      continue
    }
    if arg == "--prune" ||
      arg == "-p" ||
      arg == "--prune-tags" ||
      arg == "--tags" ||
      arg == "--no-tags" {
      i += 1
      continue
    }
    warn_unimplemented_arg("fetch", arg)
    i += 1
  }
  let explicit_refspecs : Array[String] = []
  let mut legacy_fetch_target : String? = None
  if positional_args.length() > 0 {
    let first = positional_args[0]
    match remotes.get(first) {
      Some(rc) => {
        remote_name = first
        if rc.urls.length() > 0 {
          remote_url = Some(rc.urls[0])
        }
      }
      None =>
        match parse_legacy_branches_entry(fs, git_dir, first) {
          Some((legacy_url, legacy_branch)) => {
            remote_name = first
            remote_url = Some(legacy_url)
            let branch = match legacy_branch {
              Some(name) => name
              None => legacy_default_branch_name()
            }
            legacy_fetch_target = Some(branch)
          }
          None => remote_url = Some(first)
        }
    }
    let mut i = 1
    while i < positional_args.length() {
      let token = positional_args[i]
      if token == "tag" {
        if i + 1 >= positional_args.length() {
          raise @git.GitError::InvalidObject("fetch tag requires tag name")
        }
        let tag_name = positional_args[i + 1]
        if tag_name.length() == 0 {
          raise @git.GitError::InvalidObject("fetch tag requires tag name")
        }
        let tag_ref = "refs/tags/" + tag_name
        explicit_refspecs.push(tag_ref + ":" + tag_ref)
        i += 2
        continue
      }
      explicit_refspecs.push(token)
      i += 1
    }
  }
  if explicit_refspecs.length() == 0 && legacy_fetch_target is Some(branch) {
    explicit_refspecs.push(
      "refs/heads/" + branch + ":refs/heads/" + remote_name,
    )
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let rewrite_rules = read_url_rewrite_rules(fs, git_dir)
  let resolved_url = rewrite_url_by_rules(url, rewrite_rules, false)
  let mut is_partial_clone = false
  let mut inherited_filter = @protocol.FilterSpec::NoFilter
  match remotes.get(remote_name) {
    Some(rc) => {
      if rc.promisor || rc.partial_clone_filter is Some(_) {
        is_partial_clone = true
      }
      if rc.partial_clone_filter is Some(raw_filter) {
        inherited_filter = parse_filter_spec(raw_filter)
      }
    }
    None => ()
  }
  if explicit_no_filter {
    filter = @protocol.FilterSpec::NoFilter
  } else if not(explicit_filter_flag) && inherited_filter.is_partial() {
    filter = inherited_filter
  }
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  let local_promisor_remote = match
    @gitlib.resolve_local_repo_path(fs, local_root, resolved_url) {
    Some(src_path) => has_promisor_source_repo(fs, src_path)
    None => false
  }
  let mut has_oid_refspec = false
  for spec in explicit_refspecs {
    let raw = if spec.has_prefix("+") {
      String::unsafe_substring(spec, start=1, end=spec.length())
    } else {
      spec
    }
    if looks_like_object_id(raw) {
      has_oid_refspec = true
      break
    }
  }
  let force_transport = (
      filter.is_partial() ||
      refetch ||
      local_promisor_remote ||
      is_partial_clone
    ) &&
    not(has_oid_refspec)
  fetch_from_remote(
    fs,
    git_dir,
    root,
    remote_name,
    resolved_url,
    explicit_refspecs,
    filter~,
    force_transport~,
    update_head_ok~,
    quiet~,
  )
}

///|
fn find_submodule_replaced_with_non_submodule(
  from_modes : Map[String, Int],
  to_modes : Map[String, Int],
) -> String? {
  for path, mode in from_modes {
    if mode != 0o160000 {
      continue
    }
    match to_modes.get(path) {
      Some(next_mode) => if next_mode != 0o160000 { return Some(path) }
      None => ()
    }
  }
  None
}

///|
fn resolve_initial_pull_head_target(branch_name : String?) -> String {
  match branch_name {
    Some(branch) => "refs/heads/" + branch
    None => "HEAD"
  }
}

///|
fn collect_commit_tree_modes(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> Map[String, Int] raise @git.GitError {
  let files = @gitlib.collect_tree_files_from_commit(db, fs, commit_id)
  let modes : Map[String, Int] = {}
  for path, entry in files {
    modes[path] = entry.mode
  }
  modes
}

///|
