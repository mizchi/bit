///|
pub fn run_storage_command(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  cmd : String,
  args : Array[String],
) -> Unit raise Error {
  match cmd {
    "init" => storage_handle_init(fs, rfs, root, args)
    "add" => storage_handle_add(fs, rfs, root, args)
    "commit" => storage_handle_commit(fs, rfs, root, args)
    "status" => storage_handle_status(rfs, root, args)
    "log" => storage_handle_log(rfs, root, args)
    "hash-object" => storage_handle_hash_object(fs, rfs, root, args)
    "write-tree" => storage_handle_write_tree(fs, rfs, root, args)
    "update-ref" => storage_handle_update_ref(fs, rfs, root, args)
    _ =>
      raise @git.GitError::InvalidObject("unsupported storage command: " + cmd)
  }
}

///|
fn storage_trim_string(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn storage_decode_bytes(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn storage_normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()
      } else if not(path.has_prefix("/")) {
        parts.push(part)
      }
    } else {
      parts.push(part)
    }
  }
  let result = parts.join("/")
  if path.has_prefix("/") {
    if result.length() == 0 {
      "/"
    } else {
      "/" + result
    }
  } else if result.length() == 0 {
    "."
  } else {
    result
  }
}

///|
fn storage_is_bare_repo_dir(rfs : &@git.RepoFileSystem, path : String) -> Bool {
  rfs.is_file(path + "/HEAD") && rfs.is_dir(path + "/objects")
}

///|
fn storage_default_repo_marker_path(
  rfs : &@git.RepoFileSystem,
  root : String,
) -> String {
  if storage_is_bare_repo_dir(rfs, root) {
    root
  } else {
    root + "/.git"
  }
}

///|
fn storage_resolve_git_dir(rfs : &@git.RepoFileSystem, root : String) -> String {
  let default_git_dir = storage_default_repo_marker_path(rfs, root)
  match @sys.get_env_var("GIT_DIR") {
    Some(dir) => {
      let resolved = if dir.has_prefix("/") {
        dir
      } else {
        storage_normalize_path(root + "/" + dir)
      }
      if rfs.is_file(resolved) {
        @gitlib.resolve_gitdir(rfs, resolved)
      } else if rfs.is_dir(resolved) {
        resolved
      } else if storage_is_bare_repo_dir(rfs, root) {
        root
      } else {
        resolved
      }
    }
    None =>
      if rfs.is_file(default_git_dir) {
        @gitlib.resolve_gitdir(rfs, default_git_dir)
      } else if rfs.is_dir(default_git_dir) {
        default_git_dir
      } else if storage_is_bare_repo_dir(rfs, root) {
        root
      } else {
        default_git_dir
      }
  }
}

