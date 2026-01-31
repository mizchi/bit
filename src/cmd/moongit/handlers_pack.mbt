///| Pack handlers: rev-list, verify-pack, unpack-objects, bundle

///|
async fn handle_rev_list(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut max_count : Int? = None
  let mut count_only = false
  let mut objects = false
  let mut quiet = false
  let mut reverse = false
  let mut first_parent = false
  let mut all = false
  let mut stdin = false
  let refs : Array[String] = []
  let excludes : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--max-count" if i + 1 < args.length() => {
        max_count = Some(@strconv.parse_int(args[i + 1]) catch { _ => 0 })
        i += 2
        continue
      }
      "--count" => count_only = true
      "--objects" | "--objects-edge" => objects = true
      "--quiet" | "-q" => quiet = true
      "--reverse" => reverse = true
      "--ancestry-path" => () // Ignored for now
      "--first-parent" => first_parent = true
      "--all" => all = true
      "--stdin" => stdin = true
      "--not" => {
        // Next refs are excludes until another --not
        i += 1
        while i < args.length() {
          let next = args[i]
          if next == "--not" {
            break
          }
          if not(next.has_prefix("-")) {
            excludes.push(next)
          }
          i += 1
        }
        continue
      }
      _ if arg.has_prefix("--max-count=") => {
        let val = String::unsafe_substring(arg, start=12, end=arg.length())
        max_count = Some(@strconv.parse_int(val) catch { _ => 0 })
      }
      _ if arg.has_prefix("^") => excludes.push(String::unsafe_substring(arg, start=1, end=arg.length()))
      _ if not(arg.has_prefix("-")) => refs.push(arg)
      _ => () // Ignore unknown options
    }
    i += 1
  }
  // Read from stdin if requested
  if stdin {
    let input = decode_bytes(read_all_stdin())
    for line_view in input.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() > 0 && not(line.has_prefix("#")) {
        if line.has_prefix("^") {
          excludes.push(String::unsafe_substring(line, start=1, end=line.length()))
        } else {
          refs.push(line)
        }
      }
    }
  }
  // If --all, add all refs
  if all {
    let all_refs = @gitlib.show_ref(fs, git_dir)
    for item in all_refs {
      let (name, _) = item
      refs.push(name)
    }
  }
  // If no refs specified, default to HEAD
  if refs.length() == 0 {
    refs.push("HEAD")
  }
  // Resolve starting commits
  let start_ids : Array[@git.ObjectId] = []
  for spec in refs {
    match @gitlib.rev_parse(fs, git_dir, spec) {
      Some(id) => start_ids.push(id)
      None => ()
    }
  }
  // Resolve exclude commits
  let exclude_ids : Map[String, Bool] = {}
  for spec in excludes {
    match @gitlib.rev_parse(fs, git_dir, spec) {
      Some(id) =>
        // Walk the exclude commit and all its ancestors
        walk_commits_to_map(fs, git_dir, id, exclude_ids)
      None => ()
    }
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let visited : Map[String, Bool] = {}
  let result : Array[@git.ObjectId] = []
  let object_ids : Array[@git.ObjectId] = []
  let limit = match max_count {
    Some(n) => n
    None => 2147483647 // Max int
  }
  // BFS/DFS traversal
  let queue : Array[@git.ObjectId] = []
  for id in start_ids {
    queue.push(id)
  }
  while queue.length() > 0 && result.length() < limit {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if visited.contains(hex) || exclude_ids.contains(hex) {
      continue
    }
    visited[hex] = true
    result.push(id)
    if objects {
      object_ids.push(id)
    }
    // Get commit and add parents
    match db.get(fs, id) {
      Some(obj) if obj.obj_type == @git.ObjectType::Commit => {
        let info = @git.parse_commit(obj.data)
        if objects {
          // Also collect tree objects
          collect_tree_objects(db, fs, info.tree, object_ids, visited)
        }
        if first_parent && info.parents.length() > 0 {
          if not(visited.contains(info.parents[0].to_hex())) {
            queue.push(info.parents[0])
          }
        } else {
          for parent in info.parents {
            if not(visited.contains(parent.to_hex())) {
              queue.push(parent)
            }
          }
        }
      }
      _ => ()
    }
  }
  // Apply reverse if requested
  if reverse {
    result.rev_in_place()
    if objects {
      object_ids.rev_in_place()
    }
  }
  // Output
  if count_only {
    print_line(result.length().to_string())
    return
  }
  if quiet {
    return
  }
  // Output commits
  for id in result {
    print_line(id.to_hex())
  }
  // Output objects (trees, blobs) if --objects
  if objects {
    for id in object_ids {
      // Skip commits already printed
      let hex = id.to_hex()
      let mut is_commit = false
      for r in result {
        if r.to_hex() == hex {
          is_commit = true
          break
        }
      }
      if not(is_commit) {
        print_line(hex)
      }
    }
  }
}

