///| Core handlers: init, status, add, commit, log, show

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
  // Parse options
  let mut bare = false
  let mut quiet = false
  let mut initial_branch : String? = None
  let mut target_dir : String? = None
  let mut separate_git_dir : String? = None
  let mut template_dir : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--bare" => bare = true
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
      _ if arg.has_prefix("--initial-branch=") =>
        initial_branch = Some((try! arg[17:]).to_string())
      _ if arg.has_prefix("--separate-git-dir=") =>
        separate_git_dir = Some((try! arg[19:]).to_string())
      _ if arg.has_prefix("--template=") =>
        template_dir = Some((try! arg[11:]).to_string())
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
    None => None
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
  // Build init options
  let opts : @gitlib.InitOptions = {
    default_branch: branch,
    bare,
    separate_git_dir: resolved_sep_git_dir,
    template_dir,
  }
  // Initialize repository
  @gitlib.init_repo_with_options(fs, path, opts)
  // Apply template if specified
  match template_dir {
    Some(tpl) =>
      if fs.is_dir(tpl) {
        @gitlib.apply_template(fs, fs, actual_git_dir, tpl)
      }
    None => ()
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
async fn handle_status(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let mut root = get_work_root()
  let mut git_dir = root + "/.git"
  let mut has_git_dir = fs.is_dir(git_dir)
  let mut has_git_file = if has_git_dir { false } else { fs.is_file(git_dir) }
  if not(has_git_dir) && not(has_git_file) {
    match find_repo_root(".") {
      Some(found) => {
        root = found
        git_dir = root + "/.git"
        has_git_dir = fs.is_dir(git_dir)
        has_git_file = if has_git_dir { false } else { fs.is_file(git_dir) }
      }
      None =>
        raise @git.GitError::InvalidObject(
          "Not a git repository (or any of the parent directories): .git",
        )
    }
  }
  if not(has_git_dir) && not(has_git_file) {
    raise @git.GitError::InvalidObject(
      "Not a git repository (or any of the parent directories): .git",
    )
  }
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("status", arg)
      _ => ()
    }
  }
  // Show subdir-clone info if applicable (only in non-porcelain mode)
  if not(porcelain) && not(short) {
    match get_subdir_info(fs, git_dir) {
      Some((remote, path, base)) => {
        print_line("# subdir-clone: \{path} from \{remote}")
        print_line("# base: \{base[:7].to_string()}")
        print_line("")
      }
      None => ()
    }
  }
  if porcelain || short {
    if show_branch {
      let head = @gitlib.read_head_ref(fs, git_dir) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => return ()
      }
      match head {
        @gitlib.HeadRef::Branch(name) => print_line("## \{name}")
        @gitlib.HeadRef::Detached(id) =>
          print_line("## HEAD (detached at \{id.to_hex()[:7].to_string()})")
      }
    }
    let lines = @gitlib.status_porcelain(fs, root)
    for line in lines {
      print_line(line)
    }
  } else {
    let text = @gitlib.status_text(fs, root)
    print_str(text)
  }
}

///|
async fn handle_add(args : Array[String]) -> Unit raise Error {
  if has_interactive_add_flag(args) {
    run_add_interactive(args)
    return
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let mut add_all = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-A" | "--all" => add_all = true
      "-f" | "--force" => () // TODO: skip gitignore check
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("add", arg)
      _ => ()
    }
  }
  if add_all {
    // Stage all: untracked, modified, and deleted
    let status = @gitlib.status(fs, root)
    let all_paths : Array[String] = []
    for p in status.untracked {
      all_paths.push(p)
    }
    for p in status.unstaged_modified {
      all_paths.push(p)
    }
    for p in status.unstaged_deleted {
      all_paths.push(p)
    }
    if all_paths.length() > 0 {
      @gitlib.add_paths_async(fs, fs, root, all_paths)
    }
    return
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("Nothing specified, nothing added.")
  }
  @gitlib.add_paths_async(fs, fs, root, paths)
}

