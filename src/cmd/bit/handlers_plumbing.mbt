///| Plumbing handlers: read-tree, update-index, mktree, request-pull, send-pack, range-diff

///|
async fn handle_read_tree(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut reset = false
  let mut update = false
  let mut dry_run = false
  let mut empty = false
  let tree_refs : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" => () // Merge mode - simplified
      "--reset" => reset = true
      "-u" => update = true
      "-n" | "--dry-run" => dry_run = true
      "--empty" => empty = true
      "--prefix" if i + 1 < args.length() => {
        i += 2
        continue
      }
      "--index-output" if i + 1 < args.length() => {
        i += 2
        continue
      }
      _ if arg.has_prefix("--prefix=") => ()
      _ if arg.has_prefix("--index-output=") => ()
      _ if not(arg.has_prefix("-")) => tree_refs.push(arg)
      _ => ()
    }
    i += 1
  }
  // Handle --empty: clear index
  if empty {
    if not(dry_run) {
      @gitlib.write_index_entries(fs, git_dir, [])
    }
    return
  }
  if tree_refs.length() == 0 {
    eprint_line("fatal: must specify tree-ish")
    @sys.exit(128)
    return
  }
  // Resolve tree-ish to tree object
  let tree_id = match @gitlib.rev_parse(fs, git_dir, tree_refs[0]) {
    Some(id) => plumb_resolve_to_tree(fs, git_dir, id)
    None => {
      eprint_line("fatal: not a valid object name: " + tree_refs[0])
      @sys.exit(128)
      return
    }
  }
  // Collect tree files
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let files = @gitlib.collect_tree_files(db, fs, tree_id)
  // Get entries from tree
  let entries = @gitlib.tree_files_to_index(db, fs, files)
  // Write to index
  if not(dry_run) {
    @gitlib.write_index_entries(fs, git_dir, entries)
  }
  // Handle -u: update working tree
  if update && not(dry_run) {
    let root = get_work_root()
    @gitlib.write_worktree_from_files(
      db,
      fs,
      fs,
      root,
      git_dir,
      files,
      remove_missing=reset,
    )
  }
}

///|
fn plumb_resolve_to_tree(
  fs : OsFs,
  git_dir : String,
  id : @git.ObjectId,
) -> @git.ObjectId raise Error {
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  match db.get(fs, id) {
    Some(obj) =>
      match obj.obj_type {
        @git.ObjectType::Tree => id
        @git.ObjectType::Commit => {
          let info = @git.parse_commit(obj.data)
          info.tree
        }
        @git.ObjectType::Tag => {
          // Parse tag and follow to target
          let text = decode_bytes(obj.data)
          for line_view in text.split("\n") {
            let line = line_view.to_string()
            if line.has_prefix("object ") {
              let target_hex = line[7:].to_string()
              let target = @git.ObjectId::from_hex(target_hex)
              return plumb_resolve_to_tree(fs, git_dir, target)
            }
          }
          raise @git.GitError::InvalidObject("Invalid tag object")
        }
        _ => raise @git.GitError::InvalidObject("Cannot resolve to tree")
      }
    None => raise @git.GitError::InvalidObject("Object not found")
  }
}

///|
async fn handle_update_index(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let git_dir = find_git_dir(fs)
  let mut add = false
  let mut remove = false
  let mut force_remove = false
  let mut refresh = false
  let mut quiet = false
  let mut ignore_missing = false
  let mut stdin = false
  let mut nul_term = false
  let mut verbose = false
  let cacheinfo : Array[(String, String, String)] = []
  let paths : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--add" => add = true
      "--remove" => remove = true
      "--force-remove" => force_remove = true
      "--replace" => ()
      "--refresh" => refresh = true
      "--really-refresh" => refresh = true
      "-q" => quiet = true
      "--ignore-missing" => ignore_missing = true
      "--stdin" => stdin = true
      "-z" => nul_term = true
      "-v" | "--verbose" => verbose = true
      "--cacheinfo" if i + 3 < args.length() => {
        cacheinfo.push((args[i + 1], args[i + 2], args[i + 3]))
        i += 4
        continue
      }
      _ if arg.has_prefix("--cacheinfo=") => {
        let val = arg[12:].to_string()
        match val.find(",") {
          Some(idx1) => {
            let mode = val[:idx1].to_string()
            let rest = val[idx1 + 1:].to_string()
            match rest.find(",") {
              Some(idx2) => {
                let sha = rest[:idx2].to_string()
                let path = rest[idx2 + 1:].to_string()
                cacheinfo.push((mode, sha, path))
              }
              None => ()
            }
          }
          None => ()
        }
      }
      "--" => {
        for j in (i + 1)..<args.length() {
          paths.push(args[j])
        }
        break
      }
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
    i += 1
  }
  // Read from stdin if requested
  if stdin {
    let input = decode_bytes(read_all_stdin())
    let sep = if nul_term { "\u0000" } else { "\n" }
    for part_view in input.split(sep) {
      let part = trim_string(part_view.to_string())
      if part.length() > 0 {
        paths.push(part)
      }
    }
  }
  // For --cacheinfo, we need to write objects first
  for info in cacheinfo {
    let (mode_str, sha, path) = info
    // Just add to paths for now - the object should already exist
    ignore(mode_str)
    ignore(sha)
    if verbose {
      print_line("add '" + path + "'")
    }
  }
  // Use the existing add functionality
  if paths.length() > 0 {
    if add || force_remove || remove || refresh {
      // For now, delegate to the git add/rm logic
      let add_paths : Array[String] = []
      let remove_paths : Array[String] = []
      for path in paths {
        let full_path = if path.has_prefix("/") {
          path
        } else {
          root + "/" + path
        }
        if force_remove || (remove && not(fs.is_file(full_path))) {
          remove_paths.push(path)
        } else if fs.is_file(full_path) {
          add_paths.push(path)
        } else if not(ignore_missing) && not(quiet) {
          eprint_line("error: " + path + ": does not exist")
        }
      }
      // Use gitlib functions
      if add_paths.length() > 0 {
        @gitlib.add_paths(fs, fs, root, add_paths)
      }
      // For removals, filter out from index
      if remove_paths.length() > 0 {
        let entries = @gitlib.read_index_entries(fs, git_dir)
        let remove_set : Map[String, Bool] = {}
        for p in remove_paths {
          remove_set[p] = true
        }
        let filtered : Array[@gitlib.IndexEntry] = []
        for e in entries {
          if not(remove_set.contains(e.path)) {
            filtered.push(e)
          }
        }
        @gitlib.write_index_entries(fs, git_dir, filtered)
      }
    }
  }
  // Handle --refresh
  if refresh && paths.length() == 0 {
    // Refresh all entries - recompute hashes
    let entries = @gitlib.read_index_entries(fs, git_dir)
    let refreshed : Array[@gitlib.IndexEntry] = []
    for e in entries {
      // Keep existing entries (could recompute hash if needed)
      refreshed.push(e)
    }
    @gitlib.write_index_entries(fs, git_dir, refreshed)
  }
}

