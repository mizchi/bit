///|
async fn handle_clone(args : Array[String]) -> Unit raise Error {
  let fallback_root = get_work_root()
  let command_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None =>
      match @env.current_dir() {
        Some(dir) => dir
        None => fallback_root
      }
  }
  let positional : Array[String] = []
  let mut url : String? = None
  let mut dest : String? = None
  let mut separate_git_dir_raw : String? = None
  let reference_paths_raw : Array[String] = []
  let mut depth = 0
  let mut filter = @protocol.FilterSpec::NoFilter
  let mut has_filter_flag = false
  let mut recursive = false
  let mut bare = false
  let mut mirror = false
  let mut no_checkout = false
  let mut remote_name = "origin"
  let mut ref_spec : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--depth" && i + 1 < args.length() {
      // Parse depth value
      let depth_str = args[i + 1]
      depth = @strconv.parse_int(depth_str) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          0
        }
      }
      i += 2
      continue
    }
    if arg.has_prefix("--depth=") {
      let depth_str = String::unsafe_substring(arg, start=8, end=arg.length())
      depth = @strconv.parse_int(depth_str) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          0
        }
      }
      i += 1
      continue
    }
    if arg == "--bare" {
      bare = true
      i += 1
      continue
    }
    if arg == "--mirror" {
      mirror = true
      bare = true
      i += 1
      continue
    }
    if arg == "-n" || arg == "--no-checkout" {
      no_checkout = true
      i += 1
      continue
    }
    if (arg == "-b" || arg == "--branch") && i + 1 < args.length() {
      ref_spec = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--branch=") {
      ref_spec = Some(
        String::unsafe_substring(arg, start=9, end=arg.length()),
      )
      i += 1
      continue
    }
    if arg == "--single-branch" || arg == "--no-single-branch" {
      i += 1
      continue
    }
    if (arg == "-o" || arg == "--origin") && i + 1 < args.length() {
      remote_name = args[i + 1]
      i += 2
      continue
    }
    if arg.has_prefix("--origin=") {
      remote_name = String::unsafe_substring(arg, start=9, end=arg.length())
      i += 1
      continue
    }
    if arg == "--separate-git-dir" && i + 1 < args.length() {
      separate_git_dir_raw = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--separate-git-dir=") {
      let dir = String::unsafe_substring(
        arg,
        start=19,
        end=arg.length(),
      )
      separate_git_dir_raw = Some(dir)
      i += 1
      continue
    }
    if arg == "--reference" && i + 1 < args.length() {
      reference_paths_raw.push(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--reference=") {
      let ref_path = String::unsafe_substring(
        arg,
        start=12,
        end=arg.length(),
      )
      reference_paths_raw.push(ref_path)
      i += 1
      continue
    }
    if arg == "--recursive" {
      recursive = true
      i += 1
      continue
    }
    // Parse --filter option
    if arg == "--filter" && i + 1 < args.length() {
      has_filter_flag = true
      filter = parse_filter_spec(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--filter=") {
      has_filter_flag = true
      let filter_str = String::unsafe_substring(arg, start=9, end=arg.length())
      filter = parse_filter_spec(filter_str)
      i += 1
      continue
    }
    if arg.has_prefix("-") {
      warn_unimplemented_arg("clone", arg)
      i += 1
      continue
    }
    positional.push(arg)
    i += 1
  }
  if positional.length() > 2 {
    raise @git.GitError::InvalidObject("too many arguments")
  }
  if positional.length() > 0 {
    url = Some(positional[0])
  }
  if positional.length() > 1 {
    dest = Some(positional[1])
  }
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  ignore(has_filter_flag)
  ignore(mirror)
  if recursive {
    @stdio.stderr.write("fatal: --recursive is not supported yet\n")
    @sys.exit(1)
  }
  let fs = OsFs::new()
  let local_src_path = @gitlib.resolve_local_repo_path(fs, command_root, remote_url)
  // Check for ambiguity with local directories only when path is not local.
  if local_src_path is None {
    match check_shorthand_ambiguity(remote_url, p => fs.is_dir(p)) {
      Some(conflict_path) =>
        raise @git.GitError::InvalidObject(
          "Ambiguous: '\{conflict_path}' exists locally. Use full URL or ./\{remote_url} for local path.",
        )
      None => ()
    }
  }
  // Check for shorthand (user/repo, user/repo:path, or browser URL)
  match parse_github_shorthand(remote_url) {
    Some(Repo(github_url, refname)) => {
      // user/repo → normal clone from GitHub
      print_line("Shorthand: \{github_url}")
      url = Some(github_url)
      ref_spec = refname
    }
    Some(Subdir(github_url, subdir, refname)) => {
      // user/repo:path or /tree/ URL → subdir clone
      print_line("Subdir clone: \{github_url} → \{subdir}")
      return subdir_clone(github_url, subdir, dest, refname)
    }
    Some(File(raw_url, filename)) => {
      // /blob/ URL → single file fetch
      let target_file = match dest {
        Some(d) => d
        None => filename
      }
      print_line("Fetching file: \{raw_url}")
      return fetch_raw_file(raw_url, target_file)
    }
    None => ()
  }
  // Re-extract remote_url after potential shorthand expansion
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Derive destination from URL if not specified
  let relative_target = trim_trailing_slashes(match dest {
    Some(d) => d
    None => {
      let source_name = if remote_url.has_suffix(".git") {
        String::unsafe_substring(
          remote_url,
          start=0,
          end=remote_url.length() - 4,
        )
      } else {
        remote_url
      }
      let base = match source_name.rev_find("/") {
        Some(i) =>
          String::unsafe_substring(
            source_name,
            start=i + 1,
            end=source_name.length(),
          )
        None => source_name
      }
      if bare {
        if base.has_suffix(".git") { base } else { base + ".git" }
      } else {
        base
      }
    }
  })
  let target = absolutize_clone_path(command_root, relative_target)
  let mut separate_git_dir = match separate_git_dir_raw {
    Some(dir) =>
      Some(absolutize_clone_path(command_root, trim_trailing_slashes(dir)))
    None => None
  }
  if bare && separate_git_dir is Some(_) {
    raise @git.GitError::InvalidObject(
      "--separate-git-dir does not work with --bare",
    )
  }
  let mut clone_root = target
  let mut use_env_work_tree = false
  if not(bare) {
    match @sys.get_env_var("GIT_WORK_TREE") {
      Some(work_tree) => {
        clone_root = absolutize_clone_path(
          command_root,
          trim_trailing_slashes(work_tree),
        )
        use_env_work_tree = true
        if separate_git_dir is None {
          separate_git_dir = Some(target)
        }
      }
      None => ()
    }
  }
  if bare {
    print_line("Cloning into bare repository '\{relative_target}'...")
  } else {
    print_line("Cloning into '\{relative_target}'...")
  }
  let fs = OsFs::new()
  if use_env_work_tree {
    if fs.is_dir(clone_root) || fs.is_file(clone_root) {
      raise @git.GitError::InvalidObject(
        "working tree already exists: \{clone_root}",
      )
    }
  } else {
    ensure_clone_path_available(fs, clone_root)
  }
  match separate_git_dir {
    Some(path) => ensure_clone_path_available(fs, path)
    None => ()
  }
  let reference_object_dirs : Array[String] = []
  for ref_path in reference_paths_raw {
    let abs_ref_path = absolutize_clone_path(
      command_root,
      trim_trailing_slashes(ref_path),
    )
    match @gitlib.detect_git_dir(fs, abs_ref_path) {
      Some((git_dir, _)) => reference_object_dirs.push(git_dir + "/objects")
      None => ()
    }
  }
  let clone_git_dir = match separate_git_dir {
    Some(path) => path
    None => clone_root + "/.git"
  }
  match local_src_path {
    Some(src_path) => {
      if has_promisor_source_repo(fs, src_path) {
        ()
      }
      let remote_display = if remote_url.has_prefix("file://") {
        remote_url
      } else if remote_url.has_prefix("/") {
        remote_url
      } else {
        normalize_path(command_root + "/" + remote_url)
      }
      let use_transport_clone = (filter.is_partial() || depth > 0) &&
        separate_git_dir is None &&
        remote_name == "origin"
      if use_transport_clone {
        let refs = @gitionative.clone_http_to_fs(
          remote_display,
          true,
          fs,
          clone_root,
          depth~,
          filter~,
          no_checkout~,
        )
        if refs.length() == 0 {
          raise @git.GitError::InvalidObject("Clone failed: no refs found")
        }
      } else {
        clone_local_repo(
          fs,
          src_path,
          clone_root,
          remote_display,
          bare,
          filter,
          mirror~,
          no_checkout~,
          separate_git_dir~,
          remote_name~,
          reference_alternates=reference_object_dirs,
        )
        if not(bare) && not(filter.is_partial()) {
          if not(no_checkout) {
            match @gitlib.resolve_head_commit(fs, clone_git_dir) {
              Some(commit_id) =>
                @gitlibnative.apply_worktree_modes_from_commit(
                  fs,
                  fs,
                  clone_root,
                  clone_git_dir,
                  commit_id,
                )
              None => ()
            }
          }
          pack_remote_tracking_refs(fs, clone_git_dir, remote_name)
        }
        if ref_spec is Some(refname) &&
          not(bare) &&
          not(filter.is_partial()) &&
          not(no_checkout) {
          let local_branch_ref = "refs/heads/" + refname
          if @gitlib.resolve_ref(fs, clone_git_dir, local_branch_ref) is Some(_) {
            let _ = @gitlib.checkout(fs, fs, clone_root, refname)
          } else {
            match resolve_local_clone_checkout_target(
              fs,
              clone_git_dir,
              src_path,
              refname,
            ) {
              Some(target_id) => {
                let _ = @gitlib.checkout(
                  fs,
                  fs,
                  clone_root,
                  target_id.to_hex(),
                  detach=true,
                )
              }
              None =>
                raise @git.GitError::InvalidObject("Unknown ref: " + refname)
            }
          }
        }
      }
    }
    None => {
      if separate_git_dir is Some(_) {
        raise @git.GitError::InvalidObject(
          "--separate-git-dir is only supported for local clone",
        )
      }
      if remote_name != "origin" {
        raise @git.GitError::InvalidObject(
          "-o/--origin is only supported for local clone",
        )
      }
      let refs = @gitionative.clone_http_to_fs(
        remote_url,
        true,
        fs,
        clone_root,
        depth~,
        filter~,
        no_checkout~,
      )
      if not(bare) && not(filter.is_partial()) {
        if not(no_checkout) {
          match @gitlib.resolve_head_commit(fs, clone_git_dir) {
            Some(commit_id) =>
              @gitlibnative.apply_worktree_modes_from_commit(
                fs,
                fs,
                clone_root,
                clone_git_dir,
                commit_id,
              )
            None => ()
          }
        }
        pack_remote_tracking_refs(fs, clone_git_dir, remote_name)
      }
      if refs.length() > 0 {
        if ref_spec is Some(refname) &&
          not(bare) &&
          not(filter.is_partial()) &&
          not(no_checkout) {
          match resolve_remote_ref_id(remote_url, refname) {
            Some((commit_id, branch)) => {
              let mut db = @gitlib.ObjectDb::load_lazy(fs, clone_git_dir)
              if db.get(fs, commit_id) is None {
                let pack = @gitionative.fetch_pack_http(
                  remote_url,
                  [commit_id],
                  true,
                )
                let objects = @pack.parse_packfile(pack)
                @pack.write_packfile_with_index(
                  fs,
                  clone_git_dir,
                  pack,
                  objects,
                )
                db = @gitlib.ObjectDb::load_lazy(fs, clone_git_dir)
              }
              match branch {
                Some(name) => {
                  fs.mkdir_p(clone_git_dir + "/refs/heads") catch {
                    err => {
                      if @async.is_being_cancelled() ||
                        @async.is_cancellation_error(err) {
                        raise err
                      }
                      ()
                    }
                  }
                  fs.write_string(
                    clone_git_dir + "/refs/heads/" + name,
                    commit_id.to_hex() + "\n",
                  ) catch {
                    err => {
                      if @async.is_being_cancelled() ||
                        @async.is_cancellation_error(err) {
                        raise err
                      }
                      ()
                    }
                  }
                  let _ = @gitlib.checkout(fs, fs, clone_root, name)
                }
                None => {
                  let _ = @gitlib.checkout(
                    fs,
                    fs,
                    clone_root,
                    commit_id.to_hex(),
                    detach=true,
                  )
                }
              }
            }
            None =>
              raise @git.GitError::InvalidObject("Unknown ref: " + refname)
          }
        }
      } else {
        raise @git.GitError::InvalidObject("Clone failed: no refs found")
      }
    }
  }
}