///|
async fn handle_commit(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut message : String? = None
  let mut all_modified = false
  let mut amend = false
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
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
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
      "-a" | "--all" => all_modified = true
      "--amend" => amend = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("commit", arg)
      _ => ()
    }
    i += 1
  }
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
    let initial_message = if amend {
      get_head_commit_message(fs, root)
    } else {
      None
    }
    message = read_commit_message_from_editor(fs, root, initial_message~)
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
  let committer = default_author
  let committer_timestamp = default_timestamp
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
    )
  }
  let short_id = (try! commit_id.to_hex()[:7]).to_string()
  let first_line = match msg.find("\n") {
    Some(idx) => (try! msg[:idx]).to_string()
    None => msg
  }
  let git_dir = root + "/.git"
  // Show subdir-clone context if applicable
  match get_subdir_info(fs, git_dir) {
    Some((_, path, _)) =>
      print_line("[" + short_id + " (subdir: " + path + ")] " + first_line)
    None => print_line("[" + short_id + "] " + first_line)
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

///|
fn get_head_commit_message(fs : &@git.RepoFileSystem, root : String) -> String? {
  let git_dir = root + "/.git"
  let head = @gitlib.resolve_head_commit(fs, git_dir) catch { _ => return None }
  guard head is Some(commit_id) else { return None }
  let db = @gitlib.ObjectDb::load(fs, git_dir) catch { _ => return None }
  let obj = db.get(fs, commit_id) catch { _ => return None }
  guard obj is Some(o) else { return None }
  // Extract message from raw commit data (after blank line)
  let text = decode_bytes(o.data)
  let mut in_message = false
  let msg_lines : Array[String] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      msg_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
    }
  }
  if msg_lines.length() > 0 {
    Some(msg_lines.join("\n"))
  } else {
    None
  }
}