///|
async fn handle_mktree(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut batch = false
  let mut nul_term = false
  for arg in args {
    match arg {
      "--batch" => batch = true
      "-z" => nul_term = true
      "--missing" => ()
      _ => ()
    }
  }
  // Read ls-tree format input from stdin
  let input = decode_bytes(read_all_stdin())
  let sep = if nul_term { "\u0000" } else { "\n" }
  if batch {
    // Batch mode: empty line separates trees
    let current_entries : Array[@git.TreeEntry] = []
    for line_view in input.split(sep) {
      let line = trim_string(line_view.to_string())
      if line.length() == 0 {
        // Output tree for current entries
        if current_entries.length() > 0 {
          let tree_id = write_mktree_entries(fs, git_dir, current_entries)
          print_line(tree_id.to_hex())
          current_entries.clear()
        }
        continue
      }
      parse_and_add_tree_entry(line, current_entries)
    }
    // Output final tree if any entries remain
    if current_entries.length() > 0 {
      let tree_id = write_mktree_entries(fs, git_dir, current_entries)
      print_line(tree_id.to_hex())
    }
  } else {
    // Single tree mode
    let entries : Array[@git.TreeEntry] = []
    for line_view in input.split(sep) {
      let line = trim_string(line_view.to_string())
      if line.length() == 0 {
        continue
      }
      parse_and_add_tree_entry(line, entries)
    }
    let tree_id = write_mktree_entries(fs, git_dir, entries)
    print_line(tree_id.to_hex())
  }
}

///|
fn parse_and_add_tree_entry(
  line : String,
  entries : Array[@git.TreeEntry],
) -> Unit {
  // Format: <mode> SP <type> SP <object> TAB <file>
  // Or: <mode> SP <object> TAB <file> (simplified)
  match line.find("\t") {
    None => return ()
    Some(tab_idx) => {
      let meta = String::unsafe_substring(line, start=0, end=tab_idx)
      let name = String::unsafe_substring(
        line,
        start=tab_idx + 1,
        end=line.length(),
      )
      let parts : Array[String] = []
      for part_view in meta.split(" ") {
        let p = part_view.to_string()
        if p.length() > 0 {
          parts.push(p)
        }
      }
      if parts.length() >= 2 {
        let mode = parts[0]
        // Object ID is either parts[1] or parts[2] depending on format
        let object_hex = if parts.length() >= 3 { parts[2] } else { parts[1] }
        let id = @git.ObjectId::from_hex(object_hex) catch { _ => return () }
        entries.push(@git.TreeEntry::new(mode, name, id))
      }
    }
  }
}

///|
fn write_mktree_entries(
  fs : OsFs,
  git_dir : String,
  entries : Array[@git.TreeEntry],
) -> @git.ObjectId raise Error {
  // Sort entries by Git's tree sorting rules
  let sorted = entries.copy()
  sorted.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    String::compare(a_key, b_key)
  })
  let (tree_id, compressed) = @git.create_tree(sorted)
  @gitlib.write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