///|
fn storage_repo_object_format(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> String {
  match
    @gitlib.read_config_value(
      rfs,
      git_dir + "/config",
      "extensions",
      "objectformat",
    ) {
    Some(value) => if value.to_lower() == "sha256" { "sha256" } else { "sha1" }
    None => "sha1"
  }
}

///|
fn storage_repo_compat_object_format(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  match
    @gitlib.read_config_value(
      rfs,
      git_dir + "/config",
      "extensions",
      "compatobjectformat",
    ) {
    Some(value) => {
      let normalized = @gitlib.config_strip_quotes(value).to_lower()
      if normalized == "sha1" || normalized == "sha256" {
        Some(normalized)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn storage_parse_git_env_timestamp(raw : String) -> Int64? {
  let mut token : String? = None
  for part_view in raw.split(" ") {
    let part = part_view.to_string()
    if part.length() > 0 {
      token = Some(part)
      break
    }
  }
  match token {
    Some(part) =>
      if part.has_prefix("@") {
        let numeric = String::unsafe_substring(part, start=1, end=part.length())
        let parsed = @strconv.parse_int64(numeric) catch { _ => return None }
        Some(parsed)
      } else {
        let parsed = @strconv.parse_int64(part) catch { _ => return None }
        Some(parsed)
      }
    None => None
  }
}

///|
fn storage_get_current_timestamp() -> Int64 {
  @env.now().to_int().to_int64()
}

///|
fn storage_get_author_string() -> String {
  match @sys.get_env_var("GIT_AUTHOR_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_AUTHOR_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None =>
      match @sys.get_env_var("USER") {
        Some(user) => user + " <" + user + "@localhost>"
        None => "Unknown <unknown@localhost>"
      }
  }
}

///|
fn storage_get_committer_string() -> String {
  match @sys.get_env_var("GIT_COMMITTER_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_COMMITTER_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None => storage_get_author_string()
  }
}

///|
fn storage_get_commit_timestamp() -> Int64 {
  match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(raw) =>
      match storage_parse_git_env_timestamp(raw) {
        Some(ts) => ts
        None => storage_get_current_timestamp()
      }
    None => storage_get_current_timestamp()
  }
}

///|
fn storage_is_short_count_flag(arg : String) -> Bool {
  if not(arg.has_prefix("-")) || arg.length() <= 1 {
    return false
  }
  let raw = String::unsafe_substring(arg, start=1, end=arg.length())
  for c in raw {
    if c < '0' || c > '9' {
      return false
    }
  }
  true
}

///|
fn storage_hash_object_requires_standalone_error(
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
fn storage_read_all_stdin() -> Bytes raise Error {
  raise @git.GitError::InvalidObject(
    "hash-object: stdin is not supported in storage runtime",
  )
}

///|
fn storage_parse_object_type(s : String) -> @git.ObjectType raise Error {
  match s {
    "blob" => @git.ObjectType::Blob
    "tree" => @git.ObjectType::Tree
    "commit" => @git.ObjectType::Commit
    "tag" => @git.ObjectType::Tag
    _ => raise @git.GitError::InvalidObject("invalid object type \"" + s + "\"")
  }
}

///|
fn storage_is_reftable_repo(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Bool {
  if rfs.is_dir(git_dir + "/reftable") {
    return true
  }
  match
    @gitlib.read_config_value(
      rfs,
      git_dir + "/config",
      "extensions",
      "refstorage",
    ) {
    Some(value) => value.to_lower() == "reftable"
    None => false
  }
}

///|
fn storage_parent_dir(path : String) -> String {
  if path.length() == 0 || path == "/" {
    return "/"
  }
  match path.rev_find("/") {
    None => ""
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

///|
fn storage_read_ref_value(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @git.ObjectId? {
  storage_read_ref_value_inner(rfs, git_dir, refname, 0)
}

///|
fn storage_read_ref_value_inner(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
  depth : Int,
) -> @git.ObjectId? {
  if depth > 8 {
    return None
  }
  let ref_path = git_dir + "/" + refname
  if rfs.is_file(ref_path) {
    let content = storage_decode_bytes(rfs.read_file(ref_path)) catch {
      _ => return None
    }
    let hex = storage_trim_string(content)
    if hex.has_prefix("ref: ") {
      let target = String::unsafe_substring(hex, start=5, end=hex.length())
      return storage_read_ref_value_inner(rfs, git_dir, target, depth + 1)
    }
    (@git.ObjectId::from_hex(hex) |> Some) catch {
      _ => None
    }
  } else {
    @gitlib.resolve_ref(rfs, git_dir, refname) catch {
      _ => None
    }
  }
}

///|
fn storage_fail_unsupported_option(
  cmd : String,
  arg : String,
) -> Unit raise Error {
  raise @git.GitError::InvalidObject(
    cmd + ": option is not supported in storage runtime: " + arg,
  )
}

///|
fn storage_fail_unsupported_mode(
  cmd : String,
  detail : String,
) -> Unit raise Error {
  raise @git.GitError::InvalidObject(
    cmd + ": mode is not supported in storage runtime: " + detail,
  )
}

///|
fn storage_runtime_is_quiet() -> Bool {
  match @sys.get_env_var("BIT_STORAGE_RUNTIME_QUIET") {
    Some(value) => {
      let normalized = storage_trim_string(value).to_lower()
      normalized == "1" || normalized == "true" || normalized == "yes"
    }
    None => false
  }
}

///|
fn storage_print_line(text : String) -> Unit {
  if storage_runtime_is_quiet() {
    return
  }
  println(text)
}

///|
fn storage_require_sha1_repo(
  cmd : String,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  if storage_repo_object_format(rfs, git_dir) != "sha1" {
    storage_fail_unsupported_mode(cmd, "repository object format")
  }
  match storage_repo_compat_object_format(rfs, git_dir) {
    Some(format) =>
      if format != "sha1" {
        storage_fail_unsupported_mode(cmd, "compatObjectFormat")
      }
    None => ()
  }
}

///|
fn storage_handle_init(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let mut quiet = false
  let mut initial_branch : String? = None
  let mut ref_format = "files"
  let mut object_format = "sha1"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-q" | "--quiet" => quiet = true
      "-b" if i + 1 < args.length() => {
        initial_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "--initial-branch" if i + 1 < args.length() => {
        initial_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "--ref-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "files" {
          storage_fail_unsupported_mode("init", "--ref-format=" + value)
        }
        ref_format = value
        i += 2
        continue
      }
      "--object-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "sha1" {
          storage_fail_unsupported_mode("init", "--object-format=" + value)
        }
        object_format = value
        i += 2
        continue
      }
      _ if arg.has_prefix("--initial-branch=") =>
        initial_branch = Some((try! arg[17:]).to_string())
      _ if arg.has_prefix("--ref-format=") => {
        let value = (try! arg[13:]).to_string().to_lower()
        if value != "files" {
          storage_fail_unsupported_mode("init", "--ref-format=" + value)
        }
        ref_format = value
      }
      _ if arg.has_prefix("--object-format=") => {
        let value = (try! arg[16:]).to_string().to_lower()
        if value != "sha1" {
          storage_fail_unsupported_mode("init", "--object-format=" + value)
        }
        object_format = value
      }
      _ if arg.has_prefix("-") => storage_fail_unsupported_option("init", arg)
      _ => storage_fail_unsupported_mode("init", "directory argument")
    }
    i += 1
  }
  let opts : @gitlib.InitOptions = {
    default_branch: initial_branch.unwrap_or("main"),
    bare: false,
    separate_git_dir: None,
    template_dir: None,
    ref_format,
    object_format,
  }
  @gitrepo.init_repo_with_options(fs, root, opts)
  if not(quiet) {
    let git_dir = storage_resolve_git_dir(rfs, root)
    storage_print_line("Initialized empty Git repository in " + git_dir + "/")
  }
}

///|
fn storage_handle_add(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  storage_require_sha1_repo("add", rfs, git_dir)
  let mut add_all = false
  let mut end_of_options = false
  let paths : Array[String] = []
  for arg in args {
    if not(end_of_options) && arg == "--" {
      end_of_options = true
      continue
    }
    match arg {
      "-A" | "--all" if not(end_of_options) => add_all = true
      _ if end_of_options || not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => storage_fail_unsupported_option("add", arg)
      _ => ()
    }
  }
  if add_all {
    @gitlib.add_paths(fs, rfs, root, ["."])
    return
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("add requires pathspec")
  }
  @gitlib.add_paths(fs, rfs, root, paths)
}

///|
fn storage_handle_commit(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  storage_require_sha1_repo("commit", rfs, git_dir)
  let mut message : String? = None
  let mut all_modified = false
  let mut allow_empty = false
  let mut quiet = false
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
      _ if arg.has_prefix("-m") && arg.length() > 2 => {
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
      "-a" | "--all" => all_modified = true
      "--allow-empty" => allow_empty = true
      "-q" | "--quiet" => quiet = true
      "--no-verify" => ()
      _ if arg.has_prefix("-") => storage_fail_unsupported_option("commit", arg)
      _ => storage_fail_unsupported_mode("commit", "positional arguments")
    }
    i += 1
  }
  guard message is Some(msg) else {
    raise @git.GitError::InvalidObject(
      "storage runtime commit requires -m/--message",
    )
  }
  if all_modified {
    @gitlib.add_paths(fs, rfs, root, ["."])
  }
  let timestamp = storage_get_commit_timestamp()
  let committer = storage_get_committer_string()
  let committer_timestamp = timestamp
  let commit_id = @gitlib.commit(
    fs,
    rfs,
    root,
    msg,
    storage_get_author_string(),
    timestamp,
    committer~,
    committer_timestamp~,
    allow_empty~,
  )
  if not(quiet) {
    let short_id = (try! commit_id.to_hex()[:7]).to_string()
    let first_line = match msg.find("\n") {
      Some(idx) => (try! msg[:idx]).to_string()
      None => msg
    }
    storage_print_line("[" + short_id + "] " + first_line)
  }
}

///|
priv struct StorageStatusSnapshot {
  staged_added : Array[String]
  staged_modified : Array[String]
  staged_deleted : Array[String]
  unstaged_modified : Array[String]
  unstaged_deleted : Array[String]
  untracked : Array[String]
}

///|
fn storage_parse_octal_mode(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
fn storage_is_tree_mode(mode : String) -> Bool {
  mode == "040000" || mode == "40000"
}

///|
fn storage_resolve_common_git_dir(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if not(rfs.is_file(commondir_path)) {
    return git_dir
  }
  let raw = storage_decode_bytes(
    (rfs.read_file(commondir_path) catch { _ => Bytes::default() }),
  )
  let rel = storage_trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    storage_normalize_path(rel)
  } else {
    storage_normalize_path(git_dir + "/" + rel)
  }
}

///|
fn storage_collect_staged_changes_db(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  index_map : Map[String, @gitlib.IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise Error {
  let tree_obj = db.get(rfs, tree_id)
  match tree_obj {
    None => raise @git.GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != @git.ObjectType::Tree {
        raise @git.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @git.parse_tree(obj.data)
      for entry in entries {
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if storage_is_tree_mode(entry.mode) {
          storage_collect_staged_changes_db(
            db,
            rfs,
            entry.id,
            path,
            index_map,
            staged_modified,
            staged_deleted,
          )
        } else {
          let mode = storage_parse_octal_mode(entry.mode)
          match index_map.get(path) {
            Some(index_entry) => {
              if index_entry.id != entry.id || index_entry.mode != mode {
                staged_modified.push(path)
              }
              index_map.remove(path)
            }
            None => staged_deleted.push(path)
          }
        }
      }
    }
  }
}

///|
fn storage_collect_staged_changes_from_head(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  index_map : Map[String, @gitlib.IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise Error {
  match @gitlib.resolve_head_commit(rfs, git_dir) {
    None => ()
    Some(commit_id) => {
      let common_git_dir = storage_resolve_common_git_dir(rfs, git_dir)
      let db = @gitlib.ObjectDb::load_lazy(rfs, common_git_dir)
      match db.get(rfs, commit_id) {
        None => ()
        Some(obj) => {
          if obj.obj_type != @git.ObjectType::Commit {
            raise @git.GitError::InvalidObject("Object is not a commit")
          }
          let info = @git.parse_commit(obj.data)
          storage_collect_staged_changes_db(
            db,
            rfs,
            info.tree,
            "",
            index_map,
            staged_modified,
            staged_deleted,
          )
        }
      }
    }
  }
}

///|
fn storage_collect_status_snapshot(
  rfs : &@git.RepoFileSystem,
  root : String,
) -> StorageStatusSnapshot raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let entries = @gitlib.read_index_entries(rfs, git_dir)
  let index_map : Map[String, @gitlib.IndexEntry] = {}
  for entry in entries {
    index_map[entry.path] = entry
  }
  let files = @ignore.list_working_files(rfs, root)
  files.sort()
  let visited : Map[String, Bool] = {}
  let untracked : Array[String] = []
  let unstaged_modified : Array[String] = []
  for rel_path in files {
    visited[rel_path] = true
    match index_map.get(rel_path) {
      Some(index_entry) => {
        let abs_path = root + "/" + rel_path
        let content = rfs.read_file(abs_path) catch {
          _ => continue
        }
        let worktree_id = @git.hash_blob(content)
        if worktree_id != index_entry.id {
          unstaged_modified.push(rel_path)
        }
      }
      None => untracked.push(rel_path)
    }
  }
  let unstaged_deleted : Array[String] = []
  for entry in entries {
    if visited.get(entry.path) is Some(_) {
      continue
    }
    let abs_path = root + "/" + entry.path
    if not(rfs.is_file(abs_path)) {
      unstaged_deleted.push(entry.path)
    }
  }
  let staged_index_map : Map[String, @gitlib.IndexEntry] = {}
  for entry in entries {
    staged_index_map[entry.path] = entry
  }
  let staged_modified : Array[String] = []
  let staged_deleted : Array[String] = []
  storage_collect_staged_changes_from_head(
    rfs,
    git_dir,
    staged_index_map,
    staged_modified,
    staged_deleted,
  )
  let staged_added : Array[String] = []
  for item in staged_index_map.to_array() {
    let (path, _) = item
    staged_added.push(path)
  }
  staged_added.sort()
  staged_modified.sort()
  staged_deleted.sort()
  unstaged_modified.sort()
  unstaged_deleted.sort()
  untracked.sort()
  let snapshot : StorageStatusSnapshot = {
    staged_added,
    staged_modified,
    staged_deleted,
    unstaged_modified,
    unstaged_deleted,
    untracked,
  }
  snapshot
}

///|
fn storage_status_porcelain_branch_line(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> String raise Error {
  match @gitlib.read_head_ref(rfs, git_dir) {
    @gitlib.HeadRef::Branch(name) => "## " + name
    @gitlib.HeadRef::Detached(id) => {
      let short_id = (try! id.to_hex()[:7]).to_string()
      "## HEAD (detached at " + short_id + ")"
    }
  }
}

///|
fn storage_status_porcelain_lines(
  rfs : &@git.RepoFileSystem,
  root : String,
  show_branch : Bool,
) -> Array[String] raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let out : Array[String] = []
  if show_branch {
    out.push(storage_status_porcelain_branch_line(rfs, git_dir))
  }
  let status = storage_collect_status_snapshot(rfs, root)
  let xmap : Map[String, Char] = {}
  let ymap : Map[String, Char] = {}
  for p in status.staged_added {
    xmap[p] = 'A'
  }
  for p in status.staged_modified {
    xmap[p] = 'M'
  }
  for p in status.staged_deleted {
    xmap[p] = 'D'
  }
  for p in status.unstaged_modified {
    ymap[p] = 'M'
  }
  for p in status.unstaged_deleted {
    ymap[p] = 'D'
  }
  let paths : Map[String, Bool] = {}
  for p in status.staged_added {
    paths[p] = true
  }
  for p in status.staged_modified {
    paths[p] = true
  }
  for p in status.staged_deleted {
    paths[p] = true
  }
  for p in status.unstaged_modified {
    paths[p] = true
  }
  for p in status.unstaged_deleted {
    paths[p] = true
  }
  let lines : Array[String] = []
  let merged_paths : Array[String] = []
  for item in paths.to_array() {
    let (path, _) = item
    merged_paths.push(path)
  }
  merged_paths.sort()
  for path in merged_paths {
    let x = xmap.get(path).unwrap_or(' ')
    let y = ymap.get(path).unwrap_or(' ')
    lines.push("\{x}\{y} \{path}")
  }
  for path in status.untracked {
    lines.push("?? \{path}")
  }
  for line in lines {
    out.push(line)
  }
  out
}

///|
fn storage_status_text_lines(
  rfs : &@git.RepoFileSystem,
  root : String,
) -> Array[String] raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let out : Array[String] = []
  match @gitlib.read_head_ref(rfs, git_dir) {
    @gitlib.HeadRef::Branch(name) => out.push("On branch " + name)
    @gitlib.HeadRef::Detached(id) => {
      let short_id = (try! id.to_hex()[:7]).to_string()
      out.push("HEAD detached at " + short_id)
    }
  }
  let status = storage_collect_status_snapshot(rfs, root)
  let has_staged = status.staged_added.length() > 0 ||
    status.staged_modified.length() > 0 ||
    status.staged_deleted.length() > 0
  let has_unstaged = status.unstaged_modified.length() > 0 ||
    status.unstaged_deleted.length() > 0
  if has_staged {
    out.push("")
    out.push("Changes to be committed:")
    for path in status.staged_added {
      out.push("  staged: " + path)
    }
    for path in status.staged_modified {
      out.push("  staged: " + path)
    }
    for path in status.staged_deleted {
      out.push("  staged: " + path)
    }
  }
  if has_unstaged {
    out.push("")
    out.push("Changes not staged for commit:")
    for path in status.unstaged_modified {
      out.push("  modified: " + path)
    }
    for path in status.unstaged_deleted {
      out.push("  deleted: " + path)
    }
  }
  if status.untracked.length() > 0 {
    out.push("")
    out.push("Untracked files:")
    for path in status.untracked {
      out.push("  " + path)
    }
  }
  if not(has_staged) && not(has_unstaged) && status.untracked.length() == 0 {
    out.push("")
    out.push("nothing to commit, working tree clean")
  }
  out
}

///|
fn storage_handle_status(
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let mut porcelain = false
  let mut short = false
  let mut show_branch = false
  for arg in args {
    match arg {
      "--porcelain" | "--porcelain=v1" => porcelain = true
      "-s" | "--short" => short = true
      "-b" | "--branch" => show_branch = true
      "-sb" => {
        short = true
        show_branch = true
      }
      _ if arg.has_prefix("-") => storage_fail_unsupported_option("status", arg)
      _ => storage_fail_unsupported_mode("status", "pathspec")
    }
  }
  let lines = if porcelain || short {
    storage_status_porcelain_lines(rfs, root, show_branch)
  } else {
    storage_status_text_lines(rfs, root)
  }
  for line in lines {
    storage_print_line(line)
  }
}

///|
fn storage_handle_log(
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let mut oneline = false
  let mut max_count = 10
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--oneline" => oneline = true
      "-n" if i + 1 < args.length() => {
        max_count = @strconv.parse_int(args[i + 1])
        i += 2
        continue
      }
      "--max-count" if i + 1 < args.length() => {
        max_count = @strconv.parse_int(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-n") && arg.length() > 2 =>
        max_count = @strconv.parse_int((try! arg[2:]).to_string())
      _ if storage_is_short_count_flag(arg) => {
        let num_str = String::unsafe_substring(arg, start=1, end=arg.length())
        max_count = @strconv.parse_int(num_str)
      }
      _ if arg.has_prefix("--max-count=") =>
        max_count = @strconv.parse_int((try! arg[12:]).to_string())
      _ if arg.has_prefix("-") => storage_fail_unsupported_option("log", arg)
      _ => storage_fail_unsupported_mode("log", "revision arguments")
    }
    i += 1
  }
  let git_dir = storage_resolve_git_dir(rfs, root)
  if oneline {
    let lines = @gitlib.log_head_oneline(rfs, git_dir, max_count~)
    for line in lines {
      storage_print_line(line)
    }
    return
  }
  let entries = @gitlib.log_head(rfs, git_dir, max_count~)
  for entry in entries {
    storage_print_line("commit " + entry.id.to_hex())
    storage_print_line("Author: " + entry.author)
    storage_print_line("")
    storage_print_line("    " + entry.message)
    storage_print_line("")
  }
}

///|
fn storage_handle_hash_object(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let mut write_object = false
  let mut stdin_mode = false
  let mut obj_type = "blob"
  let paths : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-w" => write_object = true
      "--stdin" => stdin_mode = true
      "--literally" => ()
      "-t" if i + 1 < args.length() => {
        obj_type = args[i + 1]
        i += 2
        continue
      }
      _ if arg.has_prefix("-t") && arg.length() > 2 =>
        obj_type = String::unsafe_substring(arg, start=2, end=arg.length())
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => storage_fail_unsupported_option("hash-object", arg)
    }
    i += 1
  }
  let git_dir = if write_object {
    storage_resolve_git_dir(rfs, root)
  } else {
    root + "/.git"
  }
  let compat_object_format = storage_read_compat_object_format(rfs, git_dir)
  if storage_hash_object_requires_standalone_error(
      write_object, compat_object_format,
    ) {
    storage_fail_unsupported_mode(
      "hash-object", "-w with compatObjectFormat=sha256",
    )
  }
  if stdin_mode {
    let content = storage_read_all_stdin()
    let id = @git.hash_object_content(
      storage_parse_object_type(obj_type),
      content,
    )
    if write_object {
      ignore(
        @gitlib.write_loose_object(
          fs,
          git_dir,
          storage_parse_object_type(obj_type),
          content,
        ),
      )
    }
    storage_print_line(id.to_hex())
    return
  }
  for path in paths {
    let abs = if path.has_prefix("/") { path } else { root + "/" + path }
    let content = rfs.read_file(abs)
    let id = @git.hash_object_content(
      storage_parse_object_type(obj_type),
      content,
    )
    if write_object {
      ignore(
        @gitlib.write_loose_object(
          fs,
          git_dir,
          storage_parse_object_type(obj_type),
          content,
        ),
      )
    }
    storage_print_line(id.to_hex())
  }
}

///|
fn storage_read_compat_object_format(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  let overrides = @gitlib.parse_config_overrides()
  match overrides.get("extensions.compatobjectformat") {
    Some(value) => Some(value)
    None =>
      @gitlib.read_config_value(
        rfs,
        git_dir + "/config",
        "extensions",
        "compatobjectformat",
      )
  }
}

///|
fn storage_handle_write_tree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  storage_require_sha1_repo("write-tree", rfs, git_dir)
  let mut prefix : String? = None
  for arg in args {
    if arg.has_prefix("--prefix=") {
      prefix = Some((try! arg[9:]).to_string())
      continue
    }
    if arg.has_prefix("-") {
      storage_fail_unsupported_option("write-tree", arg)
    }
    storage_fail_unsupported_mode("write-tree", "path arguments")
  }
  let entries = @gitlib.read_index_entries(rfs, git_dir)
  let tree_id = @gitlib.write_tree_from_index(fs, git_dir, entries, prefix~)
  storage_print_line(tree_id.to_hex())
}

///|
fn storage_handle_update_ref(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  if storage_is_reftable_repo(rfs, git_dir) {
    storage_fail_unsupported_mode("update-ref", "reftable repository")
  }
  let mut delete_mode = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "-d" | "--delete" => delete_mode = true
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => storage_fail_unsupported_option("update-ref", arg)
    }
  }
  if delete_mode {
    guard positional.length() >= 1 else {
      raise @git.GitError::InvalidObject(
        "usage: update-ref -d <refname> [<oldvalue>]",
      )
    }
    let refname = positional[0]
    let old_value : String? = if positional.length() >= 2 {
      Some(positional[1])
    } else {
      None
    }
    storage_verify_old_ref_value(rfs, git_dir, refname, old_value)
    let ref_path = git_dir + "/" + refname
    if rfs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    return
  }
  guard positional.length() >= 2 else {
    raise @git.GitError::InvalidObject(
      "usage: update-ref <refname> <newvalue> [<oldvalue>]",
    )
  }
  let refname = positional[0]
  let new_value = if positional[1] == "@" { "HEAD" } else { positional[1] }
  let old_value : String? = if positional.length() >= 3 {
    Some(positional[2])
  } else {
    None
  }
  storage_verify_old_ref_value(rfs, git_dir, refname, old_value)
  let new_id = storage_resolve_object_id(rfs, git_dir, new_value)
  let ref_path = git_dir + "/" + refname
  let dir = storage_parent_dir(ref_path)
  if dir.length() > 0 && not(rfs.is_dir(dir)) {
    fs.mkdir_p(dir)
  }
  fs.write_string(ref_path, new_id.to_hex() + "\n")
}

///|
fn storage_verify_old_ref_value(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
  old_value : String?,
) -> Unit raise Error {
  match old_value {
    Some(expected_hex) => {
      let expected = @git.ObjectId::from_hex(expected_hex)
      let current = storage_read_ref_value(rfs, git_dir, refname)
      match current {
        Some(cur_id) =>
          if cur_id.to_hex() != expected.to_hex() {
            raise @git.GitError::InvalidObject(
              "update-ref oldvalue mismatch for " + refname,
            )
          }
        None =>
          if expected.to_hex() != @git.ObjectId::zero().to_hex() {
            raise @git.GitError::InvalidObject(
              "update-ref expected existing ref: " + refname,
            )
          }
      }
    }
    None => ()
  }
}

///|
fn storage_resolve_object_id(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @git.ObjectId raise Error {
  @git.ObjectId::from_hex(spec) catch {
    _ =>
      match @gitrepo.rev_parse(rfs, git_dir, spec) {
        Some(id) => id
        None => raise @git.GitError::InvalidObject("unknown revision: " + spec)
      }
  }
}
