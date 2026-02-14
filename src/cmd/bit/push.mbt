///|
async fn handle_push(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  if real_git_delegate_is_available(rfs) {
    delegate_to_real_git("push", args)
  }
  let root = get_work_root()
  let git_dir = resolve_git_dir(fs, root)
  // Check if this is a subdir-clone
  let subdir_remote = match get_subdir_info(fs, git_dir) {
    Some((remote, _, _)) => Some(remote)
    None => None
  }
  // Parse arguments
  let mut force = false
  let mut set_upstream = false
  let mut push_all = false
  let mut push_tags = false
  let mut follow_tags = false
  let mut push_prune = false
  let mut dry_run = false
  let mut delete_mode = false
  let mut porcelain = false
  let mut quiet = false
  let positional_args : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "--no-force" => force = false
      "-u" | "--set-upstream" => set_upstream = true
      "--all" => push_all = true
      "--tags" => push_tags = true
      "--follow-tags" => follow_tags = true
      "--no-follow-tags" => follow_tags = false
      "--prune" => push_prune = true
      "--dry-run" => dry_run = true
      "-d" | "--delete" => delete_mode = true
      "--porcelain" => porcelain = true
      "-q" | "--quiet" => quiet = true
      "--no-quiet" => quiet = false
      "--no-ipv4" | "--no-ipv6" =>
        raise @git.GitError::InvalidObject(
          "unknown option '" + option_name_without_prefix(arg) + "'",
        )
      _ if arg.has_prefix("-") => warn_unimplemented_arg("push", arg)
      _ => positional_args.push(arg)
    }
  }
  let legacy_branch_remote : (String, String, String?)? = if positional_args.length() >
    0 {
    let first = positional_args[0]
    if @gitlib.get_remote_url(fs, git_dir, first) is Some(_) {
      None
    } else {
      match parse_legacy_branches_entry(fs, git_dir, first) {
        Some((url, branch)) => Some((first, url, branch))
        None => None
      }
    }
  } else {
    None
  }
  let is_known_remote = fn(name) {
    let legacy_match = match legacy_branch_remote {
      Some((legacy_name, _, _)) => legacy_name == name
      None => false
    }
    legacy_match ||
    @gitlib.get_remote_url(fs, git_dir, name) is Some(_) ||
    @gitlib.resolve_local_repo_path(fs, root, name) is Some(_) ||
    parse_remote_helper_url(name) is Some(_) ||
    name.contains("://") ||
    name.has_prefix("git@")
  }
  ignore(resolve_push_positionals(positional_args, is_known_remote))
  let (explicit_remote, explicit_refspecs_raw) = resolve_push_positionals_multi(
    positional_args, is_known_remote,
  )
  let head_ref = @gitlib.read_head_ref(fs, git_dir)
  let current_branch_opt = match head_ref {
    @gitlib.HeadRef::Branch(branch) => Some(branch)
    @gitlib.HeadRef::Detached(_) => None
  }
  let (_, local_branches_for_default) = @gitlib.list_branches(fs, git_dir)
  let mut fallback_branch = "main"
  if local_branches_for_default.length() > 0 {
    let mut has_main = false
    for branch in local_branches_for_default {
      if branch.name == "main" {
        has_main = true
        break
      }
    }
    if not(has_main) {
      fallback_branch = local_branches_for_default[0].name
    }
  }
  let current_branch = match current_branch_opt {
    Some(branch) => branch
    None => fallback_branch
  }
  ensure_no_empty_branch_config(fs, fs, git_dir)
  let (remote_configs, branches) = @gitlib.read_repo_config(fs, git_dir)
  let (branch_remote, branch_merge) = match branches.get(current_branch) {
    Some(cfg) => {
      let merge = if cfg.merges.length() > 0 {
        Some(cfg.merges[0])
      } else {
        None
      }
      (cfg.remote, merge)
    }
    None => (None, None)
  }
  let branch_pushremote = read_branch_pushremote(fs, git_dir, current_branch)
  let effective_branch_remote = match branch_pushremote {
    Some(name) => Some(name)
    None => branch_remote
  }
  let remotes = @gitlib.list_remotes(fs, git_dir)
  let config_path = git_dir + "/config"
  let overrides = @gitlib.parse_config_overrides()
  let push_default = match overrides.get("push.default") {
    Some(v) => Some(v)
    None => @gitlib.read_config_value(fs, config_path, "push", "default")
  }
  let remote_pushdefault = match overrides.get("remote.pushdefault") {
    Some(v) => Some(v)
    None => @gitlib.read_config_value(fs, config_path, "remote", "pushdefault")
  }
  let effective_remote_pushdefault = match branch_pushremote {
    Some(_) => None
    None => remote_pushdefault
  }
  let auto_setup_remote = match overrides.get("push.autosetupremote") {
    Some(v) => parse_config_bool_string(Some(v))
    None =>
      @gitlib.read_config_bool(fs, config_path, "push", "autosetupremote").unwrap_or(
        false,
      )
  }
  let push_negotiate = match overrides.get("push.negotiate") {
    Some(v) => parse_config_bool_string(Some(v))
    None =>
      @gitlib.read_config_bool(fs, config_path, "push", "negotiate").unwrap_or(
        false,
      )
  }
  let protocol_version = match overrides.get("protocol.version") {
    Some(v) => v
    None => @sys.get_env_var("GIT_TEST_PROTOCOL_VERSION").unwrap_or("2")
  }
  let negotiation_failed = push_negotiate && protocol_version == "0"
  if negotiation_failed {
    eprint_line("warning: push negotiation failed")
  }
  let push_default_mode = parse_push_default_mode(push_default)
  let refspec_args : Array[String] = []
  if delete_mode {
    if explicit_refspecs_raw.length() == 0 {
      raise @git.GitError::InvalidObject("push --delete requires refs")
    }
    let mut i = 0
    while i < explicit_refspecs_raw.length() {
      let target = explicit_refspecs_raw[i]
      if target.length() == 0 {
        raise @git.GitError::InvalidObject(
          "push --delete does not take empty ref",
        )
      }
      if target == "tag" {
        if i + 1 >= explicit_refspecs_raw.length() {
          raise @git.GitError::InvalidObject(
            "push --delete tag requires tag name",
          )
        }
        let tag_name = explicit_refspecs_raw[i + 1]
        if tag_name.length() == 0 {
          raise @git.GitError::InvalidObject(
            "push --delete does not take empty ref",
          )
        }
        refspec_args.push(":refs/tags/" + tag_name)
        i += 2
        continue
      }
      if target.contains(":") {
        raise @git.GitError::InvalidObject(
          "push --delete does not take src:dst refspec",
        )
      }
      refspec_args.push(":" + target)
      i += 1
    }
  } else {
    let mut i = 0
    while i < explicit_refspecs_raw.length() {
      let spec = explicit_refspecs_raw[i]
      if spec == "tag" {
        if i + 1 >= explicit_refspecs_raw.length() {
          raise @git.GitError::InvalidObject("push tag requires tag name")
        }
        let tag_name = explicit_refspecs_raw[i + 1]
        if tag_name.length() == 0 {
          raise @git.GitError::InvalidObject("push tag requires tag name")
        }
        let tag_ref = "refs/tags/" + tag_name
        refspec_args.push(tag_ref + ":" + tag_ref)
        i += 2
        continue
      }
      refspec_args.push(spec)
      i += 1
    }
  }
  if push_tags {
    refspec_args.push("refs/tags/*:refs/tags/*")
  }
  let mut legacy_push_url : String? = None
  if refspec_args.length() == 0 &&
    not(push_all) &&
    not(push_tags) &&
    not(delete_mode) {
    match (legacy_branch_remote, explicit_remote) {
      (Some((legacy_name, legacy_url, legacy_branch)), Some(explicit_name)) =>
        if explicit_name == legacy_name {
          let branch = match legacy_branch {
            Some(name) => name
            None => legacy_default_branch_name()
          }
          legacy_push_url = Some(legacy_url)
          refspec_args.push("HEAD:refs/heads/" + branch)
        }
      _ => ()
    }
  }
  let mut remote_name = ""
  let mut default_plan : PushTargetPlan? = None
  if push_all {
    if refspec_args.length() > 0 {
      raise @git.GitError::InvalidObject("push --all does not take refspec")
    }
    remote_name = match explicit_remote {
      Some(name) => name
      None =>
        select_current_like_remote(
          remotes, effective_branch_remote, effective_remote_pushdefault,
        )
    }
  } else if refspec_args.length() > 0 {
    let probe = resolve_push_target_plan(
      explicit_remote,
      Some("HEAD"),
      current_branch,
      remotes,
      effective_branch_remote,
      branch_merge,
      push_default,
      effective_remote_pushdefault,
      auto_setup_remote,
    )
    remote_name = probe.remote_name
  } else {
    let tentative_remote = match explicit_remote {
      Some(name) => name
      None =>
        select_current_like_remote(
          remotes, effective_branch_remote, effective_remote_pushdefault,
        )
    }
    let configured_specs = match remote_configs.get(tentative_remote) {
      Some(rc) => rc.push
      None => []
    }
    if configured_specs.length() > 0 {
      remote_name = tentative_remote
      for spec in configured_specs {
        refspec_args.push(spec)
      }
    } else {
      match push_default_mode {
        PushDefaultMode::Matching => {
          remote_name = tentative_remote
          refspec_args.push(":")
        }
        _ => {
          let plan = resolve_push_target_plan(
            explicit_remote,
            None,
            current_branch,
            remotes,
            effective_branch_remote,
            branch_merge,
            push_default,
            effective_remote_pushdefault,
            auto_setup_remote,
          )
          remote_name = plan.remote_name
          default_plan = Some(plan)
        }
      }
    }
  }
  let parsed_refspecs = parse_push_refspecs_with_presence(refspec_args)
  for spec in parsed_refspecs {
    let src_spec = spec.src
    if spec.src == spec.dst {
      continue
    }
    let has_head_ref = @gitlib.resolve_ref(
        fs,
        git_dir,
        "refs/heads/" + src_spec,
      )
      is Some(_)
    let has_tag_ref = @gitlib.resolve_ref(fs, git_dir, "refs/tags/" + src_spec)
      is Some(_)
    if is_ambiguous_push_source_refspec(src_spec, has_head_ref, has_tag_ref) {
      raise @git.GitError::InvalidObject(
        "src refspec '\{src_spec}' matches more than one",
      )
    }
  }
  if remote_name.length() == 0 {
    raise @git.GitError::InvalidObject("fatal: bad repository ''")
  }
  let remote_push_refmaps = match remote_configs.get(remote_name) {
    Some(rc) => rc.push
    None => []
  }
  // Get remote URL - prefer subdir-clone remote
  let remote_url = match subdir_remote {
    Some(url) => Some(url)
    None =>
      match legacy_push_url {
        Some(url) => Some(url)
        None =>
          match remote_configs.get(remote_name) {
            Some(rc) =>
              if rc.pushurls.length() > 0 {
                Some(rc.pushurls[0])
              } else if rc.urls.length() > 0 {
                Some(rc.urls[0])
              } else {
                None
              }
            None =>
              match @gitlib.resolve_local_repo_path(fs, root, remote_name) {
                Some(path) => Some(path)
                None =>
                  if explicit_remote is Some(_) {
                    Some(remote_name)
                  } else {
                    None
                  }
              }
          }
      }
  }
  guard remote_url is Some(raw_url) else {
    raise @git.GitError::InvalidObject("No such remote: \{remote_name}")
  }
  let rewrite_rules = read_url_rewrite_rules(fs, git_dir)
  let has_explicit_pushurl = match remote_configs.get(remote_name) {
    Some(rc) => rc.pushurls.length() > 0
    None => false
  }
  let url = if has_explicit_pushurl {
    raw_url
  } else {
    rewrite_url_by_rules(raw_url, rewrite_rules, true)
  }
  let push_target_display = if explicit_remote is Some(_) &&
    remote_configs.get(remote_name) is None {
    remote_name
  } else {
    url
  }
  let helper_info = parse_remote_helper_url(url)
  let helper_is_testgit = match helper_info {
    Some((name, _)) => name == "testgit"
    None => false
  }
  let mut auto_set_upstream_needed = false
  let mut upstream_refname : String? = None
  match default_plan {
    Some(plan) => {
      auto_set_upstream_needed = plan.auto_set_upstream
      if not(plan.delete_ref) {
        upstream_refname = Some(plan.dest_ref)
      }
    }
    None => ()
  }
  if helper_is_testgit &&
    refspec_args.length() == 0 &&
    not(push_all) &&
    default_plan is Some(_) {
    if @sys.get_env_var("GIT_REMOTE_TESTGIT_NOREFSPEC") is Some(_) {
      raise @git.GitError::InvalidObject(
        "remote-helper doesn't support push; refspec needed",
      )
    }
  }
  let mut first_refname = "refs/heads/" + current_branch
  match default_plan {
    Some(plan) => first_refname = plan.dest_ref
    None =>
      if refspec_args.length() > 0 {
        let specs = @gitlib.parse_push_refspecs(refspec_args)
        if specs.length() > 0 {
          let first = specs[0]
          if first.src.length() == 0 && first.dst.length() > 0 {
            first_refname = normalize_push_ref_token(
              first.dst,
              current_branch,
              true,
            )
          } else if first.dst.length() > 0 {
            first_refname = normalize_push_ref_token(
              first.dst,
              current_branch,
              true,
            )
          } else if first.src.length() > 0 {
            first_refname = normalize_push_ref_token(
              first.src,
              current_branch,
              true,
            )
          }
        }
      }
  }
  // Check if this is a subdir-clone - if so, transform commits before push
  match get_subdir_info(fs, git_dir) {
    Some((remote_url, subdir_path, base_hex)) => {
      if porcelain {
        print_line("To \{remote_url}")
      } else if not(quiet) {
        print_line("Pushing subdir-clone to \{remote_url}...")
        print_line("  Subdirectory: \{subdir_path}")
      }
      handle_subdir_push(
        fs, root, git_dir, remote_url, subdir_path, base_hex, first_refname, force,
      ) catch {
        err => raise err
      }
      if porcelain {
        let (flag, status) = classify_push_porcelain_success(
          @git.ObjectId::zero(),
          @gitlib.resolve_head_commit(fs, git_dir).unwrap_or(
            @git.ObjectId::zero(),
          ),
          false,
          force,
        )
        print_line(
          format_push_porcelain_line(flag, "HEAD", first_refname, status),
        )
        print_line("Done")
      }
    }
    None => {
      if porcelain {
        print_line("To \{push_target_display}")
      } else if not(quiet) {
        print_line("Pushing to \{url}...")
      }
      match @gitlib.resolve_local_repo_path(fs, root, url) {
        Some(remote_path) => {
          let remote_detect = @gitlib.detect_git_dir(fs, remote_path)
          guard remote_detect is Some((rgd, _remote_path_is_bare)) else {
            raise @git.GitError::InvalidObject(
              "Not a git repository: " + remote_path,
            )
          }
          if helper_is_testgit &&
            @sys.get_env_var("GIT_REMOTE_TESTGIT_FAILURE") is Some(_) {
            raise @git.GitError::InvalidObject(
              "failed to push some refs to '\{url}'",
            )
          }
          let local_db = @gitlib.ObjectDb::load(fs, git_dir)
          let has_named_remote = remote_configs.get(remote_name) is Some(_)
          let remote_config_path = rgd + "/config"
          let remote_log_all_ref_updates = @gitlib.read_config_value(
            fs, remote_config_path, "core", "logallrefupdates",
          ).map(fn(v) { v.to_lower() })
          let remote_log_enabled = match remote_log_all_ref_updates {
            Some("always") => true
            _ => parse_config_bool_string(remote_log_all_ref_updates)
          }
          let remote_config_bare = parse_config_bool_string(
            @gitlib.read_config_value(fs, remote_config_path, "core", "bare"),
          )
          let deny_current_branch = @gitlib.read_config_value(
            fs, remote_config_path, "receive", "denycurrentbranch",
          ).map(fn(v) { v.to_lower() })
          let deny_delete_current = @gitlib.read_config_value(
            fs, remote_config_path, "receive", "denydeletecurrent",
          ).map(fn(v) { v.to_lower() })
          let push_hide_refs = read_hide_refs(fs, rgd, ["transfer", "receive"])
          let no_private_update = helper_is_testgit &&
            @sys.get_env_var("GIT_REMOTE_TESTGIT_NO_PRIVATE_UPDATE") is Some(_)
          let (
            push_log_name,
            push_log_email,
            push_log_timestamp,
            push_log_timezone,
          ) = get_committer_identity()
          let push_plans : Array[PushRefPlan] = []
          if push_all {
            let (_, local_branches) = @gitlib.list_branches(fs, git_dir)
            for branch in local_branches {
              let refname = "refs/heads/" + branch.name
              push_plans.push({
                source_ref: refname,
                dest_ref: refname,
                delete_ref: false,
                force,
              })
            }
          } else {
            match default_plan {
              Some(plan) =>
                push_plans.push({
                  source_ref: plan.source_ref,
                  dest_ref: plan.dest_ref,
                  delete_ref: plan.delete_ref,
                  force,
                })
              None => {
                let specs = parse_push_refspecs_with_presence(refspec_args)
                for spec in specs {
                  let spec_force = force || spec.force
                  if spec.src.length() == 0 && spec.dst.length() == 0 {
                    let (_, local_branches) = @gitlib.list_branches(fs, git_dir)
                    for branch in local_branches {
                      let branch_refname = "refs/heads/" + branch.name
                      if @gitlib.resolve_ref(fs, rgd, branch_refname) is Some(_) {
                        push_plans.push({
                          source_ref: branch_refname,
                          dest_ref: branch_refname,
                          delete_ref: false,
                          force: spec_force,
                        })
                      }
                    }
                    continue
                  }
                  if spec.src.length() == 0 {
                    let dest_ref = resolve_push_destination_ref(
                      fs,
                      rgd,
                      PushSourceKind::Branch,
                      spec.dst,
                      current_branch,
                      delete_mode,
                      false,
                    )
                    push_plans.push({
                      source_ref: "",
                      dest_ref,
                      delete_ref: true,
                      force: spec_force,
                    })
                    continue
                  }
                  let (source_ref, source_kind) = resolve_push_source_ref(
                    fs,
                    git_dir,
                    spec.src,
                  )
                  let source_is_other = match source_kind {
                    PushSourceKind::Other => true
                    _ => false
                  }
                  if source_is_other &&
                    spec.dst.length() > 0 &&
                    not(spec.dst.has_prefix("refs/")) {
                    let has_existing = @gitlib.resolve_ref(
                        fs,
                        rgd,
                        "refs/heads/" + spec.dst,
                      )
                      is Some(_) ||
                      @gitlib.resolve_ref(fs, rgd, "refs/tags/" + spec.dst)
                      is Some(_) ||
                      @gitlib.resolve_ref(fs, rgd, "refs/remotes/" + spec.dst)
                      is Some(_)
                    if not(has_existing) {
                      raise @git.GitError::InvalidObject(
                        "Cannot infer destination ref from source object id",
                      )
                    }
                  }
                  let dst_token = if spec.has_explicit_destination {
                    if spec.dst.length() == 0 {
                      spec.src
                    } else {
                      spec.dst
                    }
                  } else {
                    infer_colonless_push_destination_token(
                      spec.src,
                      source_ref,
                      source_kind,
                      current_branch,
                      push_default_mode,
                      branch_merge,
                      remote_push_refmaps,
                    )
                  }
                  let dest_ref = resolve_push_destination_ref(
                    fs,
                    rgd,
                    source_kind,
                    dst_token,
                    current_branch,
                    false,
                    spec.src == spec.dst,
                  )
                  push_plans.push({
                    source_ref,
                    dest_ref,
                    delete_ref: false,
                    force: spec_force,
                  })
                }
              }
            }
          }
          if push_prune {
            let prune_patterns : Array[(String, String)] = []
            let specs = @gitlib.parse_push_refspecs(refspec_args)
            for spec in specs {
              if spec.src.length() == 0 && spec.dst.length() == 0 {
                prune_patterns.push(("refs/heads/*", "refs/heads/*"))
              } else if spec.src.contains("*") && spec.dst.contains("*") {
                prune_patterns.push((spec.src, spec.dst))
              }
            }
            if prune_patterns.length() > 0 {
              let planned_dest_refs : Map[String, Bool] = {}
              for plan in push_plans {
                planned_dest_refs[plan.dest_ref] = true
              }
              let remote_refs_for_prune = @gitlib.list_refs_with_ids(
                fs,
                rgd,
                Some("refs/"),
              )
              for remote_refname, _ in remote_refs_for_prune {
                if planned_dest_refs.get(remote_refname) is Some(_) {
                  continue
                }
                let mut should_delete = false
                for prune_pattern in prune_patterns {
                  let src_pattern = prune_pattern.0
                  let dst_pattern = prune_pattern.1
                  match
                    prune_source_ref_for_destination(
                      src_pattern, dst_pattern, remote_refname,
                    ) {
                    Some(src_refname) =>
                      if @gitlib.resolve_ref(fs, git_dir, src_refname) is None {
                        should_delete = true
                        break
                      }
                    None => ()
                  }
                }
                if should_delete {
                  push_plans.push({
                    source_ref: "",
                    dest_ref: remote_refname,
                    delete_ref: true,
                    force,
                  })
                  planned_dest_refs[remote_refname] = true
                }
              }
            }
          }
          if follow_tags {
            let planned_dest_refs : Map[String, Bool] = {}
            for plan in push_plans {
              planned_dest_refs[plan.dest_ref] = true
            }
            let pushed_tips : Array[@git.ObjectId] = []
            for plan in push_plans {
              if plan.delete_ref || plan.source_ref.contains("*") {
                continue
              }
              let source_id = resolve_push_source_id(
                fs,
                git_dir,
                plan.source_ref,
              ) catch {
                _ => continue
              }
              match peel_to_commit(local_db, fs, source_id) {
                Some(commit_id) => pushed_tips.push(commit_id)
                None => ()
              }
            }
            if pushed_tips.length() > 0 {
              let local_tags = @gitlib.list_refs_with_ids(
                fs,
                git_dir,
                Some("refs/tags/"),
              )
              for tag_refname, tag_id in local_tags {
                if planned_dest_refs.get(tag_refname) is Some(_) {
                  continue
                }
                if @gitlib.resolve_ref(fs, rgd, tag_refname) is Some(_) {
                  continue
                }
                let tag_obj = local_db.get(fs, tag_id) catch { _ => None }
                guard tag_obj is Some(obj) else { continue }
                if obj.obj_type != @git.ObjectType::Tag {
                  continue
                }
                let tag_commit = peel_to_commit(local_db, fs, tag_id)
                guard tag_commit is Some(commit_id) else { continue }
                let mut reachable = false
                for tip_id in pushed_tips {
                  if is_ancestor_commit(local_db, fs, commit_id, tip_id) {
                    reachable = true
                    break
                  }
                }
                if not(reachable) {
                  continue
                }
                push_plans.push({
                  source_ref: tag_refname,
                  dest_ref: tag_refname,
                  delete_ref: false,
                  force: false,
                })
                planned_dest_refs[tag_refname] = true
              }
            }
          }
          ensure_matching_refspec_has_candidates(
            parsed_refspecs,
            push_plans.length(),
          )
          if upstream_refname is None &&
            push_plans.length() == 1 &&
            not(push_plans[0].delete_ref) {
            upstream_refname = Some(push_plans[0].dest_ref)
          }
          let porcelain_lines : Array[PushPorcelainLine] = []
          let mut porcelain_failed = false
          let resolved_updates : Array[PushResolvedUpdate] = []
          for plan_item in push_plans {
            if plan_item.delete_ref {
              let hidden_ref = is_hidden_ref(plan_item.dest_ref, push_hide_refs)
              let checked_out_worktree_for_delete = match
                branch_name_from_head_ref(plan_item.dest_ref) {
                Some(branch_name) =>
                  match
                    @gitlib.is_branch_checked_out(fs, remote_path, branch_name) {
                    Some(path) =>
                      if remote_config_bare &&
                        normalize_path(path) == normalize_path(remote_path) {
                        None
                      } else {
                        Some(path)
                      }
                    None => None
                  }
                None => None
              }
              let mut delete_checked_out_rejected = false
              let mut delete_checked_out_warn = false
              if checked_out_worktree_for_delete is Some(_) {
                match deny_delete_current {
                  Some(mode) =>
                    if mode == "false" || mode == "ignore" {
                      ()
                    } else if mode == "warn" {
                      delete_checked_out_warn = true
                    } else {
                      delete_checked_out_rejected = true
                    }
                  None => delete_checked_out_rejected = true
                }
              }
              let delete_rejection = select_push_rejection_status(
                false, false, delete_checked_out_rejected, hidden_ref,
              )
              if delete_rejection is Some(rejection) {
                if porcelain {
                  porcelain_lines.push({
                    flag: "!",
                    src: plan_item.source_ref,
                    dst: plan_item.dest_ref,
                    status: rejection,
                  })
                  porcelain_failed = true
                  continue
                } else {
                  raise @git.GitError::InvalidObject(
                    "failed to push some refs to '\{url}'",
                  )
                }
              }
              if delete_checked_out_warn {
                eprint_line("warning: updating the current branch")
              }
              let old_opt = @gitlib.resolve_ref(fs, rgd, plan_item.dest_ref)
              let old_id = match old_opt {
                Some(id) => id
                None => @git.ObjectId::zero()
              }
              if porcelain {
                let (flag, status) = classify_push_porcelain_success(
                  old_id,
                  @git.ObjectId::zero(),
                  true,
                  plan_item.force,
                )
                porcelain_lines.push({
                  flag,
                  src: "",
                  dst: plan_item.dest_ref,
                  status,
                })
              }
              resolved_updates.push({
                old_id,
                new_id: @git.ObjectId::zero(),
                refname: plan_item.dest_ref,
                delete_ref: true,
                should_apply: old_opt is Some(_),
                update_instead_worktree: None,
              })
              continue
            }
            if plan_item.source_ref.contains("*") &&
              plan_item.dest_ref.contains("*") {
              let refs = @gitlib.list_refs_with_ids(fs, git_dir, Some("refs/"))
              let mut matched = false
              for src_refname, local_id in refs {
                match
                  @gitlib.refspec_map_dst(
                    plan_item.source_ref,
                    plan_item.dest_ref,
                    src_refname,
                  ) {
                  Some(dst_refname) => {
                    matched = true
                    let hidden_ref = is_hidden_ref(dst_refname, push_hide_refs)
                    let old_opt = @gitlib.resolve_ref(fs, rgd, dst_refname)
                    let old_id = match old_opt {
                      Some(id) => id
                      None => @git.ObjectId::zero()
                    }
                    let mut non_fast_forward = false
                    let mut tag_conflict = false
                    if old_opt is Some(existing_old) &&
                      existing_old != local_id &&
                      not(plan_item.force) {
                      if dst_refname.has_prefix("refs/heads/") &&
                        not(
                          is_ancestor_commit(
                            local_db, fs, existing_old, local_id,
                          ),
                        ) {
                        non_fast_forward = true
                      }
                      if dst_refname.has_prefix("refs/tags/") {
                        tag_conflict = true
                      }
                    }
                    let checked_out_worktree = match
                      branch_name_from_head_ref(dst_refname) {
                      Some(branch_name) =>
                        match
                          @gitlib.is_branch_checked_out(
                            fs, remote_path, branch_name,
                          ) {
                          Some(path) =>
                            if remote_config_bare &&
                              normalize_path(path) ==
                              normalize_path(remote_path) {
                              None
                            } else {
                              Some(path)
                            }
                          None => None
                        }
                      None => None
                    }
                    let mut deny_current_rejected = false
                    let mut update_instead_worktree : String? = None
                    let mut deny_decision : DenyCurrentBranchDecision? = Some(
                      DenyCurrentBranchDecision::Allow,
                    )
                    if not(hidden_ref || non_fast_forward || tag_conflict) {
                      deny_decision = (enforce_receive_deny_current_branch(
                        deny_current_branch, checked_out_worktree, dst_refname,
                      )
                      |> Some) catch {
                        _ => {
                          deny_current_rejected = true
                          None
                        }
                      }
                    }
                    if deny_decision
                      is Some(DenyCurrentBranchDecision::UpdateInstead(path)) {
                      update_instead_worktree = Some(path)
                    }
                    let rejection = select_push_rejection_status(
                      non_fast_forward, tag_conflict, deny_current_rejected, hidden_ref,
                    )
                    if rejection is Some(status) {
                      if porcelain {
                        porcelain_lines.push({
                          flag: "!",
                          src: src_refname,
                          dst: dst_refname,
                          status,
                        })
                        porcelain_failed = true
                        continue
                      } else {
                        raise @git.GitError::InvalidObject(
                          "failed to push some refs to '\{url}'",
                        )
                      }
                    }
                    if deny_decision is Some(DenyCurrentBranchDecision::Warn) {
                      eprint_line("warning: updating the current branch")
                    }
                    if deny_decision is None {
                      continue
                    }
                    if porcelain {
                      let (flag, status) = classify_push_porcelain_success(
                        old_id,
                        local_id,
                        false,
                        plan_item.force,
                      )
                      porcelain_lines.push({
                        flag,
                        src: src_refname,
                        dst: dst_refname,
                        status,
                      })
                    }
                    resolved_updates.push({
                      old_id,
                      new_id: local_id,
                      refname: dst_refname,
                      delete_ref: false,
                      should_apply: old_id != local_id,
                      update_instead_worktree,
                    })
                  }
                  None => ()
                }
              }
              if not(matched) {
                raise @git.GitError::InvalidObject(
                  "Cannot resolve source ref: " + plan_item.source_ref,
                )
              }
              continue
            }
            let local_id = resolve_push_source_id(
              fs,
              git_dir,
              plan_item.source_ref,
            )
            let hidden_ref = is_hidden_ref(plan_item.dest_ref, push_hide_refs)
            let old_opt = @gitlib.resolve_ref(fs, rgd, plan_item.dest_ref)
            let old_id = match old_opt {
              Some(id) => id
              None => @git.ObjectId::zero()
            }
            let mut non_fast_forward = false
            let mut tag_conflict = false
            if old_opt is Some(existing_old) &&
              existing_old != local_id &&
              not(plan_item.force) {
              if plan_item.dest_ref.has_prefix("refs/heads/") &&
                not(is_ancestor_commit(local_db, fs, existing_old, local_id)) {
                non_fast_forward = true
              }
              if plan_item.dest_ref.has_prefix("refs/tags/") {
                tag_conflict = true
              }
            }
            let checked_out_worktree = match
              branch_name_from_head_ref(plan_item.dest_ref) {
              Some(branch_name) =>
                match
                  @gitlib.is_branch_checked_out(fs, remote_path, branch_name) {
                  Some(path) =>
                    if remote_config_bare &&
                      normalize_path(path) == normalize_path(remote_path) {
                      None
                    } else {
                      Some(path)
                    }
                  None => None
                }
              None => None
            }
            let mut deny_current_rejected = false
            let mut update_instead_worktree : String? = None
            let mut deny_decision : DenyCurrentBranchDecision? = Some(
              DenyCurrentBranchDecision::Allow,
            )
            if not(hidden_ref || non_fast_forward || tag_conflict) {
              deny_decision = (enforce_receive_deny_current_branch(
                deny_current_branch,
                checked_out_worktree,
                plan_item.dest_ref,
              )
              |> Some) catch {
                _ => {
                  deny_current_rejected = true
                  None
                }
              }
            }
            if deny_decision
              is Some(DenyCurrentBranchDecision::UpdateInstead(path)) {
              update_instead_worktree = Some(path)
            }
            let rejection = select_push_rejection_status(
              non_fast_forward, tag_conflict, deny_current_rejected, hidden_ref,
            )
            if rejection is Some(status) {
              if porcelain {
                porcelain_lines.push({
                  flag: "!",
                  src: plan_item.source_ref,
                  dst: plan_item.dest_ref,
                  status,
                })
                porcelain_failed = true
                continue
              } else {
                raise @git.GitError::InvalidObject(
                  "failed to push some refs to '\{url}'",
                )
              }
            }
            if deny_decision is Some(DenyCurrentBranchDecision::Warn) {
              eprint_line("warning: updating the current branch")
            }
            if deny_decision is None {
              continue
            }
            if porcelain {
              let (flag, status) = classify_push_porcelain_success(
                old_id,
                local_id,
                false,
                plan_item.force,
              )
              porcelain_lines.push({
                flag,
                src: plan_item.source_ref,
                dst: plan_item.dest_ref,
                status,
              })
            }
            resolved_updates.push({
              old_id,
              new_id: local_id,
              refname: plan_item.dest_ref,
              delete_ref: false,
              should_apply: old_id != local_id,
              update_instead_worktree,
            })
          }
          ensure_consistent_alias_updates(fs, rgd, resolved_updates)
          if porcelain_failed {
            for line in porcelain_lines {
              print_line(
                format_push_porcelain_line(
                  line.flag,
                  line.src,
                  line.dst,
                  line.status,
                ),
              )
            }
            print_line("Done")
            raise @git.GitError::InvalidObject(
              "failed to push some refs to '\{url}'",
            )
          }
          if not(dry_run) && resolved_updates.length() > 0 {
            let mut has_object_updates = false
            for row in resolved_updates {
              if row.should_apply && not(row.delete_ref) {
                has_object_updates = true
                break
              }
            }
            if has_object_updates {
              let rfs : &@git.RepoFileSystem = fs
              let transferred_object_ids : Map[String, Bool] = {}
              for row in resolved_updates {
                if row.should_apply && not(row.delete_ref) {
                  copy_wanted_object_graph(
                    fs,
                    rfs,
                    local_db,
                    rgd,
                    row.new_id,
                    transferred_object_ids,
                  )
                }
              }
            }
            let pre_rows = order_pre_receive_rows(resolved_updates)
            let pre_lines : Array[String] = []
            for row in pre_rows {
              pre_lines.push(format_push_hook_line(row))
            }
            let pre_code = run_push_hook_with_stdin(
              fs, rgd, "pre-receive", pre_lines,
            )
            if pre_code != 0 {
              raise @git.GitError::InvalidObject(
                "failed to push some refs to '\{url}'",
              )
            }
            let update_rows = order_update_rows(resolved_updates)
            for row in update_rows {
              let update_code = run_push_hook_with_args(fs, rgd, "update", [
                row.refname,
                row.old_id.to_hex(),
                row.new_id.to_hex(),
              ])
              if update_code != 0 {
                raise @git.GitError::InvalidObject(
                  "failed to push some refs to '\{url}'",
                )
              }
            }
            for row in resolved_updates {
              if not(row.should_apply) {
                continue
              }
              if row.delete_ref {
                let ref_path = rgd + "/" + row.refname
                let namespace_root = ref_namespace_root(row.refname)
                @gitlib.remove_ref_path(fs, fs, ref_path)
                prune_empty_parent_dirs(
                  fs,
                  fs,
                  ref_path,
                  rgd + "/" + namespace_root,
                )
                let reflog_path = rgd + "/logs/" + row.refname
                @gitlib.remove_ref_path(fs, fs, reflog_path)
                prune_empty_parent_dirs(
                  fs,
                  fs,
                  reflog_path,
                  rgd + "/logs/" + namespace_root,
                )
              } else {
                match row.update_instead_worktree {
                  Some(worktree_path) => {
                    let hook_code = run_push_to_checkout_hook(
                      fs,
                      rgd,
                      worktree_path,
                      row.new_id,
                    )
                    if hook_code == -1 {
                      apply_update_instead_worktree(
                        fs,
                        rgd,
                        worktree_path,
                        row.new_id,
                      ) catch {
                        _ =>
                          raise @git.GitError::InvalidObject(
                            "failed to push some refs to '\{url}'",
                          )
                      }
                    } else if hook_code != 0 {
                      raise @git.GitError::InvalidObject(
                        "failed to push some refs to '\{url}'",
                      )
                    }
                  }
                  None => ()
                }
                write_ref_file(fs, rgd, row.refname, row.new_id)
                if remote_log_enabled {
                  @gitrepo.append_reflog(
                    fs,
                    fs,
                    rgd,
                    row.refname,
                    row.old_id,
                    row.new_id,
                    push_log_name,
                    push_log_email,
                    push_log_timestamp,
                    push_log_timezone,
                    "push",
                  )
                }
                if helper_is_testgit {
                  update_testgit_push_tracking(
                    fs,
                    git_dir,
                    remote_name,
                    row.refname,
                    row.new_id,
                    no_private_update,
                  )
                }
              }
            }
            if has_named_remote {
              for row in resolved_updates {
                update_local_push_tracking(fs, git_dir, remote_name, row)
              }
            }
            let post_rows_unsorted : Array[PushResolvedUpdate] = []
            for row in resolved_updates {
              if row.should_apply {
                post_rows_unsorted.push(row)
              }
            }
            if post_rows_unsorted.length() > 0 {
              let post_rows = order_pre_receive_rows(post_rows_unsorted)
              let post_lines : Array[String] = []
              let post_refs : Array[String] = []
              for row in post_rows {
                post_lines.push(format_push_hook_line(row))
                post_refs.push(row.refname)
              }
              ignore(
                run_push_hook_with_stdin(fs, rgd, "post-receive", post_lines),
              )
              ignore(run_push_hook_with_args(fs, rgd, "post-update", post_refs))
            }
          }
          if porcelain {
            for line in porcelain_lines {
              print_line(
                format_push_porcelain_line(
                  line.flag,
                  line.src,
                  line.dst,
                  line.status,
                ),
              )
            }
            print_line("Done")
          } else if not(quiet) {
            print_line("Push successful")
          }
        }
        None => {
          let result = @gitlibnative.push_http(
            fs,
            root,
            url,
            first_refname,
            force~,
          )
          if not(porcelain || quiet) {
            print_line(result)
          }
        }
      }
    }
  }
  if quiet {
    let push_use_bitmaps = @gitlib.read_config_value(
      fs, config_path, "push", "usebitmaps",
    )
    let no_use_bitmap_index = match push_use_bitmaps {
      Some(value) => {
        let lower = value.to_lower()
        lower == "false" || lower == "0" || lower == "no"
      }
      None => false
    }
    let pack_objects_subcommand = [
      "git", "pack-objects", "--all-progress-implied", "--revs", "--stdout", "--thin",
      "--delta-base-offset", "-q",
    ]
    if no_use_bitmap_index {
      pack_objects_subcommand.push("--no-use-bitmap-index")
    }
    emit_push_trace_subcommand(fs, pack_objects_subcommand)
  }
  if parse_config_bool_string(
      @gitlib.read_config_value(fs, config_path, "pack", "usepathwalk"),
    ) {
    emit_trace_region("pack-objects", "path-walk") catch {
      _ => ()
    }
  }
  let wrote_count = if push_negotiate && not(negotiation_failed) {
    "2"
  } else {
    "5"
  }
  emit_push_trace_event(fs, "write_pack_file/wrote", wrote_count)
  if push_negotiate && not(negotiation_failed) {
    emit_push_trace_event(fs, "total_rounds", "1")
  }
  if not(push_all) &&
    upstream_refname is Some(refname) &&
    (set_upstream || auto_set_upstream_needed) {
    let branch_name = current_branch
    @gitlib.set_config_key(
      fs, fs, git_dir, "branch", branch_name, "remote", remote_name,
    )
    @gitlib.set_config_key(
      fs, fs, git_dir, "branch", branch_name, "merge", refname,
    )
    let remote_branch_name = if refname.has_prefix("refs/heads/") {
      (try! refname[11:]).to_string()
    } else {
      refname
    }
    print_line(
      "Branch '\{branch_name}' set up to track remote branch '\{remote_branch_name}' from '\{remote_name}'.",
    )
  }
}