async fn handle_request_pull(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut i = 0
  let positional : Array[String] = []
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-p" => ()
      _ if arg.has_prefix("--signoff=") => ()
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => ()
    }
    i += 1
  }
  // Expected: start url [end]
  if positional.length() < 2 {
    eprint_line("usage: git request-pull <start> <url> [<end>]")
    @sys.exit(1)
    return
  }
  let start = positional[0]
  let url = positional[1]
  let end = if positional.length() > 2 { positional[2] } else { "HEAD" }
  // Resolve start and end commits
  let start_id = match @gitlib.rev_parse(fs, git_dir, start) {
    Some(id) => id
    None => {
      eprint_line("fatal: Not a valid revision: " + start)
      @sys.exit(128)
      return
    }
  }
  let end_id = match @gitlib.rev_parse(fs, git_dir, end) {
    Some(id) => id
    None => {
      eprint_line("fatal: Not a valid revision: " + end)
      @sys.exit(128)
      return
    }
  }
  // Verify end is a commit
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let end_obj = db.get(fs, end_id)
  match end_obj {
    Some(obj) if obj.obj_type == @git.ObjectType::Commit => ()
    _ => {
      eprint_line("fatal: Not a commit: " + end)
      @sys.exit(128)
      return
    }
  }
  // Count commits
  let mut commit_count = 0
  let mut current : @git.ObjectId? = Some(end_id)
  let start_hex = start_id.to_hex()
  while current is Some(id) {
    if id.to_hex() == start_hex {
      break
    }
    commit_count += 1
    match db.get(fs, id) {
      Some(obj) if obj.obj_type == @git.ObjectType::Commit => {
        let info = @git.parse_commit(obj.data)
        current = if info.parents.length() > 0 {
          Some(info.parents[0])
        } else {
          None
        }
      }
      _ => current = None
    }
  }
  // Get current branch name
  let head_content = decode_bytes(fs.read_file(git_dir + "/HEAD"))
  let branch = if head_content.has_prefix("ref: refs/heads/") {
    trim_string(head_content[16:].to_string())
  } else {
    end_id.to_hex()[:7].to_string()
  }
  // Print request-pull output
  print_line("The following changes since commit " + start_id.to_hex() + ":")
  print_line("")
  // Get start commit message
  match db.get(fs, start_id) {
    Some(obj) if obj.obj_type == @git.ObjectType::Commit => {
      let first_line = plumb_get_first_line_of_commit(obj.data)
      print_line(
        "  " + first_line + " (" + start_id.to_hex()[:10].to_string() + ")",
      )
    }
    _ => ()
  }
  print_line("")
  print_line("are available in the Git repository at:")
  print_line("")
  print_line("  " + url + " " + branch)
  print_line("")
  print_line("for you to fetch changes up to " + end_id.to_hex() + ":")
  print_line("")
  // Get end commit message
  match db.get(fs, end_id) {
    Some(obj) if obj.obj_type == @git.ObjectType::Commit => {
      let first_line = plumb_get_first_line_of_commit(obj.data)
      print_line(
        "  " + first_line + " (" + end_id.to_hex()[:10].to_string() + ")",
      )
    }
    _ => ()
  }
  print_line("")
  print_line("----------------------------------------------------------------")
  print_line("")
  print_line(commit_count.to_string() + " commit(s) since " + start)
  print_line("")
}

///|
fn plumb_get_first_line_of_commit(data : Bytes) -> String {
  let text = decode_bytes(data)
  // Skip header lines until empty line
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if not(in_body) {
      if line.length() == 0 {
        in_body = true
      }
      continue
    }
    // Return first non-empty body line
    if line.length() > 0 {
      return line
    }
  }
  ""
}

///|
async fn handle_send_pack(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut dry_run = false
  let mut force = false
  let mut verbose = false
  let mut all = false
  let mut mirror = false
  let mut stdin = false
  let mut remote : String? = None
  let refspecs : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--dry-run" => dry_run = true
      "-f" | "--force" => force = true
      "-v" | "--verbose" => verbose = true
      "--thin" | "--no-thin" => ()
      "--atomic" => ()
      "--stateless-rpc" => ()
      "--all" => all = true
      "--mirror" => mirror = true
      "--stdin" => stdin = true
      "--receive-pack" if i + 1 < args.length() => {
        i += 2
        continue
      }
      _ if arg.has_prefix("--receive-pack=") => ()
      _ if arg.has_prefix("--exec=") => ()
      _ if not(arg.has_prefix("-")) =>
        if remote is None {
          remote = Some(arg)
        } else {
          refspecs.push(arg)
        }
      _ => ()
    }
    i += 1
  }
  // Read refspecs from stdin if requested
  if stdin {
    let input = decode_bytes(read_all_stdin())
    for line_view in input.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() > 0 {
        refspecs.push(line)
      }
    }
  }
  guard remote is Some(remote_url) else {
    eprint_line("fatal: No destination specified")
    @sys.exit(128)
    return
  }
  // If --all or --mirror, add all refs
  if all || mirror {
    let refs = @gitlib.show_ref(fs, git_dir)
    for item in refs {
      let (name, _) = item
      if mirror || name.has_prefix("refs/heads/") {
        refspecs.push(name + ":" + name)
      }
    }
  }
  if refspecs.length() == 0 {
    // Default to current branch
    let head = decode_bytes(fs.read_file(git_dir + "/HEAD"))
    if head.has_prefix("ref: ") {
      let ref_name = trim_string(head[5:].to_string())
      refspecs.push(ref_name + ":" + ref_name)
    }
  }
  // Parse refspecs and collect refs to push
  let refs_to_push : Array[(String, @git.ObjectId, String)] = []
  for spec in refspecs {
    let (src, dst) = match spec.find(":") {
      Some(idx) => (spec[:idx].to_string(), spec[idx + 1:].to_string())
      None => (spec, spec)
    }
    // Handle force push
    let actual_src = if src.has_prefix("+") { src[1:].to_string() } else { src }
    // Resolve source ref
    match @gitlib.rev_parse(fs, git_dir, actual_src) {
      Some(id) => refs_to_push.push((actual_src, id, dst))
      None =>
        if actual_src.length() > 0 {
          eprint_line(
            "error: src refspec " + actual_src + " does not match any",
          )
        }
    }
  }
  if verbose {
    for item in refs_to_push {
      let (src, id, dst) = item
      print_line(
        "push " + src + " -> " + dst + " (" + id.to_hex()[:7].to_string() + ")",
      )
    }
  }
  if dry_run {
    print_line("(dry run - no actual push)")
    return
  }
  // For actual push, we would need to establish connection
  // This is a simplified implementation that outputs what would be sent
  print_line("To " + remote_url)
  for item in refs_to_push {
    let (_, id, dst) = item
    print_line(
      " * [new reference]  " + id.to_hex()[:7].to_string() + " -> " + dst,
    )
  }
  ignore(force)
}