///|
fn trim_trailing_slashes(path : String) -> String {
  if path == "/" {
    return path
  }
  let mut end = path.length()
  while end > 0 {
    let c = String::unsafe_substring(path, start=end - 1, end=end)
    if c != "/" {
      break
    }
    end -= 1
  }
  if end == 0 {
    return path
  }
  String::unsafe_substring(path, start=0, end=end)
}

///|
fn absolutize_clone_path(base : String, path : String) -> String {
  if path.has_prefix("/") {
    normalize_path(path)
  } else {
    normalize_path(base + "/" + path)
  }
}

///|
fn ensure_clone_path_available(fs : OsFs, path : String) -> Unit raise Error {
  if fs.is_file(path) {
    raise @git.GitError::InvalidObject("path exists and is not dir: " + path)
  }
  if fs.is_dir(path) && not(is_empty_dir(fs, path)) {
    raise @git.GitError::InvalidObject(
      "destination path exists and is not an empty directory: " + path,
    )
  }
}

///|
fn resolve_local_clone_checkout_target(
  fs : OsFs,
  clone_git_dir : String,
  src_path : String,
  refname : String,
) -> @git.ObjectId? raise Error {
  let target = refname + "^{commit}"
  match @gitrepo.rev_parse(fs, clone_git_dir, target) {
    Some(id) => Some(id)
    None =>
      match @gitlib.detect_git_dir(fs, src_path) {
        Some((src_git_dir, _)) => @gitrepo.rev_parse(fs, src_git_dir, target)
        None => None
      }
  }
}

///|
