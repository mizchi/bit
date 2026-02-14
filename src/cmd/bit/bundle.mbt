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
  for arg in args {
    if arg == "--since" || arg.has_prefix("--since=") {
      eprint_line("fatal: bit bundle create: --since is not supported yet")
      @sys.exit(1)
    }
  }
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
      _ if arg.has_prefix("^") =>
        excludes.push(String::unsafe_substring(arg, start=1, end=arg.length()))
      _ if not(arg.has_prefix("-")) =>
        if bundle_file is None {
          bundle_file = Some(arg)
        } else {
          refs.push(arg)
        }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("bundle", arg)
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
    let all_refs = @gitrepo.show_ref(fs, git_dir)
    for item in all_refs {
      let (name, _) = item
      refs.push(name)
    }
  }
  if refs.length() == 0 {
    refs.push("HEAD")
  }
  let prereq_hexes : Array[String] = []
  let prereq_seen : Map[String, Bool] = {}
  let add_prereq = fn(hex : String) -> Unit {
    if not(prereq_seen.contains(hex)) {
      prereq_seen[hex] = true
      prereq_hexes.push(hex)
    }
  }
  // Add prerequisites (excluded refs)
  for spec in excludes {
    match @gitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => add_prereq(id.to_hex())
      None => ()
    }
  }
  // Collect objects for pack
  let start_ids : Array[@git.ObjectId] = []
  for spec in refs {
    match @gitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => start_ids.push(id)
      None => ()
    }
  }
  let exclude_ids : Map[String, Bool] = {}
  for spec in excludes {
    match @gitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => walk_commits_to_map(fs, git_dir, id, exclude_ids)
      None => ()
    }
  }
  // Build bundle header
  let lines : Array[String] = ["# v2 git bundle"]
  for hex in prereq_hexes {
    lines.push("-" + hex)
  }
  // Add refs
  for spec in refs {
    match @gitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => {
        let refname = if spec == "HEAD" { "HEAD" } else { spec }
        lines.push(id.to_hex() + " " + refname)
      }
      None => ()
    }
  }
  lines.push("") // Empty line before pack data
  let header = lines.join("\n")
  let header_bytes = @utf8.encode(header[:])
  // Collect all reachable objects
  let objects = collect_bundle_objects(fs, git_dir, start_ids, exclude_ids)
  // Create packfile
  let pack_data = @pack.create_packfile(objects)
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
                let target_hex = String::unsafe_substring(
                  line,
                  start=7,
                  end=line.length(),
                )
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("bundle", arg)
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
    match @gitrepo.rev_parse(fs, git_dir, prereq) {
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
    } else {
      warn_unimplemented_arg("bundle", arg)
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
    } else {
      warn_unimplemented_arg("bundle", arg)
    }
  }
  guard bundle_file is Some(path) else {
    eprint_line("fatal: must specify a bundle file")
    @sys.exit(1)
  }
  let (_, _, refs, pack_data) = parse_bundle_file(fs, path)
  // Unpack objects
  let objects = @pack.parse_packfile(pack_data)
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
  let header_bytes = FixedArray::makei(header_end, j => data[j])
  let header = header_bytes |> Bytes::from_array |> decode_bytes
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
          let name = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          refs.push((id, name))
        }
        None => ()
      }
    }
  }
  let pack_data = Bytes::from_array(
    FixedArray::makei(data.length() - header_end, j => data[header_end + j]),
  )
  (header, prereqs, refs, pack_data)
}