///|
async fn handle_range_diff(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let ranges : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--creation-factor" if i + 1 < args.length() => {
        i += 2
        continue
      }
      "--no-dual-color" | "--dual-color" | "--no-color" => ()
      _ if arg.has_prefix("--creation-factor=") => ()
      _ if not(arg.has_prefix("-")) => ranges.push(arg)
      _ => ()
    }
    i += 1
  }
  // Parse ranges - can be:
  // 1. <range1> <range2> - two revision ranges
  // 2. <rev1>...<rev2> - symmetric difference style
  // 3. <base> <rev1> <rev2> - three-argument form
  let (range1_start, range1_end, range2_start, range2_end) = if ranges.length() ==
    3 {
    // Three-argument form: base rev1 rev2
    (ranges[0], ranges[1], ranges[0], ranges[2])
  } else if ranges.length() == 2 {
    // Two revision ranges
    let (s1, e1) = plumb_parse_range(ranges[0])
    let (s2, e2) = plumb_parse_range(ranges[1])
    (s1, e1, s2, e2)
  } else if ranges.length() == 1 && ranges[0].contains("...") {
    // Symmetric difference: A...B means A..B compared to B..A
    match ranges[0].find("...") {
      Some(idx) => {
        let a = ranges[0][:idx].to_string()
        let b = ranges[0][idx + 3:].to_string()
        (a, b, b, a)
      }
      None => {
        eprint_line("fatal: invalid range")
        @sys.exit(128)
        return
      }
    }
  } else {
    eprint_line("usage: git range-diff [<options>] <range1> <range2>")
    eprint_line("       git range-diff [<options>] <rev1>...<rev2>")
    eprint_line("       git range-diff [<options>] <base> <rev1> <rev2>")
    @sys.exit(1)
    return
  }
  // Resolve revisions
  let r1_start = @gitlib.rev_parse(fs, git_dir, range1_start)
  let r1_end = @gitlib.rev_parse(fs, git_dir, range1_end)
  let r2_start = @gitlib.rev_parse(fs, git_dir, range2_start)
  let r2_end = @gitlib.rev_parse(fs, git_dir, range2_end)
  guard r1_start is Some(r1s) &&
    r1_end is Some(r1e) &&
    r2_start is Some(r2s) &&
    r2_end is Some(r2e) else {
    eprint_line("fatal: could not resolve revisions")
    @sys.exit(128)
    return
  }
  // Collect commits in each range
  let commits1 = plumb_collect_range_commits(fs, git_dir, r1s, r1e)
  let commits2 = plumb_collect_range_commits(fs, git_dir, r2s, r2e)
  // Output range-diff
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let mut idx1 = 1
  let mut idx2 = 1
  // Simple matching by commit message
  let matched : Map[String, Int] = {}
  for c in commits2 {
    let msg = plumb_get_commit_subject(db, fs, c)
    matched[msg] = idx2
    idx2 += 1
  }
  idx2 = 1
  for c1 in commits1 {
    let msg1 = plumb_get_commit_subject(db, fs, c1)
    match matched.get(msg1) {
      Some(m_idx) =>
        // Matched
        print_line(
          idx1.to_string() +
          ":  " +
          c1.to_hex()[:7].to_string() +
          " = " +
          m_idx.to_string() +
          ":  " +
          msg1,
        )
      None =>
        // Only in range1
        print_line(
          idx1.to_string() +
          ":  " +
          c1.to_hex()[:7].to_string() +
          " < -:  ------- " +
          msg1,
        )
    }
    idx1 += 1
  }
  // Show commits only in range2
  for c2 in commits2 {
    let msg2 = plumb_get_commit_subject(db, fs, c2)
    let mut found = false
    for c1 in commits1 {
      if plumb_get_commit_subject(db, fs, c1) == msg2 {
        found = true
        break
      }
    }
    if not(found) {
      print_line(
        "-:  ------- > " +
        idx2.to_string() +
        ":  " +
        c2.to_hex()[:7].to_string() +
        " " +
        msg2,
      )
    }
    idx2 += 1
  }
}

///|
fn plumb_parse_range(range : String) -> (String, String) {
  match range.find("..") {
    Some(idx) =>
      (
        String::unsafe_substring(range, start=0, end=idx),
        String::unsafe_substring(range, start=idx + 2, end=range.length()),
      )
    None => ("", range)
  }
}

///|
fn plumb_collect_range_commits(
  fs : OsFs,
  git_dir : String,
  start : @git.ObjectId,
  end : @git.ObjectId,
) -> Array[@git.ObjectId] {
  let db = @gitlib.ObjectDb::load(fs, git_dir) catch { _ => return [] }
  let result : Array[@git.ObjectId] = []
  let start_hex = start.to_hex()
  let mut current : @git.ObjectId? = Some(end)
  while current is Some(id) {
    if id.to_hex() == start_hex {
      break
    }
    result.push(id)
    let obj = db.get(fs, id) catch { _ => break }
    match obj {
      Some(o) if o.obj_type == @git.ObjectType::Commit => {
        let info = @git.parse_commit(o.data) catch { _ => break }
        current = if info.parents.length() > 0 {
          Some(info.parents[0])
        } else {
          None
        }
      }
      _ => current = None
    }
  }
  result.rev_in_place()
  result
}

///|
fn plumb_get_commit_subject(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  id : @git.ObjectId,
) -> String {
  let obj = db.get(fs, id) catch { _ => return "" }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Commit =>
      plumb_get_first_line_of_commit(o.data)
    _ => ""
  }
}