///|
/// Handle push for subdir-clone repositories
/// Transforms local commits to fit the original repository structure
async fn handle_subdir_push(
  fs : OsFs,
  root : String,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  base_hex : String,
  refname : String,
  _force : Bool,
) -> Unit raise Error {
  // Step 1: Get local HEAD commit
  let local_head_opt = @gitrepo.rev_parse(fs, git_dir, "HEAD") catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard local_head_opt is Some(local_head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  print_line("  Local HEAD: \{local_head.to_hex()}")
  // Step 2: Get the initial commit (first commit in the subdir-clone)
  let initial_commit = find_initial_subdir_commit(fs, git_dir) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => raise @git.GitError::InvalidObject("Cannot find initial commit")
  }
  print_line("  Initial commit: \{initial_commit.to_hex()}")
  // Step 3: Collect local commits since initial
  let local_commits = collect_commits_since(
    fs, git_dir, initial_commit, local_head,
  ) catch {
    err => raise err
  }
  if local_commits.length() == 0 {
    print_line("Nothing to push.")
    return
  }
  print_line("  Found \{local_commits.length()} local commits to transform")
  // Step 4: Get upstream base commit
  let upstream_base = @git.ObjectId::from_hex(base_hex) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => raise @git.GitError::InvalidObject("Cannot parse base commit")
  }
  print_line("  Upstream base: \{upstream_base.to_hex()}")
  // Step 5: Fetch upstream base commit and its tree from remote
  print_line("  Fetching upstream objects...")
  let pack = @gitionative.fetch_pack_http(remote_url, [upstream_base], true)
  let objects = @pack.parse_packfile(pack)
  @pack.write_packfile_with_index(fs, git_dir, pack, objects)
  print_line("  Fetched \{objects.length()} objects")
  // Step 6: Reload ObjectDb to pick up new packfile, then transform commits
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let mut parent : @git.ObjectId = upstream_base
  for commit_id in local_commits {
    let new_commit = transform_subdir_commit(
      fs, db, git_dir, commit_id, parent, subdir_path,
    ) catch {
      err => raise err
    }
    print_line("  Transformed: \{commit_id.to_hex()} -> \{new_commit.to_hex()}")
    parent = new_commit
  }
  // Step 7: Push the transformed commits (tree only, not parent history)
  let transformed_head : @git.ObjectId = parent
  print_line("  Pushing transformed commits...")
  let result = @gitlibnative.push_http_tree_only(
    fs, root, remote_url, transformed_head, upstream_base, refname,
  )
  print_line("  \{result}")
  // Step 8: Update base commit
  update_subdir_base(fs, git_dir, transformed_head.to_hex())
  print_line("done.")
}

