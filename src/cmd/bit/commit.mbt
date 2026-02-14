///|

///|
async fn show_commit_command_help() -> Unit {
  show_simple_command_help(
    "git commit [<options>]",
    summary="Record changes to the repository.",
  )
}

///|
async fn handle_commit(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  if commit_repo_requires_standalone_error(rfs, git_dir) {
    eprint_line(
      "fatal: commit with this repository object format is not supported in standalone mode",
    )
    @sys.exit(1)
  }
  if commit_args_require_standalone_error(args) {
    eprint_line("fatal: this commit mode is not supported in standalone mode")
    @sys.exit(1)
  }
  let commit_message_encoding = resolve_commit_message_encoding()
  let mut message : String? = None
  let mut all_modified = false
  let mut amend = false
  let mut allow_empty = false
  let mut no_verify = false
  let mut no_edit = false
  let mut quiet = false
  let mut author_override : String? = None
  let mut date_override : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "--message" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "-am" | "-ma" if i + 1 < args.length() => {
        all_modified = true
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "--author" if i + 1 < args.length() => {
        author_override = Some(args[i + 1])
        i += 2
        continue
      }
      "--date" if i + 1 < args.length() => {
        date_override = Some(args[i + 1])
        i += 2
        continue
      }
      "-F" if i + 1 < args.length() => {
        message = Some(
          read_commit_message_from_file(
            fs,
            root,
            args[i + 1],
            commit_message_encoding,
          ),
        )
        i += 2
        continue
      }
      "-C" if i + 1 < args.length() => {
        message = read_commit_message_from_revision(fs, root, args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("-am") || arg.has_prefix("-ma") => {
        all_modified = true
        message = Some((try! arg[3:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--author=") => {
        author_override = Some((try! arg[9:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--date=") => {
        date_override = Some((try! arg[7:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("-F") => {
        let file = (try! arg[2:]).to_string()
        message = Some(
          read_commit_message_from_file(fs, root, file, commit_message_encoding),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-C") => {
        let spec = (try! arg[2:]).to_string()
        message = read_commit_message_from_revision(fs, root, spec)
        i += 1
        continue
      }
      "-a" | "--all" => all_modified = true
      "--amend" => amend = true
      "--allow-empty" => allow_empty = true
      "--no-verify" => no_verify = true
      "--no-edit" => no_edit = true
      "-q" | "--quiet" => quiet = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("commit", arg)
      _ => ()
    }
    i += 1
  }
  let git_dir = resolve_git_dir(fs, root)
  let merge_heads = read_merge_head_ids(fs, git_dir)
  let should_cleanup_merge_state = merge_heads.length() > 0 ||
    fs.is_file(git_dir + "/MERGE_MSG") ||
    fs.is_file(git_dir + "/MERGE_MODE") ||
    fs.is_file(git_dir + "/SQUASH_MSG")
  // If -a flag, stage all modified files
  if all_modified {
    let status = @gitlib.status(fs, root)
    let paths_to_add : Array[String] = []
    for p in status.unstaged_modified {
      paths_to_add.push(p)
    }
    for p in status.unstaged_deleted {
      paths_to_add.push(p)
    }
    if paths_to_add.length() > 0 {
      @gitlib.add_paths_async(fs, fs, root, paths_to_add)
    }
  }
  // Open editor when message is not specified.
  if message is None {
    if no_edit {
      message = resolve_no_edit_commit_message(fs, root, git_dir, amend)
    } else {
      let initial_message = if amend {
        get_head_commit_message(fs, root)
      } else {
        None
      }
      message = read_commit_message_from_editor(fs, root, initial_message~)
    }
  }
  guard message is Some(msg) else {
    raise @git.GitError::InvalidObject(
      "Aborting commit due to empty commit message.",
    )
  }
  let default_author = get_author_string()
  let default_timestamp = get_commit_timestamp()
  let author = match author_override {
    Some(a) => a
    None => default_author
  }
  let author_timestamp = match date_override {
    Some(d) => parse_commit_date(d)
    None => default_timestamp
  }
  // Committer is always the current user
  let committer = get_committer_string()
  let committer_timestamp = default_timestamp
  if not(no_verify) {
    let hook_status = run_pre_commit_hook(fs, root, git_dir)
    if hook_status != 0 {
      raise @git.GitError::InvalidObject("pre-commit hook failed")
    }
  }
  let commit_id = if amend {
    @gitlib.commit_amend(
      fs,
      fs,
      root,
      msg,
      author,
      author_timestamp,
      committer~,
      committer_timestamp~,
    )
  } else if merge_heads.length() > 0 {
    commit_with_merge_heads(
      fs, fs, root, msg, author, author_timestamp, committer, committer_timestamp,
      merge_heads, allow_empty,
    )
  } else {
    @gitlib.commit(
      fs,
      fs,
      root,
      msg,
      author,
      author_timestamp,
      committer~,
      committer_timestamp~,
      allow_empty~,
    )
  }
  if should_cleanup_merge_state {
    cleanup_merge_state_files(fs, git_dir)
  }
  let short_id = (try! commit_id.to_hex()[:7]).to_string()
  let first_line = match msg.find("\n") {
    Some(idx) => (try! msg[:idx]).to_string()
    None => msg
  }
  // Show subdir-clone context if applicable
  if not(quiet) {
    match get_subdir_info(fs, git_dir) {
      Some((_, path, _)) =>
        print_line("[" + short_id + " (subdir: " + path + ")] " + first_line)
      None => print_line("[" + short_id + "] " + first_line)
    }
  }
}

///|
fn commit_repo_requires_standalone_error(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Bool {
  is_reftable_repo(fs, git_dir) ||
  repo_object_format(fs, git_dir) != "sha1" ||
  (match repo_compat_object_format(fs, git_dir) {
    Some(format) => format != "sha1"
    None => false
  })
}

///|
fn resolve_no_edit_commit_message(
  fs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  amend : Bool,
) -> String? raise Error {
  let merge_head_path = git_dir + "/MERGE_HEAD"
  let squash_msg_path = git_dir + "/SQUASH_MSG"
  let merge_msg_path = git_dir + "/MERGE_MSG"
  if fs.is_file(merge_head_path) {
    if fs.is_file(merge_msg_path) {
      return Some(decode_bytes(fs.read_file(merge_msg_path)))
    }
    if amend {
      return get_head_commit_message(fs, root)
    }
    return None
  }
  if fs.is_file(squash_msg_path) {
    let squash_msg = decode_bytes(fs.read_file(squash_msg_path))
    if fs.is_file(merge_msg_path) {
      let merge_msg = decode_bytes(fs.read_file(merge_msg_path))
      return Some(join_commit_messages(squash_msg, merge_msg))
    }
    return Some(squash_msg)
  }
  if fs.is_file(merge_msg_path) {
    return Some(decode_bytes(fs.read_file(merge_msg_path)))
  }
  if amend {
    return get_head_commit_message(fs, root)
  }
  None
}

///|
fn join_commit_messages(primary : String, secondary : String) -> String {
  if primary.length() == 0 {
    return secondary
  }
  if secondary.length() == 0 {
    return primary
  }
  if primary.has_suffix("\n") || secondary.has_prefix("\n") {
    primary + secondary
  } else {
    primary + "\n" + secondary
  }
}

///|
fn read_merge_head_ids(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[@git.ObjectId] raise Error {
  let path = git_dir + "/MERGE_HEAD"
  if not(fs.is_file(path)) {
    return []
  }
  let ids : Array[@git.ObjectId] = []
  let content = decode_bytes(fs.read_file(path))
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    let id = @git.ObjectId::from_hex(line) catch {
      _ => raise @git.GitError::InvalidObject("invalid MERGE_HEAD: \{line}")
    }
    ids.push(id)
  }
  ids
}

///|
fn commit_with_merge_heads(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer : String,
  committer_timestamp : Int64,
  merge_heads : Array[@git.ObjectId],
  allow_empty : Bool,
) -> @git.ObjectId raise Error {
  let git_dir = resolve_git_dir(rfs, root)
  let head_parent = @gitlib.resolve_head_commit(rfs, git_dir)
  let entries = @gitlib.read_index_entries(rfs, git_dir)
  let tree_id = if entries.length() == 0 {
    if not(allow_empty) {
      raise @git.GitError::InvalidObject("Empty index")
    }
    match head_parent {
      Some(parent_id) => {
        let db = @gitlib.ObjectDb::load_lazy(rfs, git_dir)
        let parent_tree = match db.get(rfs, parent_id) {
          Some(obj) if obj.obj_type == @git.ObjectType::Commit =>
            (@git.parse_commit(obj.data).tree |> Some) catch {
              _ => None
            }
          _ => None
        }
        match parent_tree {
          Some(tree) => tree
          None => {
            let (empty_tree_id, empty_tree_compressed) = @git.create_tree([])
            @gitlib.write_object_bytes(
              fs, git_dir, empty_tree_id, empty_tree_compressed,
            )
            empty_tree_id
          }
        }
      }
      None => {
        let (empty_tree_id, empty_tree_compressed) = @git.create_tree([])
        @gitlib.write_object_bytes(
          fs, git_dir, empty_tree_id, empty_tree_compressed,
        )
        empty_tree_id
      }
    }
  } else {
    @gitlib.write_tree_from_index(fs, git_dir, entries)
  }
  let parents : Array[@git.ObjectId] = []
  let seen : Map[String, Bool] = {}
  match head_parent {
    Some(parent_id) => {
      parents.push(parent_id)
      seen[parent_id.to_hex()] = true
    }
    None => ()
  }
  for merge_head in merge_heads {
    let hex = merge_head.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    parents.push(merge_head)
  }
  let commit = @git.Commit::new(
    tree_id, parents, author, author_timestamp, "+0000", committer, committer_timestamp,
    "+0000", message,
  )
  let (commit_id, compressed) = @git.create_commit(commit)
  @gitlib.write_object_bytes(fs, git_dir, commit_id, compressed)
  @gitlib.update_head_ref(fs, rfs, git_dir, commit_id)
  commit_id
}

///|
fn cleanup_merge_state_files(
  fs : &@git.FileSystem,
  git_dir : String,
) -> Unit raise Error {
  let files = ["MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG"]
  for file in files {
    fs.remove_file(git_dir + "/" + file) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
  }
}

///|
fn commit_args_require_standalone_error(args : Array[String]) -> Bool {
  let mut expect_value = false
  for arg in args {
    if expect_value {
      expect_value = false
      continue
    }
    if arg == "--" {
      // `git commit -- <pathspec>` requires full pathspec semantics.
      return true
    }
    if arg == "-S" ||
      arg == "--gpg-sign" ||
      arg == "--no-gpg-sign" ||
      arg.has_prefix("-S") ||
      arg.has_prefix("--gpg-sign=") {
      // Signed commit modes are not supported in standalone mode.
      return true
    }
    if arg == "-m" ||
      arg == "--message" ||
      arg == "-F" ||
      arg == "--file" ||
      arg == "-C" ||
      arg == "--reuse-message" ||
      arg == "-c" ||
      arg == "--reedit-message" ||
      arg == "--author" ||
      arg == "--date" {
      expect_value = true
      continue
    }
    if arg.has_prefix("--message=") ||
      arg.has_prefix("--author=") ||
      arg.has_prefix("--date=") ||
      arg.has_prefix("--file=") ||
      arg.has_prefix("--reuse-message=") ||
      arg.has_prefix("--reedit-message=") {
      continue
    }
    if arg.has_prefix("-m") ||
      arg.has_prefix("-F") ||
      arg.has_prefix("-C") ||
      arg.has_prefix("-c") ||
      arg.has_prefix("-am") ||
      arg.has_prefix("-ma") {
      continue
    }
    if arg.has_prefix("-") {
      continue
    }
    return true
  }
  false
}

///|
async fn read_commit_message_from_file(
  fs : &@git.RepoFileSystem,
  root : String,
  file : String,
  encoding : String,
) -> String raise Error {
  if file == "-" {
    return decode_commit_message_bytes(read_all_stdin(), encoding)
  }
  let path = if file.has_prefix("/") { file } else { root + "/" + file }
  decode_commit_message_bytes(fs.read_file(path), encoding)
}

///|
fn read_commit_message_from_revision(
  fs : &@git.RepoFileSystem,
  root : String,
  spec : String,
) -> String? raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let commit_id = @gitrepo.rev_parse(fs, git_dir, spec)
  match commit_id {
    Some(id) => {
      let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
      match db.get(fs, id) {
        Some(obj) => Some(extract_commit_message(obj.data))
        None => None
      }
    }
    None => None
  }
}

///|
fn resolve_commit_message_encoding() -> String {
  let overrides = @gitlib.parse_config_overrides()
  match overrides.get("i18n.commitencoding") {
    Some(value) => {
      let trimmed = trim_string(value)
      if trimmed.length() > 0 {
        trimmed
      } else {
        "UTF-8"
      }
    }
    None => "UTF-8"
  }
}

///|
fn decode_commit_message_bytes(data : Bytes, encoding : String) -> String {
  if is_iso_8859_1_encoding(encoding) {
    let out = StringBuilder::new()
    for b in data {
      out.write_char(b.to_int().unsafe_to_char())
    }
    out.to_string()
  } else {
    decode_bytes(data)
  }
}

///|
fn is_iso_8859_1_encoding(encoding : String) -> Bool {
  let normalized = normalize_commit_encoding_name(encoding)
  normalized == "iso88591" || normalized == "latin1" || normalized == "latin"
}

///|
fn normalize_commit_encoding_name(value : String) -> String {
  let out = StringBuilder::new()
  for c in trim_string(value).to_lower() {
    if c == '-' || c == '_' || c == ' ' {
      continue
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
fn abs_path(path : String) -> String {
  if path.has_prefix("/") {
    return path
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  normalize_path(cwd + "/" + path)
}

///|
async fn run_pre_commit_hook(fs : OsFs, root : String, git_dir : String) -> Int {
  let hook_git_dir = abs_path(git_dir)
  let hook_path = hook_git_dir + "/hooks/pre-commit"
  if not(fs.is_file(hook_path)) {
    return 0
  }
  let work_root = abs_path(root)
  @process.run(hook_path, [], inherit_env=true, cwd=work_root) catch {
    _ => 1
  }
}

///|
fn parse_commit_date(date_str : String) -> Int64 {
  // Support common formats:
  // - Unix timestamp: "1234567890"
  // - @timestamp: "@1234567890"
  // - ISO 8601: "2024-01-01T12:00:00"
  if date_str.has_prefix("@") {
    let ts_str = try date_str[1:] catch {
      _ => return 0L
    } noraise {
      s => s.to_string()
    }
    return parse_int64(ts_str)
  }
  // Try parsing as unix timestamp
  if date_str.iter().all(c => c >= '0' && c <= '9') {
    return parse_int64(date_str)
  }
  // Fallback to current time if format not recognized
  get_commit_timestamp()
}

///|
fn parse_int64(s : String) -> Int64 {
  let mut result = 0L
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
  }
  result
}