///|
async fn handle_log(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let mut oneline = false
  let mut graph = false
  let mut all_refs = false
  let mut decorate = false
  let mut show_stat = false
  let mut show_patch = false
  let mut max_count = 10
  let mut since_ts = 0L
  let mut until_ts = 9223372036854775807L
  for arg in args {
    match arg {
      "--oneline" => oneline = true
      "--graph" => graph = true
      "--all" => all_refs = true
      "--decorate" => decorate = true
      "--stat" => show_stat = true
      "-p" | "--patch" => show_patch = true
      _ if arg.has_prefix("-n") => {
        let num_str = (try! arg[2:]).to_string()
        max_count = @strconv.parse_int(num_str)
      }
      _ if arg.has_prefix("--max-count=") => {
        let num_str = (try! arg[12:]).to_string()
        max_count = @strconv.parse_int(num_str)
      }
      _ if arg.has_prefix("--since=") => {
        let val = (try! arg[8:]).to_string()
        since_ts = @strconv.parse_int64(val) catch { _ => 0L }
      }
      _ if arg.has_prefix("--until=") => {
        let val = (try! arg[8:]).to_string()
        until_ts = @strconv.parse_int64(val) catch { _ => 9223372036854775807L }
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("log", arg)
      _ => ()
    }
  }
  // Show subdir-clone info if applicable (only in full format)
  if not(oneline) {
    match get_subdir_info(fs, git_dir) {
      Some((remote, path, base)) => {
        print_line("# subdir-clone: \{path} from \{remote}")
        print_line("# base: \{base[:7].to_string()}")
        print_line("")
      }
      None => ()
    }
  }
  if graph {
    log_with_graph(rfs, git_dir, max_count, oneline, all_refs, decorate)
  } else if oneline {
    let lines = @gitlib.log_head_oneline(
      fs,
      git_dir,
      max_count~,
      since=since_ts,
      until=until_ts,
    )
    for line in lines {
      print_line(line)
    }
  } else {
    let entries = @gitlib.log_head(
      fs,
      git_dir,
      max_count~,
      since=since_ts,
      until=until_ts,
    )
    for entry in entries {
      print_line("commit " + entry.id.to_hex())
      print_line("Author: " + entry.author)
      print_line("")
      print_line("    " + entry.message)
      print_line("")
      if show_stat || show_patch {
        let diff_files = @gitlib.diff_trees(
          rfs,
          git_dir,
          entry.parent_tree,
          entry.tree,
        )
        if show_stat {
          let stat_lines = @gitlib.diff_stat(diff_files)
          for line in stat_lines {
            print_line(line)
          }
          print_line("")
        }
        if show_patch {
          let patch_lines = @gitlib.diff_text(diff_files)
          for line in patch_lines {
            print_line(line)
          }
          print_line("")
        }
      }
    }
  }
}

///|
async fn log_with_graph(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  max_count : Int,
  oneline : Bool,
  all_refs : Bool,
  decorate : Bool,
) -> Unit raise Error {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  // Collect starting points
  let starts : Array[@git.ObjectId] = []
  let ref_names : Map[String, Array[String]] = {} // commit hex -> ref names
  if all_refs {
    // Add all branches
    let heads_dir = git_dir + "/refs/heads"
    if rfs.is_dir(heads_dir) {
      let branches = rfs.readdir(heads_dir) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => []
      }
      for branch in branches {
        let ref_path = heads_dir + "/" + branch
        if rfs.is_file(ref_path) {
          let hex = rfs.read_file(ref_path) |> decode_bytes |> trim_string
          let id = @git.ObjectId::from_hex(hex)
          starts.push(id)
          match ref_names.get(hex) {
            Some(arr) => arr.push(branch)
            None => ref_names[hex] = [branch]
          }
        }
      }
    }
  } else {
    let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
    match head {
      Some(h) => {
        starts.push(h)
        if decorate {
          // Get current branch name
          let head_path = git_dir + "/HEAD"
          if rfs.is_file(head_path) {
            let content = rfs.read_file(head_path)
              |> decode_bytes
              |> trim_string
            if content.has_prefix("ref: refs/heads/") {
              let branch = String::unsafe_substring(
                content,
                start=16,
                end=content.length(),
              )
              ref_names[h.to_hex()] = ["HEAD -> " + branch]
            } else {
              ref_names[h.to_hex()] = ["HEAD"]
            }
          }
        }
      }
      None => return
    }
  }
  // BFS to collect commits with graph structure
  let commits : Array[(@git.ObjectId, Array[@git.ObjectId], Int)] = [] // (id, parents, column)
  let visited : Map[String, Bool] = {}
  let active_columns : Array[@git.ObjectId?] = [] // Track which columns are active
  let queue : Array[(@git.ObjectId, Int)] = [] // (commit, column)
  // Initialize queue
  for i, start in starts {
    queue.push((start, i))
    while active_columns.length() <= i {
      active_columns.push(None)
    }
    active_columns[i] = Some(start)
  }
  let mut count = 0
  while queue.length() > 0 && count < max_count {
    // Sort queue by column to process in order
    queue.sort_by((a, b) => a.1.compare(b.1))
    let (current, col) = queue[0]
    // Remove first element
    let new_queue : Array[(@git.ObjectId, Int)] = []
    for i in 1..<queue.length() {
      new_queue.push(queue[i])
    }
    while queue.length() > 0 {
      ignore(queue.pop())
    }
    for item in new_queue {
      queue.push(item)
    }
    let hex = current.to_hex()
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    count += 1
    let obj = db.get(rfs, current)
    match obj {
      Some(o) => {
        let info = @git.parse_commit(o.data)
        commits.push((current, info.parents, col))
        // Add parents to queue
        for i, parent in info.parents {
          let parent_col = if i == 0 {
            col
          } else {
            find_free_column(active_columns, col)
          }
          queue.push((parent, parent_col))
          if parent_col < active_columns.length() {
            active_columns[parent_col] = Some(parent)
          }
        }
        // Clear this column if no more commits
        if info.parents.length() == 0 && col < active_columns.length() {
          active_columns[col] = None
        }
      }
      None => ()
    }
  }
  // Output with graph
  let max_col = get_max_column(commits)
  for entry in commits {
    let (commit_id, parents, col) = entry
    let hex = commit_id.to_hex()
    let short_hex = String::unsafe_substring(hex, start=0, end=7)
    // Build graph line
    let graph_line = build_graph_line(col, max_col, parents.length() > 1)
    // Get decorations
    let decorations = match ref_names.get(hex) {
      Some(names) => " (" + names.join(", ") + ")"
      None => ""
    }
    if oneline {
      print_line(
        graph_line +
        "* " +
        short_hex +
        decorations +
        " " +
        get_commit_subject(db, rfs, commit_id),
      )
    } else {
      print_line(graph_line + "* commit " + hex + decorations)
      let obj = db.get(rfs, commit_id)
      match obj {
        Some(o) => {
          let author_line = extract_author_line_from_bytes(o.data)
          print_line(graph_line + "| Author: " + author_line)
          print_line(graph_line + "|")
          let msg = get_commit_subject(db, rfs, commit_id)
          print_line(graph_line + "|     " + msg)
          print_line(graph_line + "|")
        }
        None => ()
      }
    }
  }
}

///|
fn find_free_column(columns : Array[@git.ObjectId?], start : Int) -> Int {
  for i in (start + 1)..<columns.length() {
    if columns[i] is None {
      return i
    }
  }
  columns.length()
}

///|
fn get_max_column(
  commits : Array[(@git.ObjectId, Array[@git.ObjectId], Int)],
) -> Int {
  let mut max = 0
  for entry in commits {
    if entry.2 > max {
      max = entry.2
    }
  }
  max
}

