///|
async fn handle_cat(args : Array[String]) -> Unit raise Error {
  let positional : Array[String] = []
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("cat", arg)
    } else {
      positional.push(arg)
    }
  }
  guard positional.length() > 0 else {
    print_cat_usage()
    return ()
  }
  let spec = positional[0]
  let fs = OsFs::new()
  match check_shorthand_ambiguity(spec, p => fs.is_dir(p)) {
    Some(conflict_path) =>
      raise @git.GitError::InvalidObject(
        "Ambiguous: '\{conflict_path}' exists locally. Use full URL or ./\{spec} for local path.",
      )
    None => ()
  }
  let shorthand = parse_github_shorthand(spec)
  match shorthand {
    Some(File(raw_url, _filename)) => {
      let headers : Map[String, String] = {}
      let (response, content) = @gitionative.native_http_get(raw_url, headers)
      if response.code != 200 {
        raise @git.GitError::InvalidObject(
          "HTTP \{response.code}: failed to fetch \{raw_url}",
        )
      }
      @stdio.stdout.write(content)
      return ()
    }
    _ => ()
  }
  let (remote_url, raw_path, ref_spec) = match shorthand {
    Some(Repo(url, refname)) =>
      if positional.length() >= 2 {
        (url, positional[1], refname)
      } else {
        raise @git.GitError::InvalidObject("path required")
      }
    Some(Subdir(url, subpath, refname)) => (url, subpath, refname)
    Some(File(_url, _)) =>
      raise @git.GitError::InvalidObject(
        "unexpected file shorthand; use 'bit cat <repo>:<path>'",
      )
    None =>
      if spec.has_prefix("https://") || spec.has_prefix("http://") {
        if positional.length() >= 2 {
          (spec, positional[1], None)
        } else {
          raise @git.GitError::InvalidObject("path required")
        }
      } else if spec.has_prefix("git@") {
        raise @git.GitError::InvalidObject(
          "SSH URLs are not supported; use https://",
        )
      } else {
        raise @git.GitError::InvalidObject(
          "repository shorthand required (e.g., mizchi/bit:README.md)",
        )
      }
  }
  let path = @gitlib.normalize_repo_path(raw_path)
  let temp_dir = make_temp_dir(fs, "bit-cat")
  try {
    let _ = @gitnative.clone_http_to_fs(
      remote_url,
      true,
      fs,
      temp_dir,
      depth=1,
      filter=@protocol.FilterSpec::BlobNone,
    )
    let git_dir = temp_dir + "/.git"
    let commit_id = match ref_spec {
      Some(refname) => {
        let resolved = resolve_remote_ref_id(remote_url, refname)
        guard resolved is Some((id, _)) else {
          raise @git.GitError::InvalidObject("Unknown ref: " + refname)
        }
        id
      }
      None => {
        let head_id = @gitrepo.rev_parse(fs, git_dir, "HEAD")
        guard head_id is Some(id) else {
          raise @git.GitError::InvalidObject("HEAD not found")
        }
        id
      }
    }
    let mut db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
    if db.get(fs, commit_id) is None {
      let pack = @gitnative.fetch_pack_http(remote_url, [commit_id], true)
      let objects = @pack.parse_packfile(pack)
      @pack.write_packfile_with_index(fs, git_dir, pack, objects)
      db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
    }
    let tree_id = resolve_to_tree(db, fs, commit_id)
    let entry = @gitlib.find_tree_entry(db, fs, tree_id, path)
    guard entry is Some(found) else {
      raise @git.GitError::InvalidObject("path not found: " + path)
    }
    let is_tree = found.mode == "40000" || found.mode == "040000"
    let is_submodule = found.mode == "160000"
    if is_tree {
      raise @git.GitError::InvalidObject("path is a tree: " + path)
    }
    if is_submodule {
      raise @git.GitError::InvalidObject("path is a submodule: " + path)
    }
    let mut obj = db.get(fs, found.id)
    if obj is None {
      let wants : Array[@git.ObjectId] = [found.id]
      let pack = @gitnative.fetch_pack_http(remote_url, wants, true)
      let objects = @pack.parse_packfile(pack)
      @pack.write_packfile_with_index(fs, git_dir, pack, objects)
      let db2 = @gitlib.ObjectDb::load_lazy(fs, git_dir)
      obj = db2.get(fs, found.id)
    }
    guard obj is Some(blob) else {
      raise @git.GitError::InvalidObject("blob not found: " + path)
    }
    @stdio.stdout.write(blob.data)
  } catch {
    err => {
      remove_dir_recursive(fs, temp_dir)
      raise err
    }
  }
  remove_dir_recursive(fs, temp_dir)
}
