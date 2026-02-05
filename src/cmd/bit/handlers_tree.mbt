///| Tree/cat handlers for remote repository browsing (porcelain)

///|
fn print_tree_usage() -> Unit {
  println("usage: bit tree [<options>] <repo>[:<path>] [<pathspec>...]")
  println("")
  println("List tree entries from a remote repository in porcelain format.")
  println("")
  println("Options:")
  println("  --blob                Show porcelain details (mode/type/oid)")
  println("  -r, --recursive       Recurse into subdirectories (default)")
  println("  --no-recursive        Do not recurse")
  println("  --name-only           Show only names")
  println("  -t                    Show tree entries when recursing")
  println("  -d                    Show only tree entries")
  println("")
  println("Examples:")
  println("  bit tree mizchi/bit")
  println("  bit tree mizchi/bit:src/x")
  println("  bit tree mizchi/bit@<rev>:src/x")
  println("  bit tree mizchi/bit src/x --name-only")
}

///|
fn print_cat_usage() -> Unit {
  println("usage: bit cat <repo>:<path>")
  println("")
  println("Show file contents from a remote repository.")
  println("")
  println("Examples:")
  println("  bit cat mizchi/bit:README.md")
  println("  bit cat mizchi/bit@<rev>:README.md")
}

///|
fn temp_root_dir() -> String {
  match @sys.get_env_var("TMPDIR") {
    Some(dir) =>
      if dir.has_suffix("/") && dir.length() > 1 {
        (try! dir[:dir.length() - 1]).to_string()
      } else {
        dir
      }
    None =>
      match @sys.get_env_var("TMP") {
        Some(dir) => dir
        None => "/tmp"
      }
  }
}

///|
fn make_temp_dir(fs : OsFs, prefix : String) -> String raise @git.GitError {
  let base = temp_root_dir() + "/" + prefix + "-" + "\{get_current_timestamp()}"
  let mut candidate = base
  let mut i = 0
  while fs.is_dir(candidate) || fs.is_file(candidate) {
    i += 1
    candidate = base + "-" + "\{i}"
  }
  fs.mkdir_p(candidate) catch {
    _ => raise @git.GitError::IoError("Failed to create temp dir: " + candidate)
  }
  candidate
}

///|
async fn handle_tree(args : Array[String]) -> Unit raise Error {
  let mut recursive = true
  let mut show_trees = false
  let mut only_trees = false
  let mut name_only = true
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "--blob" => name_only = false
      "-r" | "--recursive" => recursive = true
      "--no-recursive" => recursive = false
      "-t" => show_trees = true
      "-d" => only_trees = true
      "--name-only" | "--name-status" => name_only = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("tree", arg)
      _ => positional.push(arg)
    }
  }
  guard positional.length() > 0 else {
    print_tree_usage()
    return ()
  }
  let spec = positional[0]
  let fs = OsFs::new()
  match check_shorthand_ambiguity(spec, fn(p) { fs.is_dir(p) }) {
    Some(conflict_path) =>
      raise @git.GitError::InvalidObject(
        "Ambiguous: '\{conflict_path}' exists locally. Use full URL or ./\{spec} for local path.",
      )
    None => ()
  }
  let (remote_url, path_from_spec, ref_spec) = match
    parse_github_shorthand(spec) {
    Some(Repo(url, refname)) => (url, None, refname)
    Some(Subdir(url, subpath, refname)) => (url, Some(subpath), refname)
    Some(File(_url, _)) =>
      raise @git.GitError::InvalidObject(
        "tree does not accept file URLs; use 'bit cat' instead",
      )
    None =>
      if spec.has_prefix("https://") || spec.has_prefix("http://") {
        (spec, None, None)
      } else if spec.has_prefix("git@") {
        raise @git.GitError::InvalidObject(
          "SSH URLs are not supported; use https://",
        )
      } else {
        // Fallback to local ls-tree behavior
        let local_args : Array[String] = []
        if recursive {
          local_args.push("-r")
        }
        if show_trees {
          local_args.push("-t")
        }
        if only_trees {
          local_args.push("-d")
        }
        if name_only {
          local_args.push("--name-only")
        }
        local_args.append(positional)
        return handle_ls_tree(local_args)
      }
  }
  let path_filters : Array[String] = []
  match path_from_spec {
    Some(path) => path_filters.push(path)
    None => ()
  }
  if positional.length() > 1 {
    for i in 1..<positional.length() {
      path_filters.push(positional[i])
    }
  }
  let normalized_filters = normalize_ls_tree_filters(path_filters, "")
  let temp_dir = make_temp_dir(fs, "bit-tree")
  try {
    let _ = @gitnative.clone_http_to_fs(
      remote_url,
      true,
      fs,
      temp_dir,
      depth=1,
      filter=@git.FilterSpec::BlobNone,
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
        let head_id = @gitlib.rev_parse(fs, git_dir, "HEAD")
        guard head_id is Some(id) else {
          raise @git.GitError::InvalidObject("HEAD not found")
        }
        id
      }
    }
    let mut db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
    if db.get(fs, commit_id) is None {
      let pack = @gitnative.fetch_pack_http(remote_url, [commit_id], true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
      db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
    }
    let tree_id = resolve_to_tree(db, fs, commit_id)
    print_tree_entries(
      db,
      fs,
      tree_id,
      "",
      recursive,
      show_trees,
      only_trees,
      name_only,
      false,
      "",
      [],
      "",
      normalized_filters,
    )
  } catch {
    err => {
      remove_dir_recursive(fs, temp_dir)
      raise err
    }
  }
  remove_dir_recursive(fs, temp_dir)
}

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
  match check_shorthand_ambiguity(spec, fn(p) { fs.is_dir(p) }) {
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
      let (response, content) = @gitnative.native_http_get(raw_url, headers)
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
      filter=@git.FilterSpec::BlobNone,
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
        let head_id = @gitlib.rev_parse(fs, git_dir, "HEAD")
        guard head_id is Some(id) else {
          raise @git.GitError::InvalidObject("HEAD not found")
        }
        id
      }
    }
    let mut db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
    if db.get(fs, commit_id) is None {
      let pack = @gitnative.fetch_pack_http(remote_url, [commit_id], true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
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
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
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