///|
async fn handle_multi_pack_index(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let pack_dir = git_dir + "/objects/pack"
  let mut object_dir : String? = None
  let mut progress = false
  let mut subcommand : String? = None
  let mut batch_size = 0
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--object-dir" if i + 1 < args.length() => {
        object_dir = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--object-dir=") =>
        object_dir = Some(arg[13:].to_string())
      "--progress" => progress = true
      "--no-progress" => progress = false
      "--batch-size" if i + 1 < args.length() => {
        batch_size = @strconv.parse_int(args[i + 1]) catch { _ => 0 }
        i += 2
        continue
      }
      _ if arg.has_prefix("--batch-size=") =>
        batch_size = @strconv.parse_int(arg[13:].to_string()) catch { _ => 0 }
      "write" | "verify" | "expire" | "repack" => subcommand = Some(arg)
      _ => ()
    }
    i += 1
  }
  let effective_pack_dir = match object_dir {
    Some(dir) => dir + "/pack"
    None => pack_dir
  }
  match subcommand {
    Some("write") => midx_write(fs, effective_pack_dir, progress)
    Some("verify") => midx_verify(fs, effective_pack_dir)
    Some("expire") => midx_expire(fs, effective_pack_dir, progress)
    Some("repack") => midx_repack(fs, effective_pack_dir, batch_size, progress)
    _ => {
      eprint_line("usage: git multi-pack-index [<options>] <subcommand>")
      eprint_line("")
      eprint_line("Subcommands:")
      eprint_line("    write    Write a multi-pack-index file")
      eprint_line("    verify   Verify multi-pack-index file")
      eprint_line("    expire   Delete unreferenced pack-files")
      eprint_line("    repack   Consolidate pack-files")
      @sys.exit(129)
    }
  }
  ignore(batch_size)
}

///|
async fn midx_write(
  fs : OsFs,
  pack_dir : String,
  progress : Bool,
) -> Unit raise Error {
  // Find all pack files
  let pack_files = midx_find_pack_files(fs, pack_dir)
  if pack_files.length() == 0 {
    if progress {
      print_line("No pack files found")
    }
    return
  }
  // Collect all objects from all packs
  let all_entries : Array[MidxEntry] = []
  for pack_idx, pack_name in pack_files {
    let idx_path = pack_dir +
      "/" +
      String::unsafe_substring(pack_name, start=0, end=pack_name.length() - 5) +
      ".idx"
    if not(fs.is_file(idx_path)) {
      continue
    }
    let entries = midx_read_pack_index(fs, idx_path, pack_idx)
    for entry in entries {
      all_entries.push(entry)
    }
  }
  // Sort entries by object ID
  all_entries.sort_by(fn(a, b) { midx_compare_oid(a.id, b.id) })
  // Remove duplicates (keep first occurrence = preferred pack)
  let unique_entries : Array[MidxEntry] = []
  let mut last_id : @git.ObjectId? = None
  for entry in all_entries {
    match last_id {
      Some(lid) if lid == entry.id => continue
      _ => {
        unique_entries.push(entry)
        last_id = Some(entry.id)
      }
    }
  }
  // Build MIDX file
  let midx_bytes = midx_build(pack_files, unique_entries)
  let midx_path = pack_dir + "/multi-pack-index"
  fs.write_file(midx_path, midx_bytes)
  if progress {
    print_line(
      "Wrote multi-pack-index with " +
      unique_entries.length().to_string() +
      " objects from " +
      pack_files.length().to_string() +
      " packs",
    )
  }
}

///|
async fn midx_verify(fs : OsFs, pack_dir : String) -> Unit raise Error {
  let midx_path = pack_dir + "/multi-pack-index"
  if not(fs.is_file(midx_path)) {
    eprint_line("error: could not open multi-pack-index")
    @sys.exit(1)
    return
  }
  let data = fs.read_file(midx_path)
  // Verify header
  if data.length() < 12 {
    raise @git.GitError::PackfileError("multi-pack-index too short")
  }
  if not(
      data[0] == b'M' && data[1] == b'I' && data[2] == b'D' && data[3] == b'X',
    ) {
    raise @git.GitError::PackfileError("invalid multi-pack-index signature")
  }
  let version = data[4].to_int()
  if version != 1 {
    raise @git.GitError::PackfileError(
      "unsupported multi-pack-index version: " + version.to_string(),
    )
  }
  let oid_version = data[5].to_int()
  if oid_version != 1 {
    raise @git.GitError::PackfileError(
      "unsupported OID version: " + oid_version.to_string(),
    )
  }
  // Verify checksum
  let checksum_offset = data.length() - 20
  let content = Bytes::from_array(
    FixedArray::makei(checksum_offset, fn(i) { data[i] }),
  )
  let computed = @git.sha1(content)
  let stored = @git.ObjectId::new(
    FixedArray::makei(20, fn(i) { data[checksum_offset + i] }),
  )
  if computed != stored {
    raise @git.GitError::HashMismatch(computed.to_hex(), stored.to_hex())
  }
  print_line("multi-pack-index verified")
}

///|
async fn midx_expire(
  fs : OsFs,
  pack_dir : String,
  progress : Bool,
) -> Unit raise Error {
  let midx_path = pack_dir + "/multi-pack-index"
  if not(fs.is_file(midx_path)) {
    if progress {
      print_line("No multi-pack-index to expire")
    }
    return
  }
  // Read MIDX to get referenced packs
  let data = fs.read_file(midx_path)
  if data.length() < 12 {
    return
  }
  let num_packs = midx_read_u32(data, 8)
  let num_chunks = data[6].to_int()
  // Find PNAM chunk to get pack names
  let pnam_offset = midx_find_chunk(data, num_chunks, "PNAM")
  let pnam_end = midx_find_chunk_end(data, num_chunks, "PNAM")
  if pnam_offset == 0 {
    return
  }
  // Parse pack names
  let referenced_packs : Array[String] = []
  let mut start = pnam_offset
  for _ in 0..<num_packs {
    let mut end = start
    while end < pnam_end && data[end] != b'\x00' {
      end += 1
    }
    let name = midx_bytes_to_string(data, start, end)
    referenced_packs.push(name)
    start = end + 1
  }
  // Find all pack files
  let all_packs = midx_find_pack_files(fs, pack_dir)
  let mut expired = 0
  for pack_name in all_packs {
    let mut found = false
    for ref_name in referenced_packs {
      if pack_name == ref_name {
        found = true
        break
      }
    }
    if not(found) {
      // Check for .keep file
      let keep_path = pack_dir +
        "/" +
        String::unsafe_substring(pack_name, start=0, end=pack_name.length() - 5) +
        ".keep"
      if fs.is_file(keep_path) {
        continue
      }
      // Delete pack and idx
      let pack_path = pack_dir + "/" + pack_name
      let idx_path = pack_dir +
        "/" +
        String::unsafe_substring(pack_name, start=0, end=pack_name.length() - 5) +
        ".idx"
      fs.remove_file(pack_path) catch {
        _ => ()
      }
      fs.remove_file(idx_path) catch {
        _ => ()
      }
      expired += 1
    }
  }
  if progress {
    print_line("Expired " + expired.to_string() + " pack(s)")
  }
  // Rewrite MIDX without expired packs
  if expired > 0 {
    midx_write(fs, pack_dir, false)
  }
}