///|
fn walk_commits_to_map(
  fs : OsFs,
  git_dir : String,
  start : @git.ObjectId,
  out : Map[String, Bool],
) -> Unit {
  let db = @gitlib.ObjectDb::load(fs, git_dir) catch { _ => return () }
  let queue : Array[@git.ObjectId] = [start]
  while queue.length() > 0 {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if out.contains(hex) {
      continue
    }
    out[hex] = true
    let obj = db.get(fs, id) catch { _ => continue }
    match obj {
      Some(o) if o.obj_type == @git.ObjectType::Commit => {
        let info = @git.parse_commit(o.data) catch { _ => continue }
        for parent in info.parents {
          if not(out.contains(parent.to_hex())) {
            queue.push(parent)
          }
        }
      }
      _ => ()
    }
  }
}

///|
fn collect_tree_objects(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  out : Array[@git.ObjectId],
  visited : Map[String, Bool],
) -> Unit {
  let hex = tree_id.to_hex()
  if visited.contains(hex) {
    return ()
  }
  visited[hex] = true
  out.push(tree_id)
  let obj = db.get(fs, tree_id) catch { _ => return () }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Tree => {
      let entries = @git.parse_tree(o.data) catch { _ => return () }
      for entry in entries {
        let entry_hex = entry.id.to_hex()
        if not(visited.contains(entry_hex)) {
          if entry.mode.has_prefix("40") {
            // Directory - recurse
            collect_tree_objects(db, fs, entry.id, out, visited)
          } else {
            // File or other
            visited[entry_hex] = true
            out.push(entry.id)
          }
        }
      }
    }
    _ => ()
  }
}

///|
async fn handle_verify_pack(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let mut verbose = false
  let mut stat_only = false
  let pack_files : Array[String] = []
  for arg in args {
    match arg {
      "-v" | "--verbose" => verbose = true
      "-s" | "--stat-only" => stat_only = true
      _ if not(arg.has_prefix("-")) => pack_files.push(arg)
      _ => ()
    }
  }
  if pack_files.length() == 0 {
    eprint_line(
      "usage: git verify-pack [-v | --verbose] [-s | --stat-only] <pack>...",
    )
    @sys.exit(1)
  }
  for pack_path in pack_files {
    verify_single_pack(fs, pack_path, verbose, stat_only)
  }
}

