///|

///|
async fn show_init_command_help() -> Unit {
  show_simple_command_help(
    "git init [<options>] [<directory>]",
    summary="Create an empty Git repository or reinitialize an existing one.",
  )
}

///|
async fn handle_init(args : Array[String]) -> Unit raise Error {
  let root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("GIT_WORK_TREE") {
        Some(dir) => dir
        None => @sys.get_env_var("GIT_SHIM_PWD").unwrap_or(".")
      }
  }
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let wants_bit_layout = args.iter().any(arg => arg == "--bit")
  if not(wants_bit_layout) && real_git_delegate_is_available(rfs) {
    delegate_to_real_git("init", args)
    return ()
  }
  // Parse options
  let mut bare = false
  let mut quiet = false
  let mut initial_branch : String? = None
  let mut target_dir : String? = None
  let mut separate_git_dir : String? = None
  let mut template_dir : String? = None
  let default_ref_format = match
    @sys.get_env_var("GIT_TEST_DEFAULT_REF_FORMAT") {
    Some(value) => {
      let normalized = value.to_lower()
      if normalized == "reftable" {
        "reftable"
      } else {
        "files"
      }
    }
    None => "files"
  }
  let mut ref_format = default_ref_format
  let mut ref_format_explicit = false
  let mut object_format : String? = None
  let mut object_format_explicit = false
  let mut shared_mode : String? = None
  let mut use_bit = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--bare" => bare = true
      "--bit" => use_bit = true
      "-q" | "--quiet" => quiet = true
      "-b" if i + 1 < args.length() => {
        initial_branch = Some(args[i + 1])
        i += 1
      }
      "--separate-git-dir" if i + 1 < args.length() => {
        separate_git_dir = Some(args[i + 1])
        i += 1
      }
      "--template" if i + 1 < args.length() => {
        template_dir = Some(args[i + 1])
        i += 1
      }
      "--shared" =>
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          shared_mode = Some(args[i + 1])
          i += 1
        } else {
          shared_mode = Some("group")
        }
      "--ref-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "files" && value != "reftable" {
          eprint_line("fatal: unknown ref storage format '\{value}'")
          @sys.exit(128)
        }
        ref_format = value
        ref_format_explicit = true
        i += 1
      }
      "--object-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "sha1" && value != "sha256" {
          eprint_line("fatal: unknown hash algorithm '\{value}'")
          @sys.exit(128)
        }
        object_format = Some(value)
        object_format_explicit = true
        i += 1
      }
      _ if arg.has_prefix("--initial-branch=") =>
        initial_branch = Some((try! arg[17:]).to_string())
      _ if arg.has_prefix("--separate-git-dir=") =>
        separate_git_dir = Some((try! arg[19:]).to_string())
      _ if arg.has_prefix("--template=") =>
        template_dir = Some((try! arg[11:]).to_string())
      _ if arg.has_prefix("--shared=") =>
        shared_mode = Some((try! arg[9:]).to_string())
      _ if arg.has_prefix("--ref-format=") => {
        let value = (try! arg[13:]).to_string().to_lower()
        if value != "files" && value != "reftable" {
          eprint_line("fatal: unknown ref storage format '\{value}'")
          @sys.exit(128)
        }
        ref_format = value
        ref_format_explicit = true
      }
      _ if arg.has_prefix("--object-format=") => {
        let value = (try! arg[16:]).to_string().to_lower()
        if value != "sha1" && value != "sha256" {
          eprint_line("fatal: unknown hash algorithm '\{value}'")
          @sys.exit(128)
        }
        object_format = Some(value)
        object_format_explicit = true
      }
      _ if not(arg.has_prefix("-")) => target_dir = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("init", arg)
      _ => ()
    }
    i += 1
  }
  // Check GIT_DIR and GIT_WORK_TREE environment variables
  let git_dir_env = @sys.get_env_var("GIT_DIR")
  let work_tree_env = @sys.get_env_var("GIT_WORK_TREE")
  // Check GIT_TEMPLATE_DIR environment variable
  if template_dir is None {
    template_dir = @sys.get_env_var("GIT_TEMPLATE_DIR")
  }
  // Determine the target path and git directory
  let (path, effective_git_dir) : (String, String?) = match
    (target_dir, git_dir_env) {
    (Some(dir), _) => {
      let p = if dir.has_prefix("/") { dir } else { root + "/" + dir }
      (p, None)
    }
    (None, Some(gd)) => {
      // When GIT_DIR is set without target
      let g = if gd.has_prefix("/") { gd } else { root + "/" + gd }
      // If GIT_WORK_TREE is also set, it's not bare (work tree exists)
      // If only GIT_DIR is set, it's a bare repo
      if work_tree_env is Some(_) {
        (root, Some(g))
      } else {
        (g, Some(g))
      }
    }
    (None, None) => (root, None)
  }
  // Determine if bare: only bare if explicitly requested or GIT_DIR without GIT_WORK_TREE
  if git_dir_env is Some(_) && work_tree_env is None && target_dir is None {
    bare = true
  }
  // If GIT_WORK_TREE is set with --bare, that's an error
  if bare && work_tree_env is Some(_) {
    eprint_line(
      "fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed without specifying a repository to work with",
    )
    @sys.exit(128)
  }
  // Resolve separate_git_dir to absolute path
  let resolved_sep_git_dir : String? = match separate_git_dir {
    Some(d) => Some(if d.has_prefix("/") { d } else { root + "/" + d })
    None =>
      if use_bit && not(bare) && effective_git_dir is None {
        Some(path + "/.bit")
      } else {
        None
      }
  }
  // Determine default branch
  let branch = initial_branch.unwrap_or("main")
  // Determine actual git directory path for output message
  let actual_git_dir = match (resolved_sep_git_dir, effective_git_dir) {
    (Some(sep), _) => sep
    (None, Some(gd)) => gd
    (None, None) => if bare { path } else { path + "/.git" }
  }
  // Check if this is a reinit (repository already exists)
  let is_reinit = fs.is_dir(actual_git_dir) &&
    fs.is_file(actual_git_dir + "/HEAD")
  let mut reinit_tables_list_content : String? = None
  if object_format is None {
    let env_default = @sys.get_env_var("GIT_DEFAULT_HASH").unwrap_or("sha1")
    let normalized = env_default.to_lower()
    if normalized != "sha1" && normalized != "sha256" {
      eprint_line("fatal: unknown hash algorithm '\{normalized}'")
      @sys.exit(128)
    }
    object_format = Some(normalized)
  }
  if is_reinit {
    let existing_ref_format = if is_reftable_repo(fs, actual_git_dir) {
      "reftable"
    } else {
      "files"
    }
    if existing_ref_format == "reftable" {
      let tables_list_path = actual_git_dir + "/reftable/tables.list"
      if fs.is_file(tables_list_path) {
        reinit_tables_list_content = Some(
          decode_bytes(fs.read_file(tables_list_path)),
        )
      }
    }
    if ref_format_explicit && ref_format != existing_ref_format {
      eprint_line(
        "fatal: attempt to reinitialize repository with different reference storage format",
      )
      @sys.exit(128)
    }
    ref_format = existing_ref_format
    let existing_object_format = repo_object_format(fs, actual_git_dir)
    if object_format_explicit &&
      object_format.unwrap_or("sha1") != existing_object_format {
      eprint_line(
        "fatal: attempt to reinitialize repository with different hash",
      )
      @sys.exit(128)
    }
    object_format = Some(existing_object_format)
  }
  // Build init options
  let opts : @gitlib.InitOptions = {
    default_branch: branch,
    bare,
    separate_git_dir: resolved_sep_git_dir,
    template_dir,
    ref_format,
    object_format: object_format.unwrap_or("sha1"),
  }
  // Initialize repository
  @gitrepo.init_repo_with_options(fs, path, opts)
  match reinit_tables_list_content {
    Some(content) =>
      fs.write_string(actual_git_dir + "/reftable/tables.list", content)
    None => ()
  }
  // Apply template if specified
  match template_dir {
    Some(tpl) =>
      if fs.is_dir(tpl) {
        @gitrepo.apply_template(fs, fs, actual_git_dir, tpl)
      }
    None => ()
  }
  if ref_format == "reftable" && not(is_reinit) {
    bootstrap_reftable_head_table(fs, actual_git_dir, branch)
  }
  if ref_format == "reftable" {
    apply_reftable_shared_permissions(fs, actual_git_dir, shared_mode)
  }
  // Print appropriate message (unless quiet)
  if not(quiet) {
    let verb = if is_reinit {
      "Reinitialized existing"
    } else {
      "Initialized empty"
    }
    print_line(verb + " Git repository in " + actual_git_dir + "/")
  }
}