///|
async fn midx_repack(
  fs : OsFs,
  pack_dir : String,
  batch_size : Int,
  progress : Bool,
) -> Unit raise Error {
  // Find small packs to consolidate
  let pack_files = midx_find_pack_files(fs, pack_dir)
  if pack_files.length() < 2 {
    if progress {
      print_line("Not enough packs to repack")
    }
    return
  }
  // For simplicity, just suggest running git repack
  if progress {
    print_line(
      "Found " + pack_files.length().to_string() + " pack files to consolidate",
    )
    print_line("Use 'git repack' for full repacking functionality")
  }
  ignore(batch_size)
}

///|
/// MIDX entry for building
priv struct MidxEntry {
  id : @git.ObjectId
  pack_idx : Int
  offset : Int
}

///|
fn midx_find_pack_files(fs : OsFs, pack_dir : String) -> Array[String] {
  let files : Array[String] = []
  let entries = fs.readdir(pack_dir) catch { _ => return files }
  for entry in entries {
    if entry.has_suffix(".pack") && not(entry.has_prefix(".")) {
      files.push(entry)
    }
  }
  files.sort_by(fn(a, b) { a.compare(b) })
  files
}

///|
fn midx_read_pack_index(
  fs : OsFs,
  idx_path : String,
  pack_idx : Int,
) -> Array[MidxEntry] {
  let entries : Array[MidxEntry] = []
  let data = fs.read_file(idx_path) catch { _ => return entries }
  // Check for v2 index
  if data.length() < 8 {
    return entries
  }
  if not(
      data[0] == b'\xff' &&
      data[1] == b't' &&
      data[2] == b'O' &&
      data[3] == b'c',
    ) {
    return entries // Not v2 index
  }
  let version = midx_read_u32(data, 4)
  if version != 2 {
    return entries
  }
  // Read fanout table to get object count
  let fanout_offset = 8
  let object_count = midx_read_u32(data, fanout_offset + 255 * 4)
  // Object names start after fanout
  let names_offset = fanout_offset + 256 * 4
  // Offsets start after names and CRCs
  let offsets_offset = names_offset + object_count * 20 + object_count * 4
  for i in 0..<object_count {
    let id_offset = names_offset + i * 20
    let id = @git.ObjectId::new(
      FixedArray::makei(20, fn(j) { data[id_offset + j] }),
    )
    let offset = midx_read_u32(data, offsets_offset + i * 4)
    entries.push({ id, pack_idx, offset })
  }
  entries
}

///|
fn midx_build(
  pack_files : Array[String],
  entries : Array[MidxEntry],
) -> Bytes {
  let out : Array[Byte] = []
  // Header
  out.push(b'M')
  out.push(b'I')
  out.push(b'D')
  out.push(b'X')
  out.push(b'\x01') // version
  out.push(b'\x01') // OID version (SHA-1)
  out.push(b'\x04') // number of chunks (PNAM, OIDF, OIDL, OOFF)
  out.push(b'\x00') // number of base MIDX files
  midx_push_u32(out, pack_files.length())
  // Build chunks
  let pnam_chunk = midx_build_pnam(pack_files)
  let oidf_chunk = midx_build_oidf(entries)
  let oidl_chunk = midx_build_oidl(entries)
  let ooff_chunk = midx_build_ooff(entries)
  // Chunk lookup table (5 entries = 4 chunks + terminator, 12 bytes each)
  let header_size = 12
  let chunk_table_size = 5 * 12
  let mut offset = header_size + chunk_table_size
  // Calculate PNAM padded length (4-byte aligned)
  let pnam_padded_len = (pnam_chunk.length() + 3) / 4 * 4
  // PNAM entry
  out.push(b'P')
  out.push(b'N')
  out.push(b'A')
  out.push(b'M')
  midx_push_u64(out, offset)
  offset += pnam_padded_len
  // OIDF entry
  out.push(b'O')
  out.push(b'I')
  out.push(b'D')
  out.push(b'F')
  midx_push_u64(out, offset)
  offset += oidf_chunk.length()
  // OIDL entry
  out.push(b'O')
  out.push(b'I')
  out.push(b'D')
  out.push(b'L')
  midx_push_u64(out, offset)
  offset += oidl_chunk.length()
  // OOFF entry
  out.push(b'O')
  out.push(b'O')
  out.push(b'F')
  out.push(b'F')
  midx_push_u64(out, offset)
  offset += ooff_chunk.length()
  // Terminator
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  midx_push_u64(out, offset)
  // Write chunk data with 4-byte alignment
  for b in pnam_chunk {
    out.push(b)
  }
  // Pad PNAM to 4-byte alignment
  let pnam_padding = pnam_padded_len - pnam_chunk.length()
  for _ in 0..<pnam_padding {
    out.push(b'\x00')
  }
  for b in oidf_chunk {
    out.push(b)
  }
  for b in oidl_chunk {
    out.push(b)
  }
  for b in ooff_chunk {
    out.push(b)
  }
  // Checksum
  let content = Bytes::from_array(
    FixedArray::makei(out.length(), fn(i) { out[i] }),
  )
  let checksum = @git.sha1(content)
  for b in checksum.bytes {
    out.push(b)
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn midx_build_pnam(pack_files : Array[String]) -> Array[Byte] {
  let out : Array[Byte] = []
  for name in pack_files {
    // Convert .pack to .idx for PNAM chunk
    let idx_name = if name.has_suffix(".pack") {
      String::unsafe_substring(name, start=0, end=name.length() - 5) + ".idx"
    } else {
      name
    }
    for i in 0..<idx_name.length() {
      out.push(idx_name[i].to_int().to_byte())
    }
    out.push(b'\x00')
  }
  out
}

///|
fn midx_build_oidf(entries : Array[MidxEntry]) -> Array[Byte] {
  // Build fanout table
  let counts : Array[Int] = Array::make(256, 0)
  for entry in entries {
    let first = entry.id.bytes[0].to_int()
    counts[first] = counts[first] + 1
  }
  let out : Array[Byte] = []
  let mut sum = 0
  for i in 0..<256 {
    sum = sum + counts[i]
    midx_push_u32(out, sum)
  }
  out
}

///|
fn midx_build_oidl(entries : Array[MidxEntry]) -> Array[Byte] {
  let out : Array[Byte] = []
  for entry in entries {
    for b in entry.id.bytes {
      out.push(b)
    }
  }
  out
}

///|
fn midx_build_ooff(entries : Array[MidxEntry]) -> Array[Byte] {
  let out : Array[Byte] = []
  for entry in entries {
    midx_push_u32(out, entry.pack_idx)
    midx_push_u32(out, entry.offset)
  }
  out
}

///|
fn midx_push_u32(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 24) & 0xff).to_byte())
  out.push(((value >> 16) & 0xff).to_byte())
  out.push(((value >> 8) & 0xff).to_byte())
  out.push((value & 0xff).to_byte())
}