///|
async fn verify_single_pack(
  fs : OsFs,
  pack_path : String,
  verbose : Bool,
  stat_only : Bool,
) -> Unit raise Error {
  // Normalize path - accept .pack, .idx or base name
  let base_path = if pack_path.has_suffix(".pack") {
    String::unsafe_substring(pack_path, start=0, end=pack_path.length() - 5)
  } else if pack_path.has_suffix(".idx") {
    String::unsafe_substring(pack_path, start=0, end=pack_path.length() - 4)
  } else {
    pack_path
  }
  let pack_file = base_path + ".pack"
  if not(fs.is_file(pack_file)) {
    raise @git.GitError::InvalidObject("pack file not found: " + pack_file)
  }
  let data = fs.read_file(pack_file)
  // Parse and verify the packfile
  let objects = @git.parse_packfile(data)
  // Count object types
  let mut _commits = 0
  let mut _trees = 0
  let mut _blobs = 0
  let mut _tags = 0
  let mut total_size = 0
  for obj in objects {
    match obj.obj_type {
      @git.ObjectType::Commit => _commits += 1
      @git.ObjectType::Tree => _trees += 1
      @git.ObjectType::Blob => _blobs += 1
      @git.ObjectType::Tag => _tags += 1
    }
    total_size += obj.data.length()
  }
  if verbose && not(stat_only) {
    // Print each object
    for obj in objects {
      let id = @git.hash_object_content(obj.obj_type, obj.data)
      let type_str = match obj.obj_type {
        @git.ObjectType::Commit => "commit"
        @git.ObjectType::Tree => "tree"
        @git.ObjectType::Blob => "blob"
        @git.ObjectType::Tag => "tag"
      }
      print_line("\{id.to_hex()} \{type_str} \{obj.data.length()}")
    }
  }
  // Print summary
  if verbose || stat_only {
    print_line(
      "chain length = 0: \{objects.length()} objects, \{total_size} bytes",
    )
  }
  // Print final verification message with pack checksum
  let checksum = get_pack_checksum(data)
  print_line("\{pack_file}: ok (\{checksum})")
}

///|
fn get_pack_checksum(data : Bytes) -> String {
  if data.length() < 20 {
    return "invalid"
  }
  let start = data.length() - 20
  let bytes : FixedArray[Byte] = FixedArray::makei(20, fn(i) { data[start + i] })
  @git.ObjectId::new(bytes).to_hex()
}

///|
async fn handle_unpack_objects(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut quiet = false
  let mut dry_run = false
  for arg in args {
    match arg {
      "-q" => quiet = true
      "-n" => dry_run = true
      "-r" => () // Recover - ignored for now
      "--strict" => () // Strict - ignored for now
      _ => ()
    }
  }
  // Read packfile from stdin
  let data = read_all_stdin()
  if data.length() < 32 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  // Parse the packfile
  let objects = @git.parse_packfile(data)
  if not(quiet) {
    print_line(
      "Unpacking objects: 100% (\{objects.length()}/\{objects.length()}), done.",
    )
  }
  if dry_run {
    return
  }
  // Write objects to the repository
  for obj in objects {
    let _ = @gitlib.write_loose_object(fs, git_dir, obj.obj_type, obj.data)

  }
}

///|
async fn handle_bundle(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_line("usage: git bundle <command> [<args>]")
    print_line("")
    print_line("commands:")
    print_line("   create     Create a bundle")
    print_line("   verify     Verify a bundle")
    print_line("   list-heads List refs in a bundle")
    print_line("   unbundle   Extract objects from a bundle")
    return
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "create" => handle_bundle_create(rest)
    "verify" => handle_bundle_verify(rest)
    "list-heads" => handle_bundle_list_heads(rest)
    "unbundle" => handle_bundle_unbundle(rest)
    _ => {
      eprint_line("git bundle: unknown subcommand: " + subcmd)
      @sys.exit(1)
    }
  }
}

