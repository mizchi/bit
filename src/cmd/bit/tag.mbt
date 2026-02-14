///|
async fn handle_tag(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  if real_git_delegate_is_available(rfs) {
    delegate_to_real_git("tag", args)
    return ()
  }
  let git_dir = resolve_git_dir(rfs, root)
  let mut list_mode = true
  let mut delete_mode = false
  let mut annotated = false
  let mut force = false
  let delete_tags : Array[String] = []
  let mut message : String? = None
  let mut tag_name : String? = None
  let mut target : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-l" | "--list" => list_mode = true
      "-d" | "--delete" => {
        delete_mode = true
        list_mode = false
      }
      "-a" | "--annotate" => {
        annotated = true
        list_mode = false
      }
      "-f" | "--force" => {
        force = true
        list_mode = false
      }
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        annotated = true
        list_mode = false
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) =>
        if delete_mode {
          delete_tags.push(arg)
          list_mode = false
        } else if tag_name is None {
          tag_name = Some(arg)
          list_mode = false
        } else if target is None {
          target = Some(arg)
        }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("tag", arg)
      _ => ()
    }
    i += 1
  }
  if delete_mode {
    guard delete_tags.length() > 0 else {
      raise @git.GitError::InvalidObject("tag name required for delete")
    }
    for name in delete_tags {
      @gitlib.delete_tag(fs, git_dir, name)
      print_line("Deleted tag '\{name}'")
    }
    return ()
  }
  if list_mode {
    let tags = @gitlib.list_tags(fs, git_dir)
    tags.sort()
    for tag in tags {
      print_line(tag)
    }
    return ()
  }
  guard tag_name is Some(name) else {
    raise @git.GitError::InvalidObject("tag name required")
  }
  // Resolve target (default to HEAD)
  let target_ref = target.unwrap_or("HEAD")
  let commit_id = @gitrepo.rev_parse(fs, git_dir, target_ref)
  guard commit_id is Some(id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{target_ref}")
  }
  if force {
    if @gitlib.resolve_ref(fs, git_dir, "refs/tags/" + name) is Some(_) {
      @gitlib.delete_tag(fs, git_dir, name)
    }
  }
  if annotated {
    let msg = message.unwrap_or("")
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    let timezone = get_commit_timezone()
    @gitlib.create_annotated_tag(
      fs,
      fs,
      git_dir,
      name,
      id,
      msg,
      author,
      timestamp,
      timezone~,
    )
  } else {
    @gitlib.create_lightweight_tag(fs, git_dir, name, id)
  }
}

///|