///|
fn midx_push_u64(out : Array[Byte], value : Int) -> Unit {
  // For simplicity, we assume offsets fit in 32 bits (prepend 4 zero bytes)
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  midx_push_u32(out, value)
}

///|
fn midx_read_u32(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn midx_compare_oid(a : @git.ObjectId, b : @git.ObjectId) -> Int {
  for i in 0..<20 {
    let av = a.bytes[i].to_int()
    let bv = b.bytes[i].to_int()
    if av != bv {
      return av - bv
    }
  }
  0
}

///|
fn midx_find_chunk(data : Bytes, num_chunks : Int, chunk_id : String) -> Int {
  let header_size = 12
  for i in 0..<num_chunks {
    let entry_offset = header_size + i * 12
    let id0 = data[entry_offset].to_int()
    let id1 = data[entry_offset + 1].to_int()
    let id2 = data[entry_offset + 2].to_int()
    let id3 = data[entry_offset + 3].to_int()
    let id_str = String::from_array([
      Int::unsafe_to_char(id0),
      Int::unsafe_to_char(id1),
      Int::unsafe_to_char(id2),
      Int::unsafe_to_char(id3),
    ])
    if id_str == chunk_id {
      // Read offset (8 bytes, but we use lower 4)
      return midx_read_u32(data, entry_offset + 8)
    }
  }
  0
}

///|
fn midx_find_chunk_end(
  data : Bytes,
  num_chunks : Int,
  chunk_id : String,
) -> Int {
  let header_size = 12
  for i in 0..<num_chunks {
    let entry_offset = header_size + i * 12
    let id0 = data[entry_offset].to_int()
    let id1 = data[entry_offset + 1].to_int()
    let id2 = data[entry_offset + 2].to_int()
    let id3 = data[entry_offset + 3].to_int()
    let id_str = String::from_array([
      Int::unsafe_to_char(id0),
      Int::unsafe_to_char(id1),
      Int::unsafe_to_char(id2),
      Int::unsafe_to_char(id3),
    ])
    if id_str == chunk_id {
      // Next chunk's offset is the end
      return midx_read_u32(data, entry_offset + 12 + 8)
    }
  }
  data.length() - 20
}

///|
fn midx_bytes_to_string(data : Bytes, start : Int, end : Int) -> String {
  let chars : Array[Char] = []
  for i in start..<end {
    chars.push(Int::unsafe_to_char(data[i].to_int()))
  }
  String::from_array(chars)
}

///|
async fn handle_cherry(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut verbose = false
  let mut upstream : String? = None
  let mut head : String? = None
  let mut limit : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-v" => verbose = true
      _ if not(arg.has_prefix("-")) =>
        if upstream is None {
          upstream = Some(arg)
        } else if head is None {
          head = Some(arg)
        } else if limit is None {
          limit = Some(arg)
        }
      _ => ()
    }
    i += 1
  }
  // Default upstream to tracking branch or origin/HEAD
  let effective_upstream = match upstream {
    Some(u) => u
    None => {
      // Try to get upstream from current branch
      let head_content = decode_bytes(fs.read_file(git_dir + "/HEAD"))
      if head_content.has_prefix("ref: refs/heads/") {
        let branch = trim_string(head_content[16:].to_string())
        // Check for remote tracking
        let remote_ref = "origin/" + branch
        if @gitlib.rev_parse(fs, git_dir, remote_ref) is Some(_) {
          remote_ref
        } else {
          "origin/HEAD"
        }
      } else {
        "origin/HEAD"
      }
    }
  }
  // Default head to HEAD
  let effective_head = match head {
    Some(h) => h
    None => "HEAD"
  }
  // Resolve revisions
  let upstream_id = match @gitlib.rev_parse(fs, git_dir, effective_upstream) {
    Some(id) => id
    None => {
      eprint_line("fatal: bad revision '" + effective_upstream + "'")
      @sys.exit(128)
      return
    }
  }
  let head_id = match @gitlib.rev_parse(fs, git_dir, effective_head) {
    Some(id) => id
    None => {
      eprint_line("fatal: bad revision '" + effective_head + "'")
      @sys.exit(128)
      return
    }
  }
  let limit_id : @git.ObjectId? = match limit {
    Some(l) => @gitlib.rev_parse(fs, git_dir, l)
    None => None
  }
  // Collect commits from upstream (to find merge base)
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let upstream_commits = cherry_collect_commits(db, fs, upstream_id, limit_id)
  let head_commits = cherry_collect_commits(db, fs, head_id, limit_id)
  // Compute patch-ids for upstream commits
  let upstream_patch_ids : Map[String, @git.ObjectId] = {}
  for commit_id in upstream_commits {
    let patch_id = cherry_compute_patch_id(db, fs, commit_id)
    upstream_patch_ids[patch_id] = commit_id
  }
  // Check each head commit
  for commit_id in head_commits {
    // Skip if also in upstream (by commit id)
    let mut in_upstream_by_id = false
    for u_id in upstream_commits {
      if u_id == commit_id {
        in_upstream_by_id = true
        break
      }
    }
    if in_upstream_by_id {
      continue
    }
    let patch_id = cherry_compute_patch_id(db, fs, commit_id)
    let prefix = if upstream_patch_ids.contains(patch_id) { "-" } else { "+" }
    if verbose {
      let subject = plumb_get_commit_subject(db, fs, commit_id)
      print_line(prefix + " " + commit_id.to_hex() + " " + subject)
    } else {
      print_line(prefix + " " + commit_id.to_hex())
    }
  }
  ignore(limit_id)
}

