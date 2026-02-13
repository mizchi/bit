///| Branch handlers: branch, checkout, switch, reset, rebase, stash, cherry-pick

///|
fn is_reftable_repo_for_branch(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Bool {
  if fs.is_dir(git_dir + "/reftable") {
    return true
  }
  match
    @gitlib.read_config_value(
      fs,
      git_dir + "/config",
      "extensions",
      "refstorage",
    ) {
    Some(value) => value.to_lower() == "reftable"
    None => false
  }
}

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
  let mut rename_current = false
  let mut rename_force = false
  let mut force_delete = false
  let mut show_all = false
  let mut show_remotes = false
  let mut verbose = false
  let mut set_upstream_to : String? = None
  let mut track_upstream = false
  let mut start_point : String? = None
  let mut i = 0
  if is_real_git_delegate_enabled() || is_reftable_repo_for_branch(fs, git_dir) {
    delegate_to_real_git("branch", args)
  }
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
      "-m" | "-M" if i + 1 < args.length() => {
        rename_current = true
        rename_to = Some(args[i + 1])
        rename_force = arg == "-M"
        list_mode = false
        i += 2
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
              if from_name == to_name {
                ()
              } else {
                @gitlib.rename_branch(
                  fs,
                  fs,
                  root,
                  from_name,
                  to_name,
                  force=rename_force,
                )
              }
            None => ()
          }
        None =>
          if rename_current {
            match rename_to {
              Some(to_name) => {
                let current = get_current_branch(fs, git_dir)
                if current != to_name {
                  @gitlib.rename_branch(
                    fs,
                    fs,
                    root,
                    current,
                    to_name,
                    force=rename_force,
                  )
                }
              }
              None => ()
            }
          } else {
            match new_branch {
              Some(name) => {
                match start_point {
                  Some(sp) => {
                    let commit_id = @gitrepo.rev_parse(fs, git_dir, sp)
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
}

///|