///|
async fn handle_bundle_create(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut bundle_file : String? = None
  let refs : Array[String] = []
  let excludes : Array[String] = []
  let mut all = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--all" => all = true
      _ if arg.has_prefix("^") => excludes.push(String::unsafe_substring(arg, start=1, end=arg.length()))
      _ if not(arg.has_prefix("-")) =>
        if bundle_file is None {
          bundle_file = Some(arg)
        } else {
          refs.push(arg)
        }
      _ => ()
    }
    i += 1
  }
  guard bundle_file is Some(output_path) else {
    eprint_line("fatal: must specify a bundle file")
    @sys.exit(1)
  }
  // Collect refs to include
  if all {
    let all_refs = @gitlib.show_ref(fs, git_dir)
    for item in all_refs {
      let (name, _) = item
      refs.push(name)
    }
  }
  if refs.length() == 0 {
    refs.push("HEAD")
  }
  // Build bundle header
  let lines : Array[String] = ["# v2 git bundle"]
  // Add prerequisites (excluded refs)
  for spec in excludes {
    match @gitlib.rev_parse(fs, git_dir, spec) {
      Some(id) => lines.push("-" + id.to_hex())
      None => ()
    }
  }
  // Add refs
  for spec in refs {
    match @gitlib.rev_parse(fs, git_dir, spec) {
      Some(id) => {
        let refname = if spec == "HEAD" { "HEAD" } else { spec }
        lines.push(id.to_hex() + " " + refname)
      }
      None => ()
    }
  }
  lines.push("") // Empty line before pack data
  let header = lines.join("\n")
  let header_bytes = header.to_bytes()
  // Collect objects for pack
  let start_ids : Array[@git.ObjectId] = []
  for spec in refs {
    match @gitlib.rev_parse(fs, git_dir, spec) {
      Some(id) => start_ids.push(id)
      None => ()
    }
  }
  let exclude_ids : Map[String, Bool] = {}
  for spec in excludes {
    match @gitlib.rev_parse(fs, git_dir, spec) {
      Some(id) => walk_commits_to_map(fs, git_dir, id, exclude_ids)
      None => ()
    }
  }
  // Collect all reachable objects
  let objects = collect_bundle_objects(fs, git_dir, start_ids, exclude_ids)
  // Create packfile
  let pack_data = @git.create_packfile(objects)
  // Write bundle
  let bundle_data = Bytes::from_array(
    FixedArray::makei(header_bytes.length() + pack_data.length(), fn(i) {
      if i < header_bytes.length() {
        header_bytes[i]
      } else {
        pack_data[i - header_bytes.length()]
      }
    }),
  )
  fs.write_file(output_path, bundle_data)
  print_line("Enumerating objects: \{objects.length()}, done.")
  print_line("Total \{objects.length()} (delta 0), reused 0 (delta 0)")
}

///|
fn collect_bundle_objects(
  fs : OsFs,
  git_dir : String,
  start_ids : Array[@git.ObjectId],
  exclude_ids : Map[String, Bool],
) -> Array[@git.PackObject] raise Error {
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let visited : Map[String, Bool] = {}
  let objects : Array[@git.PackObject] = []
  let queue : Array[@git.ObjectId] = []
  for id in start_ids {
    queue.push(id)
  }
  while queue.length() > 0 {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if visited.contains(hex) || exclude_ids.contains(hex) {
      continue
    }
    visited[hex] = true
    match db.get(fs, id) {
      Some(obj) => {
        objects.push(obj)
        match obj.obj_type {
          @git.ObjectType::Commit => {
            let info = @git.parse_commit(obj.data)
            // Add tree
            if not(visited.contains(info.tree.to_hex())) {
              queue.push(info.tree)
            }
            // Add parents
            for parent in info.parents {
              if not(visited.contains(parent.to_hex())) &&
                not(exclude_ids.contains(parent.to_hex())) {
                queue.push(parent)
              }
            }
          }
          @git.ObjectType::Tree => {
            let entries = @git.parse_tree(obj.data)
            for entry in entries {
              if not(visited.contains(entry.id.to_hex())) {
                queue.push(entry.id)
              }
            }
          }
          @git.ObjectType::Tag => {
            // Parse tag target
            let text = decode_bytes(obj.data)
            for line_view in text.split("\n") {
              let line = line_view.to_string()
              if line.has_prefix("object ") {
                let target_hex = String::unsafe_substring(line, start=7, end=line.length())
                let target = @git.ObjectId::from_hex(target_hex)
                if not(visited.contains(target_hex)) {
                  queue.push(target)
                }
                break
              }
            }
          }
          _ => ()
        }
      }
      None => ()
    }
  }
  objects
}