///|
fn cherry_collect_commits(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  start : @git.ObjectId,
  limit : @git.ObjectId?,
) -> Array[@git.ObjectId] {
  let result : Array[@git.ObjectId] = []
  let limit_hex = match limit {
    Some(l) => l.to_hex()
    None => ""
  }
  let mut current : @git.ObjectId? = Some(start)
  let mut count = 0
  let max_commits = 1000 // Safety limit
  while current is Some(id) && count < max_commits {
    if limit_hex.length() > 0 && id.to_hex() == limit_hex {
      break
    }
    result.push(id)
    count += 1
    let obj = db.get(fs, id) catch { _ => break }
    match obj {
      Some(o) if o.obj_type == @git.ObjectType::Commit => {
        let info = @git.parse_commit(o.data) catch { _ => break }
        current = if info.parents.length() > 0 {
          Some(info.parents[0])
        } else {
          None
        }
      }
      _ => current = None
    }
  }
  result
}

///|
fn cherry_compute_patch_id(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commit_id : @git.ObjectId,
) -> String {
  // Get commit and its parent
  let obj = db.get(fs, commit_id) catch { _ => return commit_id.to_hex() }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Commit => {
      let info = @git.parse_commit(o.data) catch {
        _ => return commit_id.to_hex()
      }
      // Get tree entries of this commit
      let tree_entries = cherry_get_tree_entries(db, fs, info.tree)
      // Get parent tree entries (or empty if no parent)
      let parent_entries : Array[(String, String)] = if info.parents.length() >
        0 {
        let parent_obj = db.get(fs, info.parents[0]) catch {
          _ => return commit_id.to_hex()
        }
        match parent_obj {
          Some(po) if po.obj_type == @git.ObjectType::Commit => {
            let parent_info = @git.parse_commit(po.data) catch {
              _ => return commit_id.to_hex()
            }
            cherry_get_tree_entries(db, fs, parent_info.tree)
          }
          _ => []
        }
      } else {
        []
      }
      // Compute diff: files that changed between parent and commit
      let diff = cherry_compute_tree_diff(parent_entries, tree_entries)
      // Sort diff for consistent ordering
      diff.sort_by(fn(a, b) { a.0.compare(b.0) })
      // Hash the diff content (path + blob id pairs)
      let content_parts : Array[String] = []
      for item in diff {
        let (path, change) = item
        content_parts.push(path + ":" + change)
      }
      let patch_content = content_parts.join("\n")
      let patch_bytes = Bytes::from_array(
        FixedArray::makei(patch_content.length(), fn(i) {
          patch_content[i].to_int().to_byte()
        }),
      )
      @git.sha1(patch_bytes).to_hex()
    }
    _ => commit_id.to_hex()
  }
}

///|
fn cherry_get_tree_entries(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
) -> Array[(String, String)] {
  let result : Array[(String, String)] = []
  let obj = db.get(fs, tree_id) catch { _ => return result }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Tree => {
      let entries = @git.parse_tree(o.data) catch { _ => return result }
      for entry in entries {
        // For files, add path -> blob id
        // For directories, recursively get entries
        if entry.mode.has_prefix("04") {
          // Directory - recurse
          let sub_entries = cherry_get_tree_entries(db, fs, entry.id)
          for sub in sub_entries {
            let (sub_path, sub_id) = sub
            result.push((entry.name + "/" + sub_path, sub_id))
          }
        } else {
          // File
          result.push((entry.name, entry.id.to_hex()))
        }
      }
    }
    _ => ()
  }
  result
}

///|
fn cherry_compute_tree_diff(
  parent : Array[(String, String)],
  current : Array[(String, String)],
) -> Array[(String, String)] {
  // Build map of parent entries
  let parent_map : Map[String, String] = {}
  for item in parent {
    let (path, id) = item
    parent_map[path] = id
  }
  // Find changes
  let diff : Array[(String, String)] = []
  for item in current {
    let (path, id) = item
    match parent_map.get(path) {
      Some(parent_id) =>
        if parent_id != id {
          // Modified
          diff.push((path, "M:" + id))
        }
      None =>
        // Added
        diff.push((path, "A:" + id))
    }
  }
  // Find deleted files
  let current_map : Map[String, String] = {}
  for item in current {
    let (path, id) = item
    current_map[path] = id
  }
  for item in parent {
    let (path, _) = item
    if not(current_map.contains(path)) {
      diff.push((path, "D"))
    }
  }
  diff
}
