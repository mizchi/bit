///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let cwd_abs = @sys.get_env_var("PWD").unwrap_or(root)
  let abs_git_dir = if git_dir.has_prefix("/") {
    git_dir
  } else if git_dir == "." {
    cwd_abs
  } else {
    cwd_abs + "/" + git_dir
  }
  let mut revs_only = false
  let mut verify = false
  let mut quiet = false
  for arg in args {
    match arg {
      "--revs-only" => revs_only = true
      "--verify" => verify = true
      "--quiet" => quiet = true
      _ => ()
    }
  }
  ignore(verify)
  ignore(quiet)
  for arg in args {
    match arg {
      "--git-dir" => print_line(git_dir)
      "--absolute-git-dir" => print_line(abs_git_dir)
      "--show-toplevel" => {
        let abs = if root == "." {
          @sys.get_env_var("PWD").unwrap_or(root)
        } else {
          root
        }
        print_line(abs)
      }
      "--revs-only" => ()
      "--verify" => ()
      "--quiet" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rev-parse", arg)
      _ => {
        let id = @gitrepo.rev_parse(fs, git_dir, arg)
        match id {
          Some(oid) => print_line(oid.to_hex())
          None =>
            if not(revs_only) {
              raise @git.GitError::InvalidObject("unknown revision: " + arg)
            }
        }
      }
    }
  }
}

///|
fn peel_cat_file_object_to_type(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  object_id : @git.ObjectId,
  expected_type : @git.ObjectType,
) -> Bytes raise @git.GitError {
  let mut current_id = object_id
  for _ in 0..<8 {
    let current_obj = db.get(fs, current_id)
    guard current_obj is Some(current) else {
      raise @git.GitError::InvalidObject(
        "Object not found: " + current_id.to_hex(),
      )
    }
    if current.obj_type == expected_type {
      return current.data
    }
    guard current.obj_type == @git.ObjectType::Tag else {
      raise @git.GitError::InvalidObject(
        "object is of type \{current.obj_type.to_string()}, not \{expected_type.to_string()}",
      )
    }
    let tag_target = parse_tag_object(decode_bytes(current.data)) catch {
      _ => None
    }
    guard tag_target is Some(target_id) else {
      raise @git.GitError::InvalidObject("malformed tag object")
    }
    current_id = target_id
  }
  raise @git.GitError::InvalidObject("tag dereference depth exceeded")
}

///|