///|
fn build_graph_line(col : Int, max_col : Int, is_merge : Bool) -> String {
  let sb = StringBuilder::new()
  for _ in 0..<col {
    sb.write_string("| ")
  }
  if is_merge {
    sb.write_string("|\\ ")
  }
  for _ in (col + 1)..<(max_col + 1) {
    sb.write_string("| ")
  }
  sb.to_string()
}

///|
fn get_commit_subject(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> String raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return "" }
  let msg = extract_commit_message(o.data)
  get_first_line(msg)
}

///|
fn extract_author_line_from_bytes(data : Bytes) -> String {
  let text = decode_bytes(data)
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("author ") {
      return String::unsafe_substring(line, start=7, end=line.length())
    }
    if line.length() == 0 {
      break
    }
  }
  "unknown"
}

///|
priv struct ShowCommitInfo {
  author : String
  timestamp : Int64
  message : String
}

///|
fn parse_show_commit(data : Bytes) -> ShowCommitInfo {
  let text = decode_bytes(data)
  let mut author = ""
  let mut timestamp = 0L
  let mut in_message = false
  let message_lines : Array[String] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      message_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
      continue
    }
    if line.has_prefix("author ") {
      let rest = String::unsafe_substring(line, start=7, end=line.length())
      // format: Name <email> 1700000000 +0000
      let mut last_space = rest.rev_find(" ")
      if last_space is Some(tz_idx) {
        let before_tz = String::unsafe_substring(rest, start=0, end=tz_idx)
        last_space = before_tz.rev_find(" ")
        if last_space is Some(time_idx) {
          author = String::unsafe_substring(before_tz, start=0, end=time_idx)
          let time_str = String::unsafe_substring(
            before_tz,
            start=time_idx + 1,
            end=before_tz.length(),
          )
          for c in time_str {
            if c >= '0' && c <= '9' {
              let digit = c.to_int() - '0'.to_int()
              timestamp = timestamp * 10L + digit.to_int64()
            }
          }
        } else {
          author = before_tz
        }
      } else {
        author = rest
      }
    }
  }
  let message = message_lines.join("\n")
  { author, timestamp, message }
}

///|
async fn handle_show(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse: git show [--pretty=<format>] [<commit>]
  let mut rev = "HEAD"
  let mut pretty_raw = false
  for arg in args {
    if arg == "--pretty=raw" || arg == "--format=raw" {
      pretty_raw = true
    } else if not(arg.has_prefix("-")) {
      rev = arg
    } else {
      warn_unimplemented_arg("show", arg)
    }
  }
  // Resolve revision
  let id = @gitlib.rev_parse(fs, git_dir, rev)
  guard id is Some(commit_id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{rev}")
  }
  // Load object
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, commit_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject(
      "Object not found: \{commit_id.to_hex()}",
    )
  }
  if o.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Not a commit: \{commit_id.to_hex()}")
  }
  // Parse commit for tree/parents
  let commit_info = @git.parse_commit(o.data)
  // If --pretty=raw, output raw commit object content
  if pretty_raw {
    print_line("commit \{commit_id.to_hex()}")
    // Output the raw commit object as text
    let text = decode_bytes(o.data)
    print_str(text)
    if not(text.has_suffix("\n")) {
      print_line("")
    }
    return ()
  }
  // Parse full commit details
  let show_info = parse_show_commit(o.data)
  // Print commit info
  print_line("commit \{commit_id.to_hex()}")
  print_line("Author: \{show_info.author}")
  print_line("Date:   \{show_info.timestamp}")
  print_line("")
  // Print message with indentation
  for line_view in show_info.message.split("\n") {
    print_line("    \{line_view.to_string()}")
  }
  print_line("")
  // Show diff against parent (simplified)
  if commit_info.parents.length() > 0 {
    let parent_id = commit_info.parents[0]
    let parent_files = @gitlib.collect_tree_files_from_commit(db, fs, parent_id)
    let current_files = @gitlib.collect_tree_files_from_commit(
      db, fs, commit_id,
    )
    // Show changed files
    for item in current_files.to_array() {
      let (path, entry) = item
      match parent_files.get(path) {
        None => print_line("diff --git a/\{path} b/\{path}\nnew file")
        Some(parent_entry) =>
          if entry.id != parent_entry.id {
            print_line("diff --git a/\{path} b/\{path}")
          }
      }
    }
    for item in parent_files.to_array() {
      let (path, _) = item
      if not(current_files.contains(path)) {
        print_line("diff --git a/\{path} b/\{path}\ndeleted file")
      }
    }
  }
}