///|
async fn apply_reftable_shared_permissions(
  fs : OsFs,
  git_dir : String,
  shared_mode : String?,
) -> Unit {
  let chmod_mode = match shared_mode {
    Some(value) => {
      let normalized = value.to_lower()
      if normalized == "world" ||
        normalized == "all" ||
        normalized == "everybody" ||
        normalized == "2" {
        Some(0o664)
      } else {
        None
      }
    }
    None => None
  }
  match chmod_mode {
    Some(mode) => {
      let reftable_dir = git_dir + "/reftable"
      let tables_list_path = reftable_dir + "/tables.list"
      if fs.is_file(tables_list_path) {
        @asyncfs.chmod(tables_list_path[:], mode) catch {
          _ => ()
        }
      }
      if fs.is_dir(reftable_dir) {
        for entry in fs.readdir(reftable_dir) {
          if entry.has_suffix(".ref") {
            let table_path = reftable_dir + "/" + entry
            @asyncfs.chmod(table_path[:], mode) catch {
              _ => ()
            }
          }
        }
      }
    }
    None => ()
  }
}

///|
async fn bootstrap_reftable_head_table(
  fs : OsFs,
  git_dir : String,
  branch : String,
) -> Unit {
  let reftable_dir = git_dir + "/reftable"
  if not(fs.is_dir(reftable_dir)) {
    return
  }
  for entry in fs.readdir(reftable_dir) {
    if entry.has_suffix(".ref") {
      return
    }
  }
  let table_name = "0x000000000001-0x000000000001-00000000.ref"
  let table_path = reftable_dir + "/" + table_name
  let payload = "bit-reftable-placeholder\nHEAD\trefs/heads/" + branch + "\n"
  fs.write_string(table_path, payload)
  fs.write_string(reftable_dir + "/tables.list", table_name + "\n")
}
