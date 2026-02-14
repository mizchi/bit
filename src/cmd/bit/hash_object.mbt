///|
async fn handle_hash_object(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut write_object = false
  let mut stdin_mode = false
  let mut obj_type = "blob"
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-w" => write_object = true
      "--stdin" => stdin_mode = true
      "--literally" => ()
      "-t" => () // next arg is type, handled below
      _ if arg.has_prefix("-t") =>
        obj_type = String::unsafe_substring(arg, start=2, end=arg.length())
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("hash-object", arg)
      _ => ()
    }
  }
  // Handle -t <type> pattern
  let mut i = 0
  while i < args.length() {
    if args[i] == "-t" && i + 1 < args.length() {
      obj_type = args[i + 1]
    }
    i += 1
  }
  let git_dir = if write_object {
    resolve_git_dir(fs, root)
  } else {
    root + "/.git"
  }
  let compat_object_format = read_hash_object_compat_object_format(fs, git_dir)
  if hash_object_requires_standalone_error(write_object, compat_object_format) {
    eprint_line(
      "fatal: hash-object -w with compatObjectFormat=sha256 is not supported in standalone mode",
    )
    @sys.exit(1)
  }
  if stdin_mode {
    let content = read_all_stdin()
    let id = @git.hash_object_content(parse_object_type(obj_type), content)
    if write_object {
      let _ = @gitlib.write_loose_object(
        fs,
        git_dir,
        parse_object_type(obj_type),
        content,
      )
    }
    print_line(id.to_hex())
    return ()
  }
  for path in paths {
    let abs = if path.has_prefix("/") { path } else { root + "/" + path }
    let content = fs.read_file(abs)
    let id = @git.hash_object_content(parse_object_type(obj_type), content)
    if write_object {
      let _ = @gitlib.write_loose_object(
        fs,
        git_dir,
        parse_object_type(obj_type),
        content,
      )
    }
    print_line(id.to_hex())
  }
}

///|
fn read_hash_object_compat_object_format(
  fs : OsFs,
  git_dir : String,
) -> String? {
  let overrides = @gitlib.parse_config_overrides()
  match overrides.get("extensions.compatobjectformat") {
    Some(value) => Some(value)
    None => {
      let config_path = git_dir + "/config"
      @gitlib.read_config_value(
        fs, config_path, "extensions", "compatobjectformat",
      )
    }
  }
}

///|
fn hash_object_requires_standalone_error(
  write_object : Bool,
  compat_object_format : String?,
) -> Bool {
  if not(write_object) {
    return false
  }
  match compat_object_format {
    Some(format) => @gitlib.config_strip_quotes(format).to_lower() == "sha256"
    None => false
  }
}

///|
fn parse_object_type(s : String) -> @git.ObjectType raise Error {
  match s {
    "blob" => @git.ObjectType::Blob
    "tree" => @git.ObjectType::Tree
    "commit" => @git.ObjectType::Commit
    "tag" => @git.ObjectType::Tag
    _ => raise @git.GitError::InvalidObject("invalid object type \"" + s + "\"")
  }
}

///|