///|
async fn handle_bundle_verify(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut quiet = false
  let mut bundle_file : String? = None
  for arg in args {
    match arg {
      "-q" | "--quiet" => quiet = true
      _ if not(arg.has_prefix("-")) => bundle_file = Some(arg)
      _ => ()
    }
  }
  guard bundle_file is Some(path) else {
    eprint_line("fatal: must specify a bundle file")
    @sys.exit(1)
  }
  let (_, prereqs, refs, _) = parse_bundle_file(fs, path)
  // Check prerequisites
  let mut ok = true
  for prereq in prereqs {
    match @gitlib.rev_parse(fs, git_dir, prereq) {
      Some(_) => ()
      None => {
        if not(quiet) {
          eprint_line("error: Repository lacks prerequisite commit: " + prereq)
        }
        ok = false
      }
    }
  }
  if ok {
    if not(quiet) {
      print_line("The bundle contains \{refs.length()} ref(s)")
      for item in refs {
        let (id, name) = item
        print_line(id + " " + name)
      }
    }
    print_line(path + " is okay")
  } else {
    @sys.exit(1)
  }
}

///|
async fn handle_bundle_list_heads(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let mut bundle_file : String? = None
  for arg in args {
    if not(arg.has_prefix("-")) {
      bundle_file = Some(arg)
    }
  }
  guard bundle_file is Some(path) else {
    eprint_line("fatal: must specify a bundle file")
    @sys.exit(1)
  }
  let (_, _, refs, _) = parse_bundle_file(fs, path)
  for item in refs {
    let (id, name) = item
    print_line(id + " " + name)
  }
}

///|
async fn handle_bundle_unbundle(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut bundle_file : String? = None
  for arg in args {
    if not(arg.has_prefix("-")) {
      bundle_file = Some(arg)
    }
  }
  guard bundle_file is Some(path) else {
    eprint_line("fatal: must specify a bundle file")
    @sys.exit(1)
  }
  let (_, _, refs, pack_data) = parse_bundle_file(fs, path)
  // Unpack objects
  let objects = @git.parse_packfile(pack_data)
  for obj in objects {
    let _ = @gitlib.write_loose_object(fs, git_dir, obj.obj_type, obj.data)

  }
  // Print refs
  for item in refs {
    let (id, name) = item
    print_line(id + " " + name)
  }
}

///|
fn parse_bundle_file(
  fs : OsFs,
  path : String,
) -> (String, Array[String], Array[(String, String)], Bytes) raise Error {
  let data = fs.read_file(path)
  // Find header end (empty line before pack)
  let mut header_end = 0
  let mut i = 0
  while i < data.length() - 1 {
    if data[i] == b'\n' && data[i + 1] == b'\n' {
      header_end = i + 2
      break
    }
    if data[i] == b'\n' && i + 1 < data.length() && data[i + 1] == b'P' {
      // Pack starts right after newline
      header_end = i + 1
      break
    }
    i += 1
  }
  if header_end == 0 {
    raise @git.GitError::PackfileError("Invalid bundle: no header found")
  }
  let header_bytes = FixedArray::makei(header_end, fn(j) { data[j] })
  let header = decode_bytes(Bytes::from_array(header_bytes))
  let prereqs : Array[String] = []
  let refs : Array[(String, String)] = []
  for line_view in header.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    if line.has_prefix("-") {
      prereqs.push(String::unsafe_substring(line, start=1, end=line.length()))
    } else {
      match line.find(" ") {
        Some(idx) => {
          let id = String::unsafe_substring(line, start=0, end=idx)
          let name = String::unsafe_substring(line, start=idx + 1, end=line.length())
          refs.push((id, name))
        }
        None => ()
      }
    }
  }
  let pack_data = Bytes::from_array(
    FixedArray::makei(data.length() - header_end, fn(j) { data[header_end + j] }),
  )
  (header, prereqs, refs, pack_data)
}
