///|

///|
async fn show_log_command_help() -> Unit {
  show_simple_command_help(
    "git log [<options>] [<revision-range>] [--] [<pathspec>...]",
    summary="Show commit logs.",
  )
}

///|
fn is_short_count_flag(arg : String) -> Bool {
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
fn format_log_oneline(
  fmt : String,
  id : @git.ObjectId,
  subject : String,
) -> String {
  let short = (try! id.to_hex()[:7]).to_string()
  match fmt {
    "%h %s" => short + " " + subject
    "%h" => short
    "%H" => id.to_hex()
    "%H %s" => id.to_hex() + " " + subject
    "%s" => subject
    _ => short + " " + subject
  }
}

///|
fn resolve_log_reflog_refname(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  rev : String,
) -> String? {
  if rev == "HEAD" {
    return Some("HEAD")
  }
  if rev.has_prefix("refs/") {
    return Some(rev)
  }
  let heads_ref = "refs/heads/" + rev
  if (@gitlib.resolve_ref(rfs, git_dir, heads_ref) catch { _ => None })
    is Some(_) {
    return Some(heads_ref)
  }
  let tags_ref = "refs/tags/" + rev
  if (@gitlib.resolve_ref(rfs, git_dir, tags_ref) catch { _ => None })
    is Some(_) {
    return Some(tags_ref)
  }
  let remotes_ref = "refs/remotes/" + rev
  if (@gitlib.resolve_ref(rfs, git_dir, remotes_ref) catch { _ => None })
    is Some(_) {
    return Some(remotes_ref)
  }
  if (@gitlib.resolve_ref(rfs, git_dir, rev) catch { _ => None }) is Some(_) {
    return Some(rev)
  }
  None
}

///|
fn shorten_reflog_refname(refname : String) -> String {
  if refname.has_prefix("refs/heads/") {
    String::unsafe_substring(refname, start=11, end=refname.length())
  } else if refname.has_prefix("refs/tags/") {
    String::unsafe_substring(refname, start=10, end=refname.length())
  } else if refname.has_prefix("refs/remotes/") {
    String::unsafe_substring(refname, start=13, end=refname.length())
  } else {
    refname
  }
}

///|
fn format_reflog_entry(fmt : String?, gd : String, message : String) -> String {
  match fmt {
    Some("%gd") => gd
    Some("%gs") => message
    Some("%gd %gs") => gd + " " + message
    Some(_) => gd + " " + message
    None => gd + " " + message
  }
}

///|
fn get_head_commit_message(fs : &@git.RepoFileSystem, root : String) -> String? {
  let git_dir = resolve_git_dir(fs, root)
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
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(fs, root)
  let mut oneline = false
  let mut graph = false
  let mut all_refs = false
  let mut decorate = false
  let mut show_stat = false
  let mut show_patch = false
  let mut max_count = 10
  let mut since_ts = 0L
  let mut until_ts = 9223372036854775807L
  let mut no_walk = false
  let mut walk_reflogs = false
  let mut format : String? = None
  let revs : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--oneline" => oneline = true
      "--graph" => graph = true
      "--all" => all_refs = true
      "--no-walk" => no_walk = true
      "-g" | "--walk-reflogs" => walk_reflogs = true
      "--decorate" => decorate = true
      "--stat" => show_stat = true
      "-p" | "--patch" => show_patch = true
      "--format" if i + 1 < args.length() => {
        format = Some(args[i + 1])
        i += 1
      }
      "--pretty" if i + 1 < args.length() => {
        format = Some(args[i + 1])
        i += 1
      }
      "-n" if i + 1 < args.length() => {
        max_count = @strconv.parse_int(args[i + 1])
        i += 1
      }
      "--max-count" if i + 1 < args.length() => {
        max_count = @strconv.parse_int(args[i + 1])
        i += 1
      }
      "--since" if i + 1 < args.length() => {
        since_ts = @strconv.parse_int64(args[i + 1]) catch { _ => 0L }
        i += 1
      }
      "--until" if i + 1 < args.length() => {
        until_ts = @strconv.parse_int64(args[i + 1]) catch {
          _ => 9223372036854775807L
        }
        i += 1
      }
      _ if arg.has_prefix("--format=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        format = Some(value)
      }
      _ if arg.has_prefix("--pretty=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        format = Some(value)
      }
      _ if arg.has_prefix("-n") && arg.length() > 2 => {
        let num_str = (try! arg[2:]).to_string()
        max_count = @strconv.parse_int(num_str)
      }
      _ if is_short_count_flag(arg) => {
        let num_str = String::unsafe_substring(arg, start=1, end=arg.length())
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
      _ => revs.push(arg)
    }
    i += 1
  }
  if walk_reflogs {
    let targets : Array[String] = if revs.length() > 0 {
      revs
    } else {
      ["HEAD"]
    }
    let mut emitted = 0
    for target in targets {
      if emitted >= max_count {
        break
      }
      let refname = resolve_log_reflog_refname(rfs, git_dir, target)
      guard refname is Some(actual_refname) else {
        raise @git.GitError::InvalidObject("Unknown revision: " + target)
      }
      let display_ref = if target.has_prefix("refs/") {
        shorten_reflog_refname(actual_refname)
      } else {
        target
      }
      let entries = @gitrepo.read_reflog(rfs, git_dir, actual_refname)
      let mut idx = 0
      let mut entry_i = entries.length()
      while entry_i > 0 && emitted < max_count {
        entry_i -= 1
        let entry = entries[entry_i]
        let gd = display_ref + "@{" + idx.to_string() + "}"
        print_line(format_reflog_entry(format, gd, entry.message))
        emitted += 1
        idx += 1
      }
    }
    return
  }
  if format is Some(fmt) {
    let db = @gitlib.ObjectDb::load(rfs, git_dir)
    let targets : Array[(String, @git.ObjectId)] = []
    if all_refs || no_walk {
      let refs = @gitlib.list_refs_with_ids(rfs, git_dir, None)
      for name, id in refs {
        targets.push((name, id))
      }
      targets.sort_by((a, b) => a.0.compare(b.0))
    }
    for rev in revs {
      let resolved = @gitrepo.rev_parse(rfs, git_dir, rev)
      guard resolved is Some(id) else {
        raise @git.GitError::InvalidObject("Unknown revision: " + rev)
      }
      targets.push((rev, id))
    }
    if targets.length() == 0 {
      let head = @gitrepo.rev_parse(rfs, git_dir, "HEAD")
      guard head is Some(id) else { return }
      targets.push(("HEAD", id))
    }
    let seen : Map[String, Bool] = {}
    let mut emitted = 0
    for target in targets {
      if emitted >= max_count {
        break
      }
      let id = target.1
      let hex = id.to_hex()
      if seen.contains(hex) {
        continue
      }
      seen[hex] = true
      let subject = get_commit_subject(db, rfs, id)
      print_line(format_log_oneline(fmt, id, subject))
      emitted += 1
    }
    return
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
        let diff_files = @gitdiff.diff_trees(
          rfs,
          git_dir,
          entry.parent_tree,
          entry.tree,
        )
        if show_stat {
          let stat_lines = @gitdiff.diff_stat(diff_files)
          for line in stat_lines {
            print_line(line)
          }
          print_line("")
        }
        if show_patch {
          let patch_lines = @gitdiff.diff_text(diff_files)
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
    let head = @gitrepo.rev_parse(rfs, git_dir, "HEAD")
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
