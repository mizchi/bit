///|
fn resolve_real_git_for_clone() -> String {
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
async fn delegate_clone_to_real_git(args : Array[String]) -> Unit raise Error {
  let real_git = resolve_real_git_for_clone()
  let delegated_args = ["clone"]
  delegated_args.append(args)
  let code = @process.run(
    real_git,
    delegated_args,
    inherit_env=true,
    cwd=get_work_root(),
  ) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => 1
  }
  @sys.exit(code)
}

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
  // In git-shim compatibility runs, prefer upstream clone semantics.
  if is_real_git_delegate_enabled() {
    delegate_to_real_git("clone", args)
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
  let mut no_local = false
  let mut reject_shallow = false
  let mut remote_name = "origin"
  let mut ref_spec : String? = None
  let mut ref_format = "files"
  let mut ssh_ip_option : String? = None
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
    if arg == "-4" || arg == "-6" {
      ssh_ip_option = Some(arg)
      i += 1
      continue
    }
    if arg == "-n" || arg == "--no-checkout" {
      no_checkout = true
      i += 1
      continue
    }
    if arg == "--no-local" {
      no_local = true
      i += 1
      continue
    }
    if arg == "--reject-shallow" {
      reject_shallow = true
      i += 1
      continue
    }
    if arg == "--no-reject-shallow" {
      reject_shallow = false
      i += 1
      continue
    }
    if (arg == "-b" || arg == "--branch") && i + 1 < args.length() {
      ref_spec = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--branch=") {
      ref_spec = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
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
      let dir = String::unsafe_substring(arg, start=19, end=arg.length())
      separate_git_dir_raw = Some(dir)
      i += 1
      continue
    }
    if arg == "--reference" && i + 1 < args.length() {
      reference_paths_raw.push(args[i + 1])
      i += 2
      continue
    }
    if arg == "--ref-format" && i + 1 < args.length() {
      let value = args[i + 1]
      if value != "files" && value != "reftable" {
        @stdio.stderr.write("fatal: unknown ref storage format '\{value}'\n")
        @sys.exit(1)
      }
      ref_format = value
      i += 2
      continue
    }
    if arg.has_prefix("--ref-format=") {
      let value = String::unsafe_substring(arg, start=13, end=arg.length())
      if value != "files" && value != "reftable" {
        @stdio.stderr.write("fatal: unknown ref storage format '\{value}'\n")
        @sys.exit(1)
      }
      ref_format = value
      i += 1
      continue
    }
    if arg.has_prefix("--reference=") {
      let ref_path = String::unsafe_substring(arg, start=12, end=arg.length())
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
  if ref_format == "reftable" {
    // Reftable clone parity is delegated until ref-storage backend support lands.
    delegate_clone_to_real_git(args)
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
  let config_overrides = @gitlib.parse_config_overrides()
  let protocol_version = match config_overrides.get("protocol.version") {
    Some(v) => v
    None => @sys.get_env_var("GIT_TEST_PROTOCOL_VERSION").unwrap_or("0")
  }
  let prefer_v2 = protocol_version == "2"
  let transport_prefer_v2 = prefer_v2 || depth > 0 || filter.is_partial()
  match ssh_ip_option {
    Some(v) => @sys.set_env_var("BIT_SSH_IP_VERSION", v)
    None => @sys.unset_env_var("BIT_SSH_IP_VERSION")
  }
  ignore(has_filter_flag)
  ignore(mirror)
  ignore(ref_format)
  if recursive {
    @stdio.stderr.write("fatal: --recursive is not supported yet\n")
    @sys.exit(1)
  }
  let fs = OsFs::new()
  let local_src_path = @gitlib.resolve_local_repo_path(
    fs, command_root, remote_url,
  )
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
  let relative_target = trim_trailing_slashes(
    match dest {
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
          if base.has_suffix(".git") {
            base
          } else {
            base + ".git"
          }
        } else {
          base
        }
      }
    },
  )
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
    None => if bare { clone_root } else { clone_root + "/.git" }
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
      let use_transport_clone = (no_local || filter.is_partial() || depth > 0) &&
        separate_git_dir is None &&
        remote_name == "origin"
      if use_transport_clone {
        let clone_filter = resolve_clone_transport_filter(
          remote_display, transport_prefer_v2, filter,
        )
        let refs = @gitionative.clone_http_to_fs(
          remote_display,
          transport_prefer_v2,
          fs,
          clone_root,
          depth~,
          filter=clone_filter,
          no_checkout~,
        )
        if bare {
          promote_transport_clone_to_bare_layout(fs, clone_root)
        }
        if refs.length() == 0 {
          raise @git.GitError::InvalidObject("Clone failed: no refs found")
        }
        if clone_filter.is_partial() && not(no_checkout) && not(bare) {
          let checkout_spec = read_head_checkout_spec_for_clone(
            fs, clone_git_dir,
          )
          let checked_id = checkout_with_promisor_retry_clone(
            fs, clone_root, checkout_spec,
          )
          warn_case_insensitive_collisions_from_commit(
            fs, clone_git_dir, checked_id,
          )
          @gitlibnative.apply_worktree_modes_from_commit(
            fs, fs, clone_root, clone_git_dir, checked_id,
          )
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
              Some(commit_id) => {
                warn_case_insensitive_collisions_from_commit(
                  fs, clone_git_dir, commit_id,
                )
                @gitlibnative.apply_worktree_modes_from_commit(
                  fs, fs, clone_root, clone_git_dir, commit_id,
                )
              }
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
            let checked_id = @gitlib.checkout(fs, fs, clone_root, refname)
            warn_case_insensitive_collisions_from_commit(
              fs, clone_git_dir, checked_id,
            )
            @gitlibnative.apply_worktree_modes_from_commit(
              fs, fs, clone_root, clone_git_dir, checked_id,
            )
          } else {
            match
              resolve_local_clone_checkout_target(
                fs, clone_git_dir, src_path, refname,
              ) {
              Some(target_id) => {
                let checked_id = @gitlib.checkout(
                  fs,
                  fs,
                  clone_root,
                  target_id.to_hex(),
                  detach=true,
                )
                warn_case_insensitive_collisions_from_commit(
                  fs, clone_git_dir, checked_id,
                )
                @gitlibnative.apply_worktree_modes_from_commit(
                  fs, fs, clone_root, clone_git_dir, checked_id,
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
      let clone_filter = resolve_clone_transport_filter(
        remote_url, transport_prefer_v2, filter,
      )
      let refs = @gitionative.clone_http_to_fs(
        remote_url,
        transport_prefer_v2,
        fs,
        clone_root,
        depth~,
        filter=clone_filter,
        no_checkout~,
      )
      if bare {
        promote_transport_clone_to_bare_layout(fs, clone_root)
      }
      if clone_filter.is_partial() && not(no_checkout) && not(bare) {
        let checkout_spec = read_head_checkout_spec_for_clone(fs, clone_git_dir)
        let checked_id = checkout_with_promisor_retry_clone(
          fs, clone_root, checkout_spec,
        )
        warn_case_insensitive_collisions_from_commit(
          fs, clone_git_dir, checked_id,
        )
        @gitlibnative.apply_worktree_modes_from_commit(
          fs, fs, clone_root, clone_git_dir, checked_id,
        )
      }
      if not(bare) && not(clone_filter.is_partial()) {
        if not(no_checkout) {
          match @gitlib.resolve_head_commit(fs, clone_git_dir) {
            Some(commit_id) => {
              warn_case_insensitive_collisions_from_commit(
                fs, clone_git_dir, commit_id,
              )
              @gitlibnative.apply_worktree_modes_from_commit(
                fs, fs, clone_root, clone_git_dir, commit_id,
              )
            }
            None => ()
          }
        }
        pack_remote_tracking_refs(fs, clone_git_dir, remote_name)
      }
      if refs.length() > 0 {
        if ref_spec is Some(refname) &&
          not(bare) &&
          not(clone_filter.is_partial()) &&
          not(no_checkout) {
          match resolve_remote_ref_id(remote_url, refname) {
            Some((commit_id, branch)) => {
              let mut db = @gitlib.ObjectDb::load_lazy(fs, clone_git_dir)
              if db.get(fs, commit_id) is None {
                let pack = @gitionative.fetch_pack_http(
                  remote_url,
                  [commit_id],
                  transport_prefer_v2,
                )
                let objects = @pack.parse_packfile(pack)
                @pack.write_packfile_with_index(
                  fs, clone_git_dir, pack, objects,
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
                  let checked_id = @gitlib.checkout(fs, fs, clone_root, name)
                  warn_case_insensitive_collisions_from_commit(
                    fs, clone_git_dir, checked_id,
                  )
                  @gitlibnative.apply_worktree_modes_from_commit(
                    fs, fs, clone_root, clone_git_dir, checked_id,
                  )
                }
                None => {
                  let checked_id = @gitlib.checkout(
                    fs,
                    fs,
                    clone_root,
                    commit_id.to_hex(),
                    detach=true,
                  )
                  warn_case_insensitive_collisions_from_commit(
                    fs, clone_git_dir, checked_id,
                  )
                  @gitlibnative.apply_worktree_modes_from_commit(
                    fs, fs, clone_root, clone_git_dir, checked_id,
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
  if reject_shallow {
    match @gitlib.resolve_head_commit(fs, clone_git_dir) {
      Some(head_id) =>
        if clone_has_missing_parent_history(fs, clone_git_dir, head_id) {
          cleanup_failed_clone(fs, clone_root, separate_git_dir)
          @stdio.stderr.write(
            "fatal: source repository is shallow, reject to clone.\n",
          )
          @sys.exit(1)
        }
      None => ()
    }
  }
  let bundle_uris = discover_clone_bundle_uris(
    remote_url, transport_prefer_v2, config_overrides,
  ) catch {
    _ => []
  }
  emit_clone_bundle_trace_events(fs, bundle_uris)
}

///|
async fn resolve_clone_transport_filter(
  remote : String,
  prefer_v2 : Bool,
  requested : @protocol.FilterSpec,
) -> @protocol.FilterSpec raise Error {
  if not(requested.is_partial()) {
    return requested
  }
  let (_, caps, version, _symrefs) = @gitionative.discover_upload_refs_http(
    remote, prefer_v2,
  )
  if clone_remote_supports_filter(caps, version) {
    return requested
  }
  @stdio.stderr.write("warning: filtering not recognized by server, ignoring\n")
  @protocol.FilterSpec::NoFilter
}

///|
fn clone_remote_supports_filter(
  caps : Array[String],
  version : @protocol.ProtocolVersion,
) -> Bool {
  match version {
    @protocol.ProtocolVersion::V2 => clone_caps_contain_token(caps, "filter")
    @protocol.ProtocolVersion::V0 => caps.contains("filter")
  }
}

///|
fn clone_caps_contain_token(caps : Array[String], token : String) -> Bool {
  let token_with_eq = token + "="
  for cap in caps {
    if cap == token || cap.has_prefix(token_with_eq) {
      return true
    }
    let words = clone_split_words(cap)
    if words.length() == 0 {
      continue
    }
    for word in words {
      if word == token || word.has_prefix(token_with_eq) {
        return true
      }
    }
    if cap.has_prefix("fetch=") {
      let first_word = words[0]
      if first_word.has_prefix("fetch=") {
        let fetch_word = String::unsafe_substring(
          first_word,
          start=6,
          end=first_word.length(),
        )
        if fetch_word == token || fetch_word.has_prefix(token_with_eq) {
          return true
        }
      }
    }
  }
  false
}

///|
fn clone_split_words(input : String) -> Array[String] {
  let words : Array[String] = []
  let mut current = StringBuilder::new()
  for ch in input {
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      let s = current.to_string()
      if s.length() > 0 {
        words.push(s)
        current = StringBuilder::new()
      }
    } else {
      current.write_char(ch)
    }
  }
  let s = current.to_string()
  if s.length() > 0 {
    words.push(s)
  }
  words
}

///|
async fn discover_clone_bundle_uris(
  remote : String,
  prefer_v2 : Bool,
  config_overrides : Map[String, String],
) -> Array[String] raise Error {
  if not(clone_config_is_true(config_overrides, "transfer.bundleuri")) {
    return []
  }
  let spec = @protocol.parse_remote(remote)
  if spec.kind != @protocol.RemoteKind::Http {
    return []
  }
  let (_, caps, version, _symrefs) = @gitionative.discover_upload_refs_http(
    remote, prefer_v2,
  )
  if version != @protocol.ProtocolVersion::V2 {
    return []
  }
  if not(clone_caps_contain_token(caps, "bundle-uri")) {
    return []
  }
  let req = build_bundle_uri_request_for_clone()
  let resp = @gitionative.upload_pack_request_http(remote, req, true)
  let uris = parse_bundle_uri_response_for_clone(resp) catch { _ => [] }
  if uris.length() > 0 {
    return uris
  }
  let fallback = parse_bundle_uri_response_loose_for_clone(resp)
  fallback
}

///|
fn clone_config_is_true(overrides : Map[String, String], key : String) -> Bool {
  match overrides.get(key) {
    Some(value) => {
      let normalized = trim_string(value).to_lower()
      normalized == "" ||
      normalized == "true" ||
      normalized == "1" ||
      normalized == "yes" ||
      normalized == "on"
    }
    None => false
  }
}

///|
fn build_bundle_uri_request_for_clone() -> Bytes {
  let chunks : Array[Bytes] = []
  chunks.push(@protocol.pktline_encode("command=bundle-uri\n"))
  chunks.push(@protocol.pktline_encode("agent=git/moonbit\n"))
  chunks.push(@protocol.pktline_encode("object-format=sha1\n"))
  chunks.push(@protocol.pktline_delim())
  chunks.push(@protocol.pktline_flush())
  let out : Array[Byte] = []
  for chunk in chunks {
    for b in chunk {
      out.push(b)
    }
  }
  Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
}

///|
fn parse_bundle_uri_response_for_clone(
  data : Bytes,
) -> Array[String] raise Error {
  let lines = @protocol.pktline_decode(data)
  let kv_lines : Array[String] = []
  for item in lines {
    let (line_bytes, is_flush) = item
    if is_flush || line_bytes.length() == 0 {
      continue
    }
    kv_lines.push(trim_string(decode_bytes(line_bytes)))
  }
  parse_bundle_uri_lines_for_clone(kv_lines)
}

///|
fn parse_bundle_uri_response_loose_for_clone(data : Bytes) -> Array[String] {
  let kv_lines : Array[String] = []
  let raw = decode_bytes(data)
  for view in raw.split("\n") {
    let line = view.to_string()
    match line.find("bundle.") {
      Some(idx) =>
        kv_lines.push(
          String::unsafe_substring(line, start=idx, end=line.length()),
        )
      None => ()
    }
  }
  parse_bundle_uri_lines_for_clone(kv_lines)
}

///|
fn parse_bundle_uri_lines_for_clone(lines : Array[String]) -> Array[String] {
  let names_in_order : Array[String] = []
  let seen_name : Map[String, Bool] = {}
  let uri_by_name : Map[String, String] = {}
  let token_by_name : Map[String, Int] = {}
  let mut heuristic = ""
  for raw_line in lines {
    let line = trim_string(raw_line)
    if line.length() == 0 {
      continue
    }
    match line.find("=") {
      Some(eq_idx) => {
        let key = String::unsafe_substring(line, start=0, end=eq_idx)
        let value = String::unsafe_substring(
          line,
          start=eq_idx + 1,
          end=line.length(),
        )
        if key == "bundle.heuristic" {
          heuristic = value.to_lower()
          continue
        }
        if not(key.has_prefix("bundle.")) {
          continue
        }
        let tail = String::unsafe_substring(key, start=7, end=key.length())
        match tail.find(".") {
          Some(dot_idx) => {
            let name = String::unsafe_substring(tail, start=0, end=dot_idx)
            let field = String::unsafe_substring(
              tail,
              start=dot_idx + 1,
              end=tail.length(),
            ).to_lower()
            if name.length() == 0 {
              continue
            }
            if not(seen_name.contains(name)) {
              seen_name[name] = true
              names_in_order.push(name)
            }
            if field == "uri" {
              uri_by_name[name] = value
            } else if field == "creationtoken" {
              let token = @strconv.parse_int(value) catch { _ => 0 }
              token_by_name[name] = token
            }
          }
          None => ()
        }
      }
      None => ()
    }
  }
  let ordered_names : Array[String] = []
  for name in names_in_order {
    if uri_by_name.contains(name) {
      ordered_names.push(name)
    }
  }
  if heuristic == "creationtoken" {
    ordered_names.sort_by((a, b) => {
      let ta = token_by_name.get(a).unwrap_or(0)
      let tb = token_by_name.get(b).unwrap_or(0)
      if ta > tb {
        -1
      } else if ta < tb {
        1
      } else {
        0
      }
    })
  }
  let uris : Array[String] = []
  for name in ordered_names {
    match uri_by_name.get(name) {
      Some(uri) => uris.push(uri)
      None => ()
    }
  }
  uris
}

///|
fn emit_clone_bundle_trace_events(
  fs : OsFs,
  bundle_uris : Array[String],
) -> Unit {
  if bundle_uris.length() == 0 {
    return ()
  }
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) =>
      for uri in bundle_uris {
        append_clone_trace_line(
          fs,
          path,
          "{\"event\":\"child_start\",\"argv\":[\"git-remote-https\",\"" +
          uri +
          "\"]}\n",
        )
      }
    None => ()
  }
}

///|
fn append_clone_trace_line(fs : OsFs, path : String, line : String) -> Unit {
  let existing = decode_bytes(fs.read_file(path) catch { _ => b"" })
  fs.write_string(path, existing + line) catch {
    _ => ()
  }
}

///|
fn clone_has_missing_parent_history(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  start_commit : @git.ObjectId,
) -> Bool raise Error {
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  db.set_skip_verify(true)
  let stack : Array[@git.ObjectId] = [start_commit]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = stack.pop().unwrap_or(start_commit)
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    let obj = db.get(fs, id)
    match obj {
      Some(o) if o.obj_type == @git.ObjectType::Commit => {
        let info_opt = (@git.parse_commit(o.data) |> Some) catch { _ => None }
        match info_opt {
          Some(info) =>
            for parent in info.parents {
              if db.get(fs, parent) is None {
                return true
              }
              stack.push(parent)
            }
          None => ()
        }
      }
      Some(_) => ()
      None => return true
    }
  }
  false
}

///|
fn cleanup_failed_clone(
  fs : OsFs,
  clone_root : String,
  separate_git_dir : String?,
) -> Unit {
  @gitlib.remove_tree(fs, fs, clone_root)
  match separate_git_dir {
    Some(path) => if path != clone_root { @gitlib.remove_tree(fs, fs, path) }
    None => ()
  }
}

///|
fn promote_transport_clone_to_bare_layout(fs : OsFs, root : String) -> Unit {
  let nested_git_dir = root + "/.git"
  if not(fs.is_dir(nested_git_dir)) {
    return ()
  }
  let root_entries = fs.readdir(root) catch { _ => [] }
  for entry in root_entries {
    if entry == "." || entry == ".." || entry == ".git" {
      continue
    }
    @gitlib.remove_tree(fs, fs, root + "/" + entry)
  }
  let nested_entries = fs.readdir(nested_git_dir) catch { _ => [] }
  for entry in nested_entries {
    if entry == "." || entry == ".." {
      continue
    }
    let src = nested_git_dir + "/" + entry
    let dest = root + "/" + entry
    @gitlib.copy_tree(fs, fs, src, dest) catch {
      _ => ()
    }
  }
  @gitlib.remove_tree(fs, fs, nested_git_dir)
}

///|
fn trim_trailing_slashes(path : String) -> String {
  if path == "/" {
    return path
  }
  let mut end = path.length()
  while end > 0 {
    let c = String::unsafe_substring(path, start=end - 1, end~)
    if c != "/" {
      break
    }
    end -= 1
  }
  if end == 0 {
    return path
  }
  String::unsafe_substring(path, start=0, end~)
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
fn read_head_checkout_spec_for_clone(fs : OsFs, git_dir : String) -> String {
  let head_path = git_dir + "/HEAD"
  if not(fs.is_file(head_path)) {
    return "HEAD"
  }
  let head = trim_string(
    decode_bytes(fs.read_file(head_path) catch { _ => b"" }),
  )
  if head.length() == 0 {
    return "HEAD"
  }
  if head.has_prefix("ref: refs/heads/") {
    return String::unsafe_substring(head, start=16, end=head.length())
  }
  if head.has_prefix("ref: ") {
    return String::unsafe_substring(head, start=5, end=head.length())
  }
  "HEAD"
}

///|
async fn checkout_with_promisor_retry_clone(
  fs : OsFs,
  root : String,
  spec : String,
) -> @git.ObjectId raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let mut promisor_db : @gitlib.PromisorDb? = None
  let mut attempts = 0
  while attempts < 16 {
    let result : Result[@git.ObjectId, Error] = try? @gitlib.checkout(
      fs, fs, root, spec,
    )
    match result {
      Ok(id) => return id
      Err(err) =>
        match parse_checkout_missing_object_id_for_clone(err) {
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
fn parse_checkout_missing_object_id_for_clone(err : Error) -> @git.ObjectId? {
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
fn worktree_is_case_insensitive_for_clone(fs : OsFs, git_dir : String) -> Bool {
  let lower_path = git_dir + "/bit-case-probe-9fcb2c2d"
  let upper_path = git_dir + "/BIT-CASE-PROBE-9FCB2C2D"
  if fs.is_file(lower_path) ||
    fs.is_dir(lower_path) ||
    fs.is_file(upper_path) ||
    fs.is_dir(upper_path) {
    return false
  }
  fs.write_string(lower_path, "1") catch {
    _ => return false
  }
  let insensitive = fs.is_file(upper_path)
  if fs.is_file(lower_path) {
    fs.remove_file(lower_path) catch {
      _ => ()
    }
  }
  insensitive
}

///|
fn collect_case_collision_paths(paths : Array[String]) -> Array[String] {
  let sorted_paths : Array[String] = []
  for path in paths {
    sorted_paths.push(path)
  }
  sorted_paths.sort_by((a, b) => String::compare(a, b))
  let collided : Map[String, Bool] = {}
  let mut i = 0
  while i < sorted_paths.length() {
    let left = sorted_paths[i]
    let left_fold = left.to_lower()
    let mut j = i + 1
    while j < sorted_paths.length() {
      let right = sorted_paths[j]
      let right_fold = right.to_lower()
      if left_fold == right_fold {
        collided[left] = true
        collided[right] = true
      } else {
        let right_prefix = right_fold + "/"
        let left_prefix = left_fold + "/"
        if left_fold.has_prefix(right_prefix) ||
          right_fold.has_prefix(left_prefix) {
          collided[left] = true
          collided[right] = true
        }
      }
      j += 1
    }
    i += 1
  }
  let out : Array[String] = []
  for item in collided.to_array() {
    let (path, _) = item
    out.push(path)
  }
  out.sort_by((a, b) => String::compare(a, b))
  out
}

///|
async fn warn_case_insensitive_collisions_from_commit(
  fs : OsFs,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise Error {
  if not(worktree_is_case_insensitive_for_clone(fs, git_dir)) {
    return
  }
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir) catch { _ => return }
  let files = @gitlib.collect_tree_files_from_commit(db, fs, commit_id) catch {
    _ => return
  }
  let paths : Array[String] = []
  for item in files.to_array() {
    let (path, _) = item
    paths.push(path)
  }
  let collided_paths = collect_case_collision_paths(paths)
  if collided_paths.length() > 0 {
    @stdio.stderr.write("warning: the following paths have collided:\n")
    for path in collided_paths {
      @stdio.stderr.write("  " + path + "\n")
    }
  }
}

///|