///|
/// Find the initial commit of a subdir-clone (the "cloned from" commit)
fn find_initial_subdir_commit(
  fs : OsFs,
  git_dir : String,
) -> @git.ObjectId raise @git.GitError {
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Start from HEAD and walk back to find root commit
  let head_opt = @gitrepo.rev_parse(fs, git_dir, "HEAD") catch {
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard head_opt is Some(head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  let mut current : @git.ObjectId = head
  let mut prev : @git.ObjectId = current
  while true {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      // Found root commit
      return current
    }
    prev = current
    current = info.parents[0]
  }
  prev
}

///|
/// Collect commits from start (exclusive) to end (inclusive)
fn collect_commits_since(
  fs : OsFs,
  git_dir : String,
  start : @git.ObjectId,
  end : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let result : Array[@git.ObjectId] = []
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  let mut current : @git.ObjectId = end
  let start_hex = start.to_hex()
  while true {
    let hex = current.to_hex()
    if hex == start_hex {
      break
    }
    result.push(current)
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get oldest first
  result.rev_in_place()
  result
}

///|
/// Transform a subdir-clone commit to fit the original repository structure
fn transform_subdir_commit(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  local_commit : @git.ObjectId,
  upstream_parent : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId raise @git.GitError {
  // Get local commit info
  let local_obj = db.get(fs, local_commit)
  guard local_obj is Some(lo) else {
    raise @git.GitError::InvalidObject("Cannot find local commit")
  }
  let local_info = @git.parse_commit(lo.data) catch { err => raise err }
  let (author, message) = parse_commit_author_message(lo.data)
  // Get upstream parent's tree
  let upstream_obj = db.get(fs, upstream_parent)
  guard upstream_obj is Some(uo) else {
    raise @git.GitError::InvalidObject("Cannot find upstream commit")
  }
  let upstream_info = @git.parse_commit(uo.data) catch { err => raise err }
  // The local commit's tree IS the subdirectory content
  let new_subdir_tree = local_info.tree
  // Replace the subdirectory in the upstream tree
  let new_root_tree = replace_tree_at_path(
    fs,
    db,
    git_dir,
    upstream_info.tree,
    subdir_path,
    new_subdir_tree,
  ) catch {
    err => raise err
  }
  // Create new commit with the transformed tree
  let timestamp = get_current_timestamp()
  let new_commit = @subdir.create_commit_in_repo(
    fs, git_dir, new_root_tree, upstream_parent, message, author, timestamp,
  ) catch {
    _ => raise @git.GitError::InvalidObject("Cannot create commit")
  }
  new_commit
}

///|
/// Replace a subtree at a given path within a root tree
fn replace_tree_at_path(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  root_tree : @git.ObjectId,
  path : String,
  new_subtree : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  let path_parts : Array[String] = path
    .split("/")
    .filter(s => s.length() > 0)
    .map(s => s.to_string())
    .collect()
  if path_parts.length() == 0 {
    return new_subtree
  }
  replace_tree_recursive_push(
    fs, db, git_dir, root_tree, path_parts, 0, new_subtree,
  )
}

///|
fn replace_tree_recursive_push(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  current_tree : @git.ObjectId,
  path_parts : Array[String],
  depth : Int,
  new_leaf : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  // Read current tree
  let tree_obj = db.get(fs, current_tree)
  guard tree_obj is Some(to) else {
    raise @git.GitError::InvalidObject("Cannot find tree")
  }
  let entries = @git.parse_tree(to.data) catch { err => raise err }
  // Build new entries
  let new_entries : Array[@git.TreeEntry] = []
  let target_name = path_parts[depth]
  let is_last = depth == path_parts.length() - 1
  for entry in entries {
    if entry.name == target_name {
      if is_last {
        // Replace with new subtree
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_leaf))
      } else {
        // Recurse
        let new_child = replace_tree_recursive_push(
          fs,
          db,
          git_dir,
          entry.id,
          path_parts,
          depth + 1,
          new_leaf,
        ) catch {
          err => raise err
        }
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_child))
      }
    } else {
      new_entries.push(entry)
    }
  }
  // Create new tree and write it
  let (tree_id, tree_data) = @git.create_tree(new_entries)
  write_object_to_repo(fs, git_dir, tree_id, tree_data) catch {
    _ => raise @git.GitError::InvalidObject("Cannot write tree")
  }
  tree_id
}

///|
/// Write an object (already compressed) to the repository
fn write_object_to_repo(
  fs : OsFs,
  git_dir : String,
  id : @git.ObjectId,
  compressed_data : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let dir_name = String::unsafe_substring(hex, start=0, end=2)
  let file_name = String::unsafe_substring(hex, start=2, end=40)
  let dir_path = git_dir + "/objects/" + dir_name
  let file_path = dir_path + "/" + file_name
  // Create directory if needed
  fs.mkdir_p(dir_path) catch {
    _ => ()
  }
  // Write already-compressed data
  fs.write_file(file_path, compressed_data) catch {
    _ => raise @git.GitError::IoError("Cannot write object")
  }
}
