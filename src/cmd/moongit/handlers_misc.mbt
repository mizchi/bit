///| Miscellaneous handlers: diff, merge, tag, rm, mv, config, sparse-checkout, rev-parse, cat-file, ls-files, hash-object, ls-tree, write-tree, show-ref, update-ref, symbolic-ref

///|
async fn handle_diff(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut cached = false
  let mut stat_mode = false
  let mut name_only = false
  let mut name_status = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--cached" | "--staged" => cached = true
      "--stat" => stat_mode = true
      "--name-only" => name_only = true
      "--name-status" => name_status = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let all_files = if cached {
    @gitlib.diff_index(fs, root)
  } else {
    @gitlib.diff_worktree(fs, root)
  }
  // Filter by paths if specified
  let files = if paths.length() > 0 {
    all_files
    .iter()
    .filter(fn(f) {
      paths.iter().any(fn(p) { f.path == p || f.path.has_prefix(p + "/") })
    })
    .collect()
  } else {
    all_files
  }
  // Output based on mode
  if name_only {
    for f in files {
      print_line(f.path)
    }
  } else if name_status {
    for f in files {
      let status = match f.kind {
        @gitlib.DiffKind::Added => "A"
        @gitlib.DiffKind::Modified => "M"
        @gitlib.DiffKind::Deleted => "D"
      }
      print_line("\{status}\t\{f.path}")
    }
  } else if stat_mode {
    let lines = @gitlib.diff_stat(files)
    for line in lines {
      print_line(line)
    }
  } else {
    let lines = @gitlib.diff_text(files)
    for line in lines {
      print_line(line)
    }
  }
}

///|
async fn handle_merge(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut target_ref : String? = None
  let mut message : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) => target_ref = Some(arg)
      _ => ()
    }
    i += 1
  }
  guard target_ref is Some(refspec) else {
    raise @git.GitError::InvalidObject("No commit to merge specified")
  }
  // Resolve target
  let target_id = @gitlib.rev_parse(fs, git_dir, refspec)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{refspec}")
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let msg = message.unwrap_or("Merge \{refspec}")
  let result = @gitlib.merge(fs, fs, root, tid, msg, author, timestamp)
  match result.status {
    @gitlib.MergeStatus::AlreadyUpToDate => print_line("Already up to date.")
    @gitlib.MergeStatus::FastForward =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Fast-forward to \{short}")
        }
        None => print_line("Fast-forward")
      }
    @gitlib.MergeStatus::Merged =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Merge made by the 'ort' strategy. [\{short}]")
        }
        None => print_line("Merged")
      }
    @gitlib.MergeStatus::Conflicted => {
      print_line("CONFLICT (content): Merge conflict in the following files:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("Automatic merge failed; fix conflicts and then commit.")
    }
  }
}

///|
async fn handle_tag(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut list_mode = true
  let mut delete_mode = false
  let mut annotated = false
  let mut message : String? = None
  let mut tag_name : String? = None
  let mut target : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-l" | "--list" => list_mode = true
      "-d" | "--delete" => {
        delete_mode = true
        list_mode = false
      }
      "-a" | "--annotate" => {
        annotated = true
        list_mode = false
      }
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        annotated = true
        list_mode = false
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) =>
        if tag_name is None {
          tag_name = Some(arg)
          list_mode = false
        } else if target is None {
          target = Some(arg)
        }
      _ => ()
    }
    i += 1
  }
  if delete_mode {
    guard tag_name is Some(name) else {
      raise @git.GitError::InvalidObject("tag name required for delete")
    }
    @gitlib.delete_tag(fs, git_dir, name)
    print_line("Deleted tag '\{name}'")
    return ()
  }
  if list_mode {
    let tags = @gitlib.list_tags(fs, git_dir)
    for tag in tags {
      print_line(tag)
    }
    return ()
  }
  guard tag_name is Some(name) else {
    raise @git.GitError::InvalidObject("tag name required")
  }
  // Resolve target (default to HEAD)
  let target_ref = target.unwrap_or("HEAD")
  let commit_id = @gitlib.rev_parse(fs, git_dir, target_ref)
  guard commit_id is Some(id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{target_ref}")
  }
  if annotated {
    let msg = message.unwrap_or("")
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    @gitlib.create_annotated_tag(
      fs, fs, git_dir, name, id, msg, author, timestamp,
    )
  } else {
    @gitlib.create_lightweight_tag(fs, git_dir, name, id)
  }
}

///|
fn handle_rm(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut cached = false
  let mut force = false
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--cached" => cached = true
      "-f" | "--force" => force = true
      "-r" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("No pathspec given")
  }
  @gitlib.rm_paths(fs, fs, root, paths, cached~, force~, recursive~)
}

///|
fn handle_mv(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut force = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  if paths.length() < 2 {
    raise @git.GitError::InvalidObject("usage: git mv <source> <destination>")
  }
  let source = paths[0]
  let dest = paths[1]
  @gitlib.mv_path(fs, fs, root, source, dest, force~)
}

///|
async fn handle_config(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let config_path = git_dir + "/config"
  // Parse arguments
  let mut get_mode = false
  let mut get_bool = false
  let mut list_mode = false
  let mut unset_mode = false
  let mut add_mode = false
  let mut key : String? = None
  let mut value : String? = None
  for arg in args {
    match arg {
      "--get" => get_mode = true
      "--bool" => get_bool = true
      "--list" | "-l" => list_mode = true
      "--unset" => unset_mode = true
      "--add" => add_mode = true
      _ if arg.has_prefix("-") => ()
      _ =>
        if key is None {
          key = Some(arg)
        } else if value is None {
          value = Some(arg)
        }
    }
  }
  // Handle --list
  if list_mode {
    if fs.is_file(config_path) {
      list_config(fs, config_path)
    }
    return
  }
  guard key is Some(k) else {
    raise @git.GitError::InvalidObject("key required")
  }
  // Handle --unset
  if unset_mode {
    unset_config(fs, config_path, k)
    return
  }
  if get_mode || value is None {
    // Read config
    if not(fs.is_file(config_path)) {
      @sys.exit(1)
    }
    let result = get_config_value(fs, config_path, k)
    match result {
      Some(val) =>
        if get_bool {
          print_line(
            if val == "true" || val == "1" || val == "yes" {
              "true"
            } else {
              "false"
            },
          )
        } else {
          print_line(val)
        }
      None =>
        // Key not found - exit silently with code 1 (git behavior)
        @sys.exit(1)
    }
  } else {
    // Write config
    guard value is Some(v) else { return }
    set_config(fs, config_path, k, v, add_mode)
  }
}

///|
fn trim_chars(s : String, chars : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if chars.contains(c.to_string()) {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if chars.contains(c.to_string()) {
      end -= 1
    } else {
      break
    }
  }
  String::unsafe_substring(s, start~, end~)
}

///|
async fn list_config(
  fs : &@git.RepoFileSystem,
  config_path : String,
) -> Unit raise Error {
  if not(fs.is_file(config_path)) {
    return
  }
  let content = decode_bytes(fs.read_file(config_path))
  let mut current_section = ""
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      current_section = String::unsafe_substring(
        line,
        start=1,
        end=line.length() - 1,
      )
      // Handle subsections like [remote "origin"]
      let space_idx = current_section.find(" ")
      match space_idx {
        Some(i) => {
          let main = String::unsafe_substring(current_section, start=0, end=i)
          let sub = trim_chars(
            String::unsafe_substring(
              current_section,
              start=i + 1,
              end=current_section.length(),
            ),
            "\" ",
          )
          current_section = main + "." + sub
        }
        None => ()
      }
      continue
    }
    // Parse key=value or key = value
    let eq_idx = line.find("=")
    match eq_idx {
      Some(i) => {
        let key_part = trim_chars(
          String::unsafe_substring(line, start=0, end=i),
          " \t",
        )
        let val_part = trim_chars(
          String::unsafe_substring(line, start=i + 1, end=line.length()),
          " \t",
        )
        print_line("\{current_section}.\{key_part}=\{val_part}")
      }
      None => ()
    }
  }
}

///|
fn get_config_value(
  fs : &@git.RepoFileSystem,
  config_path : String,
  key : String,
) -> String? raise Error {
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes(fs.read_file(config_path))
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  // Handle section.subsection.key format (e.g., remote.origin.url)
  let (section, subsection, name) = if parts.length() == 2 {
    (parts[0], (None : String?), parts[1])
  } else {
    // section.subsection.key
    let sub : Array[String] = []
    for i in 1..<(parts.length() - 1) {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")), parts[parts.length() - 1])
  }
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[") && line.has_suffix("]") {
      let sec_content = String::unsafe_substring(
        line,
        start=1,
        end=line.length() - 1,
      )
      match subsection {
        Some(sub) => {
          // Looking for [section "subsection"]
          let expected = section + " \"" + sub + "\""
          in_section = sec_content == expected ||
            sec_content == section + " " + sub
        }
        None =>
          in_section = sec_content == section ||
            sec_content.has_prefix(section + " ") ||
            sec_content.has_prefix(section + "\t")
      }
      continue
    }
    if in_section {
      // Check for key = value
      let eq_idx = line.find("=")
      match eq_idx {
        Some(i) => {
          let key_part = trim_chars(
            String::unsafe_substring(line, start=0, end=i),
            " \t",
          )
          if key_part == name {
            return Some(
              trim_chars(
                String::unsafe_substring(line, start=i + 1, end=line.length()),
                " \t",
              ),
            )
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
fn set_config(
  fs : OsFs,
  config_path : String,
  key : String,
  value : String,
  add_mode : Bool,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return
  }
  let (section, subsection, name) = if parts.length() == 2 {
    (parts[0], (None : String?), parts[1])
  } else {
    let sub : Array[String] = []
    for i in 1..<(parts.length() - 1) {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")), parts[parts.length() - 1])
  }
  let section_header = match subsection {
    Some(sub) => "[\{section} \"\{sub}\"]"
    None => "[\{section}]"
  }
  if not(rfs.is_file(config_path)) {
    // Create new config file
    wfs.write_string(
      config_path,
      section_header + "\n\t" + name + " = " + value + "\n",
    )
    return
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let lines : Array[String] = []
  for line_view in content.split("\n") {
    lines.push(line_view.to_string())
  }
  let mut in_section = false
  let mut found = false
  let mut section_end = -1
  let result : Array[String] = []
  for i, line in lines {
    let trimmed = trim_string(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      if in_section && not(found) {
        // Insert at end of previous section
        result.push("\t" + name + " = " + value)
        found = true
      }
      let sec_content = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      match subsection {
        Some(sub) => {
          let expected = section + " \"" + sub + "\""
          in_section = sec_content == expected ||
            sec_content == section + " " + sub
        }
        None => in_section = sec_content == section
      }
      if in_section {
        section_end = i
      }
      result.push(line)
      continue
    }
    if in_section && not(add_mode) {
      let eq_idx = trimmed.find("=")
      match eq_idx {
        Some(idx) => {
          let key_part = trim_chars(
            String::unsafe_substring(trimmed, start=0, end=idx),
            " \t",
          )
          if key_part == name {
            result.push("\t" + name + " = " + value)
            found = true
            continue
          }
        }
        None => ()
      }
      section_end = i
    }
    result.push(line)
  }
  if not(found) {
    if section_end >= 0 {
      // Insert after section header
      let new_result : Array[String] = []
      for i, line in result {
        new_result.push(line)
        if i == section_end && not(found) {
          new_result.push("\t" + name + " = " + value)
          found = true
        }
      }
      wfs.write_string(config_path, new_result.join("\n"))
      return
    }
    // Add new section at end
    result.push(section_header)
    result.push("\t" + name + " = " + value)
  }
  wfs.write_string(config_path, result.join("\n"))
}

///|
fn unset_config(
  fs : OsFs,
  config_path : String,
  key : String,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  if not(rfs.is_file(config_path)) {
    return
  }
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return
  }
  let (section, subsection, name) = if parts.length() == 2 {
    (parts[0], (None : String?), parts[1])
  } else {
    let sub : Array[String] = []
    for i in 1..<(parts.length() - 1) {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")), parts[parts.length() - 1])
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let lines : Array[String] = []
  for line_view in content.split("\n") {
    lines.push(line_view.to_string())
  }
  let mut in_section = false
  let result : Array[String] = []
  for line in lines {
    let trimmed = trim_string(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      let sec_content = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      match subsection {
        Some(sub) => {
          let expected = section + " \"" + sub + "\""
          in_section = sec_content == expected ||
            sec_content == section + " " + sub
        }
        None => in_section = sec_content == section
      }
      result.push(line)
      continue
    }
    if in_section {
      let eq_idx = trimmed.find("=")
      match eq_idx {
        Some(idx) => {
          let key_part = trim_chars(
            String::unsafe_substring(trimmed, start=0, end=idx),
            " \t",
          )
          if key_part == name {
            // Skip this line (unset)
            continue
          }
        }
        None => ()
      }
    }
    result.push(line)
  }
  wfs.write_string(config_path, result.join("\n"))
}

///|
async fn handle_sparse_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args.length() == 0 {
    raise @git.GitError::InvalidObject(
      "usage: git sparse-checkout <init|set|add|list|disable>",
    )
  }
  let subcmd = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "init" => {
      let cone = rest.contains("--cone")
      @gitlib.sparse_checkout_init(fs, fs, root, cone~)
      print_line("Sparse checkout initialized")
    }
    "set" => {
      let patterns = rest
        .iter()
        .filter(fn(arg) { not(arg.has_prefix("-")) })
        .collect()
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for set")
      }
      @gitlib.sparse_checkout_set(fs, fs, root, patterns)
      print_line("Sparse checkout patterns set")
    }
    "add" => {
      let patterns = rest
        .iter()
        .filter(fn(arg) { not(arg.has_prefix("-")) })
        .collect()
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for add")
      }
      @gitlib.sparse_checkout_add(fs, fs, root, patterns)
      print_line("Sparse checkout patterns added")
    }
    "list" => {
      let patterns = @gitlib.read_sparse_patterns(fs, git_dir)
      for p in patterns {
        print_line(p)
      }
    }
    "disable" => {
      @gitlib.sparse_checkout_disable(fs, fs, root)
      print_line("Sparse checkout disabled")
    }
    _ =>
      raise @git.GitError::InvalidObject(
        "unknown sparse-checkout subcommand: \{subcmd}",
      )
  }
}

///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  for arg in args {
    match arg {
      "--git-dir" => print_line(git_dir)
      "--show-toplevel" => {
        let abs = if root == "." {
          @sys.get_env_var("PWD").unwrap_or(root)
        } else {
          root
        }
        print_line(abs)
      }
      _ if arg.has_prefix("-") => ()
      _ => {
        let id = @gitlib.rev_parse(fs, git_dir, arg)
        match id {
          Some(oid) => print_line(oid.to_hex())
          None => raise @git.GitError::InvalidObject("unknown revision: " + arg)
        }
      }
    }
  }
}

///|
async fn handle_cat_file(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut show_type = false
  let mut show_size = false
  let mut pretty_print = false
  let mut obj_spec : String? = None
  for arg in args {
    match arg {
      "-t" => show_type = true
      "-s" => show_size = true
      "-p" => pretty_print = true
      _ if arg.has_prefix("-") => ()
      _ => obj_spec = Some(arg)
    }
  }
  guard obj_spec is Some(spec) else {
    raise @git.GitError::InvalidObject("object name required")
  }
  let obj_id = @gitlib.rev_parse(fs, git_dir, spec)
  guard obj_id is Some(oid) else {
    raise @git.GitError::InvalidObject("Not a valid object name: \{spec}")
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, oid)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Object not found: \{spec}")
  }
  if show_type {
    print_line(o.obj_type.to_string())
    return ()
  }
  if show_size {
    print_line(o.data.length().to_string())
    return ()
  }
  if pretty_print {
    match o.obj_type {
      @git.ObjectType::Blob => @stdio.stdout.write(o.data)
      @git.ObjectType::Tree => {
        let entries = @git.parse_tree(o.data)
        for entry in entries {
          let mode_str = if entry.mode == "40000" {
            "040000"
          } else {
            entry.mode
          }
          let type_str = if entry.mode == "40000" { "tree" } else { "blob" }
          print_line(
            "\{mode_str} \{type_str} \{entry.id.to_hex()}\t\{entry.name}",
          )
        }
      }
      @git.ObjectType::Commit => {
        let text = decode_bytes(o.data)
        print_line(text)
      }
      @git.ObjectType::Tag => {
        let text = decode_bytes(o.data)
        print_line(text)
      }
    }
    return ()
  }
  // Default: output raw content
  @stdio.stdout.write(o.data)
}

///|
async fn handle_ls_files(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut show_stage = false
  let mut show_others = false
  let mut show_deleted = false
  let mut show_directory = false
  let mut recurse_submodules = false
  let mut use_nul = false
  for arg in args {
    match arg {
      "-s" | "--stage" => show_stage = true
      "-c" | "--cached" => () // default mode, no-op
      "-o" | "--others" => show_others = true
      "-d" | "--deleted" => show_deleted = true
      "--directory" => show_directory = true
      "--recurse-submodules" => recurse_submodules = true
      "-z" => use_nul = true
      _ => ()
    }
  }
  let terminator = if use_nul { "\u0000" } else { "\n" }
  let entries = @gitlib.read_index_entries(fs, git_dir)
  if show_others {
    // Build set of tracked paths and their parent directories
    let tracked : Map[String, Bool] = {}
    let tracked_dirs : Map[String, Bool] = {}
    for e in entries {
      tracked[e.path] = true
      // Mark all parent directories as tracked
      let mut path = e.path
      while true {
        match path.rev_find("/") {
          Some(idx) => {
            let dir = (try! path[:idx]).to_string()
            tracked_dirs[dir] = true
            path = dir
          }
          None => break
        }
      }
    }
    if show_directory {
      // Show untracked directories (not individual files)
      let untracked_dirs = collect_untracked_dirs(fs, root, tracked_dirs)
      for dir in untracked_dirs {
        print_str(dir + "/" + terminator)
      }
    } else {
      // Show untracked files
      let all_files = @gitlib.list_working_files(fs, root)
      for path in all_files {
        if not(tracked.contains(path)) {
          print_str(path + terminator)
        }
      }
    }
    return ()
  }
  if show_deleted {
    // Show deleted files (in index but not in worktree)
    for e in entries {
      let abs = root + "/" + e.path
      if not(fs.is_file(abs)) {
        print_str(e.path + terminator)
      }
    }
    return ()
  }
  // Default: show cached (indexed) files
  // Parse submodules first if needed (to skip submodule entries)
  let submodules = if recurse_submodules {
    parse_gitmodules(fs, root)
  } else {
    []
  }
  let submod_paths : Map[String, Bool] = {}
  for submod in submodules {
    submod_paths[submod.path] = true
  }
  if show_stage {
    for e in entries {
      // Skip submodule entries (mode 160000) when recursing
      if recurse_submodules && e.mode == 0o160000 {
        continue
      }
      let mode = format_mode(e.mode)
      // Stage is always 0 for normal entries (no merge conflict)
      print_str("\{mode} \{e.id.to_hex()} 0\t\{e.path}" + terminator)
    }
    // Recurse into submodules
    for submod in submodules {
      let sub_git_dir = root + "/" + submod.path + "/.git"
      if fs.is_dir(sub_git_dir) || fs.is_file(sub_git_dir) {
        let actual_git_dir = resolve_gitdir(fs, sub_git_dir)
        let sub_entries = @gitlib.read_index_entries(fs, actual_git_dir)
        for se in sub_entries {
          let mode = format_mode(se.mode)
          let full_path = submod.path + "/" + se.path
          print_str("\{mode} \{se.id.to_hex()} 0\t\{full_path}" + terminator)
        }
      }
    }
  } else {
    for e in entries {
      // Skip submodule entries (mode 160000) when recursing
      if recurse_submodules && e.mode == 0o160000 {
        continue
      }
      print_str(e.path + terminator)
    }
    // Recurse into submodules
    for submod in submodules {
      let sub_git_dir = root + "/" + submod.path + "/.git"
      if fs.is_dir(sub_git_dir) || fs.is_file(sub_git_dir) {
        let actual_git_dir = resolve_gitdir(fs, sub_git_dir)
        let sub_entries = @gitlib.read_index_entries(fs, actual_git_dir)
        for se in sub_entries {
          let full_path = submod.path + "/" + se.path
          print_str(full_path + terminator)
        }
      }
    }
  }
}

///|
struct SubmoduleInfo {
  path : String
}

///|
/// Parse .gitmodules file to extract submodule paths
fn parse_gitmodules(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[SubmoduleInfo] {
  let gitmodules_path = root + "/.gitmodules"
  if not(fs.is_file(gitmodules_path)) {
    return []
  }
  let content = decode_bytes(fs.read_file(gitmodules_path)) catch {
    _ => return []
  }
  let result : Array[SubmoduleInfo] = []
  let mut current_name = ""
  let mut current_path = ""
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[submodule \"") && line.has_suffix("\"]") {
      // Save previous submodule if any
      if current_name.length() > 0 && current_path.length() > 0 {
        result.push({ path: current_path })
      }
      // Extract name from [submodule "name"]
      current_name = String::unsafe_substring(
        line,
        start=12,
        end=line.length() - 2,
      )
      current_path = ""
    } else if line.has_prefix("path") {
      let eq_idx = line.find("=")
      match eq_idx {
        Some(i) =>
          current_path = trim_string(
            String::unsafe_substring(line, start=i + 1, end=line.length()),
          )
        None => ()
      }
    }
  }
  // Don't forget the last one
  if current_name.length() > 0 && current_path.length() > 0 {
    result.push({ path: current_path })
  }
  result
}

///|
/// Resolve .git file to actual git directory (for submodules)
fn resolve_gitdir(fs : &@git.RepoFileSystem, git_path : String) -> String {
  if fs.is_dir(git_path) {
    return git_path
  }
  // It's a file with "gitdir: <path>" content
  let content = decode_bytes(fs.read_file(git_path)) catch {
    _ => return git_path
  }
  let trimmed = trim_string(content)
  if trimmed.has_prefix("gitdir: ") {
    let target = String::unsafe_substring(
      trimmed,
      start=8,
      end=trimmed.length(),
    )
    // If relative path, resolve relative to parent of .git file
    if not(target.has_prefix("/")) {
      let parent = match git_path.rev_find("/") {
        Some(i) => String::unsafe_substring(git_path, start=0, end=i)
        None => "."
      }
      return parent + "/" + target
    }
    return target
  }
  git_path
}

///|
/// Collect untracked directories at the top level
fn collect_untracked_dirs(
  fs : &@git.RepoFileSystem,
  root : String,
  tracked_dirs : Map[String, Bool],
) -> Array[String] raise @git.GitError {
  let result : Array[String] = []
  collect_untracked_dirs_recursive(fs, root, "", tracked_dirs, result)
  result.sort()
  result
}

///|
fn collect_untracked_dirs_recursive(
  fs : &@git.RepoFileSystem,
  root : String,
  prefix : String,
  tracked_dirs : Map[String, Bool],
  out : Array[String],
) -> Unit raise @git.GitError {
  let dir = if prefix == "" { root } else { root + "/" + prefix }
  let items = fs.readdir(dir)
  for name in items {
    if name == "." || name == ".." || name == ".git" {
      continue
    }
    let rel_path = if prefix == "" { name } else { prefix + "/" + name }
    let abs_path = root + "/" + rel_path
    if fs.is_dir(abs_path) {
      // Check if this directory or any of its subdirectories are tracked
      if tracked_dirs.contains(rel_path) {
        // This directory has tracked content, recurse into it
        collect_untracked_dirs_recursive(fs, root, rel_path, tracked_dirs, out)
      } else {
        // This directory is completely untracked, add it and don't recurse
        out.push(rel_path)
      }
    }
  }
}

///|
fn format_mode(mode : Int) -> String {
  // Convert mode to octal string (6 digits)
  let mut n = mode
  let digits : Array[String] = []
  while n > 0 {
    digits.push((n % 8).to_string())
    n = n / 8
  }
  while digits.length() < 6 {
    digits.push("0")
  }
  digits.rev_in_place()
  digits.iter().fold(init="", fn(acc, d) { acc + d })
}

///|
async fn handle_hash_object(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut write_object = false
  let mut stdin_mode = false
  let mut obj_type = "blob"
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-w" => write_object = true
      "--stdin" => stdin_mode = true
      "-t" => () // next arg is type, handled below
      _ if arg.has_prefix("-t") =>
        obj_type = String::unsafe_substring(arg, start=2, end=arg.length())
      _ if not(arg.has_prefix("-")) => paths.push(arg)
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
async fn handle_ls_tree(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut recursive = false
  let mut show_trees = false // -t option
  let mut only_trees = false // -d option: only show trees
  let mut name_only = false
  let mut recurse_submodules = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "-r" | "--recursive" => recursive = true
      "-t" => show_trees = true // Show tree entries when recursing
      "-d" => only_trees = true // Only show tree entries
      "--name-only" | "--name-status" => name_only = true
      "--recurse-submodules" => recurse_submodules = true
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => ()
    }
  }
  guard positional.length() > 0 else {
    raise @git.GitError::InvalidObject("tree-ish required")
  }
  let spec = positional[0]
  // Path filters are remaining positional arguments
  let path_filters : Array[String] = []
  for i in 1..<positional.length() {
    path_filters.push(positional[i])
  }
  let tree_id = @gitlib.rev_parse(fs, git_dir, spec)
  guard tree_id is Some(tid) else {
    raise @git.GitError::InvalidObject("Not a valid object name: \{spec}")
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  // Resolve to tree if it's a commit
  let actual_tree_id = resolve_to_tree(db, fs, tid)
  // Parse submodules if needed
  let submodules = if recurse_submodules {
    parse_gitmodules(fs, root)
  } else {
    []
  }
  print_tree_entries(
    db,
    fs,
    actual_tree_id,
    "",
    recursive,
    show_trees,
    only_trees,
    name_only,
    recurse_submodules,
    root,
    submodules,
    path_filters,
  )
}

///|
fn resolve_to_tree(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  let obj = db.get(fs, id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Object not found")
  }
  match o.obj_type {
    @git.ObjectType::Tree => id
    @git.ObjectType::Commit => {
      let info = @git.parse_commit(o.data)
      info.tree
    }
    _ => raise @git.GitError::InvalidObject("Not a tree or commit")
  }
}

///|
async fn print_tree_entries(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  recursive : Bool,
  show_trees : Bool,
  only_trees : Bool,
  name_only : Bool,
  recurse_submodules : Bool,
  root : String,
  submodules : Array[SubmoduleInfo],
  path_filters : Array[String],
) -> Unit raise Error {
  let obj = db.get(fs, tree_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Tree not found")
  }
  let entries = @git.parse_tree(o.data)
  for entry in entries {
    let path = if prefix.length() == 0 {
      entry.name
    } else {
      prefix + "/" + entry.name
    }
    let is_tree = entry.mode == "40000" || entry.mode == "040000"
    let is_submodule = entry.mode == "160000"
    // Path filtering logic
    let (matches_filter, should_recurse_for_filter) = if path_filters.length() ==
      0 {
      (true, true)
    } else {
      let mut match_found = false
      let mut recurse_needed = false
      for filter in path_filters {
        let has_trailing_slash = filter.has_suffix("/")
        let filter_clean = if has_trailing_slash {
          String::unsafe_substring(filter, start=0, end=filter.length() - 1)
        } else {
          filter
        }
        // Exact match (without trailing slash)
        if path == filter_clean {
          if has_trailing_slash {
            // "path2/" means list contents of path2, so recurse but don't print path2 itself
            if is_tree {
              recurse_needed = true
            }
            // If it's a file with trailing slash filter, it's a no-match (file has no children)
          } else {
            // "path2" means show path2 entry itself, don't recurse further
            match_found = true
          }
          continue
        }
        // Entry is under the filter path (filter is prefix of path)
        // e.g., filter="path2/" and path="path2/baz"
        if path.has_prefix(filter_clean + "/") {
          // Only show descendants if filter has trailing slash
          // Without trailing slash, exact match only (handled above)
          if has_trailing_slash {
            // Check if this is a direct child of the filter
            let rest = String::unsafe_substring(
              path,
              start=filter_clean.length() + 1,
              end=path.length(),
            )
            let is_direct_child = rest.find("/") == None
            // "path2/" means show only direct children
            if is_direct_child {
              match_found = true
            }
          }
          continue
        }
        // Filter is under the entry path (need to recurse into this tree to find it)
        // e.g., path="path2" and filter="path2/baz"
        if filter_clean.has_prefix(path + "/") {
          recurse_needed = true
        }
      }
      (match_found, recurse_needed)
    }
    if not(matches_filter) && not(should_recurse_for_filter) {
      continue
    }
    // Skip submodule entries when recurse_submodules is enabled
    // (we'll recurse into them instead of listing them)
    if recurse_submodules && is_submodule {
      // Find matching submodule info
      let mut found_submod = false
      for s in submodules {
        if s.path == path {
          found_submod = true
          break
        }
      }
      if found_submod {
        // Resolve the submodule's git directory
        let sub_git_path = root + "/" + path + "/.git"
        let sub_git_dir = resolve_gitdir(fs, sub_git_path)
        // Load the submodule's object database
        let sub_db = @gitlib.ObjectDb::load(fs, sub_git_dir)
        // entry.id is the commit SHA in the submodule
        // Resolve it to a tree
        let sub_tree_id = resolve_to_tree(sub_db, fs, entry.id) catch {
          _ => continue // Skip if can't resolve submodule tree
        }
        // Recursively print submodule tree entries
        print_tree_entries(
          sub_db,
          fs,
          sub_tree_id,
          path,
          recursive,
          show_trees,
          only_trees,
          name_only,
          recurse_submodules,
          root + "/" + path,
          [], // No nested submodules for now
          path_filters,
        )
      }
      continue
    }
    // With -d, only show tree entries
    // With -r, don't print tree entries unless -t is also specified
    // With -t and path filters, show tree entries we're traversing through
    let should_print = if not(matches_filter) &&
      not(show_trees && should_recurse_for_filter && is_tree) {
      false // Don't print if path doesn't match filters (unless -t and traversing trees)
    } else if only_trees {
      is_tree // Only print tree entries
    } else {
      not(recursive) || not(is_tree) || show_trees
    }
    if should_print {
      if name_only {
        print_line(path)
      } else {
        let mode_str = if entry.mode == "40000" { "040000" } else { entry.mode }
        let type_str = if is_tree {
          "tree"
        } else if is_submodule {
          "commit"
        } else {
          "blob"
        }
        print_line("\{mode_str} \{type_str} \{entry.id.to_hex()}\t\{path}")
      }
    }
    // Recurse if -r is set, or if we need to look deeper for path filters
    // (but only for filter recursion when actually needed, not when filters are empty)
    let need_recurse = recursive ||
      (should_recurse_for_filter && path_filters.length() > 0)
    if need_recurse && is_tree {
      print_tree_entries(
        db,
        fs,
        entry.id,
        path,
        recursive,
        show_trees,
        only_trees,
        name_only,
        recurse_submodules,
        root,
        submodules,
        path_filters,
      )
    }
  }
}

///|
async fn handle_write_tree(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse --prefix option
  let mut prefix : String? = None
  for arg in args {
    if arg.has_prefix("--prefix=") {
      prefix = Some((try! arg[9:]).to_string())
    }
  }
  let entries = @gitlib.read_index_entries(fs, git_dir)
  let tree_id = @gitlib.write_tree_from_index(fs, git_dir, entries, prefix~)
  print_line(tree_id.to_hex())
}

///|
async fn handle_show_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut heads_only = false
  let mut tags_only = false
  for arg in args {
    match arg {
      "--heads" => heads_only = true
      "--tags" => tags_only = true
      _ => ()
    }
  }
  let refs = @gitlib.show_ref(fs, git_dir)
  for item in refs {
    let (refname, id) = item
    if heads_only && not(refname.has_prefix("refs/heads/")) {
      continue
    }
    if tags_only && not(refname.has_prefix("refs/tags/")) {
      continue
    }
    print_line("\{id.to_hex()} \{refname}")
  }
}

///|
async fn handle_update_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut delete_mode = false
  let mut create_reflog = false
  let mut no_deref = false
  let mut message : String? = None
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-d" | "--delete" => delete_mode = true
      "--create-reflog" => create_reflog = true
      "--no-deref" => no_deref = true
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 1
      }
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => ()
    }
    i += 1
  }
  ignore(no_deref)
  // Check if bare repo
  let is_bare = fs.is_file(git_dir + "/config") &&
    not(fs.is_dir(root + "/.git"))
  let actual_git_dir = if is_bare { root } else { git_dir }
  // Get current timestamp for reflog
  let timestamp = get_current_timestamp()
  let timezone = "+0000"
  let (author, email) = get_author_info(fs, actual_git_dir)
  if delete_mode {
    if positional.length() < 1 {
      raise @git.GitError::InvalidObject("usage: git update-ref -d <refname>")
    }
    let refname = positional[0]
    let old_value : String? = if positional.length() >= 2 {
      Some(positional[1])
    } else {
      None
    }
    let ref_path = actual_git_dir + "/" + refname
    // Check oldvalue if specified
    if old_value is Some(ov) {
      let current = read_ref_value(fs, actual_git_dir, refname)
      match current {
        Some(cur_id) =>
          if cur_id.to_hex() != ov {
            eprint_line(
              "error: cannot lock ref '\{refname}': is at \{cur_id.to_hex()} but expected \{ov}",
            )
            @sys.exit(1)
          }
        None => {
          eprint_line(
            "error: cannot lock ref '\{refname}': unable to resolve reference",
          )
          @sys.exit(1)
        }
      }
    }
    // Get old value for reflog before deleting
    let old_id = read_ref_value(fs, actual_git_dir, refname).unwrap_or(
      @git.ObjectId::zero(),
    )
    // Delete the ref
    if fs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    // Write reflog entry for deletion
    let rfs : &@git.RepoFileSystem = fs
    let wfs : &@git.FileSystem = fs
    let (should_log, _) = @gitlib.should_log_ref(
      rfs, actual_git_dir, refname, is_bare,
    )
    if should_log || @gitlib.reflog_exists(rfs, actual_git_dir, refname) {
      let msg = message.unwrap_or("update-ref: delete")
      @gitlib.append_reflog(
        wfs,
        rfs,
        actual_git_dir,
        refname,
        old_id,
        @git.ObjectId::zero(),
        author,
        email,
        timestamp,
        timezone,
        msg,
      )
    }
    return ()
  }
  if positional.length() < 2 {
    raise @git.GitError::InvalidObject(
      "usage: git update-ref <refname> <newvalue> [<oldvalue>]",
    )
  }
  let refname = positional[0]
  let new_value = positional[1]
  let old_value : String? = if positional.length() >= 3 {
    Some(positional[2])
  } else {
    None
  }
  let new_id = @git.ObjectId::from_hex(new_value)
  // Get current value
  let current_id = read_ref_value(fs, actual_git_dir, refname)
  // Check oldvalue if specified
  match old_value {
    Some(ov) => {
      let expected_id = @git.ObjectId::from_hex(ov)
      match current_id {
        Some(cur_id) =>
          if cur_id.to_hex() != expected_id.to_hex() {
            eprint_line(
              "error: cannot lock ref '\{refname}': is at \{cur_id.to_hex()} but expected \{expected_id.to_hex()}",
            )
            @sys.exit(1)
          }
        None =>
          if expected_id.to_hex() != @git.ObjectId::zero().to_hex() {
            eprint_line(
              "error: cannot lock ref '\{refname}': unable to resolve reference '\{refname}'",
            )
            @sys.exit(1)
          }
      }
    }
    None => ()
  }
  let ref_path = actual_git_dir + "/" + refname
  // Ensure parent directory exists
  let dir = match ref_path.rev_find("/") {
    None => ""
    Some(i) => String::unsafe_substring(ref_path, start=0, end=i)
  }
  if dir.length() > 0 && not(fs.is_dir(dir)) {
    fs.mkdir_p(dir)
  }
  // Write the ref
  fs.write_string(ref_path, new_id.to_hex() + "\n")
  // Handle reflog
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let (should_log, always) = @gitlib.should_log_ref(
    rfs, actual_git_dir, refname, is_bare,
  )
  if create_reflog {
    // Create reflog if requested
    @gitlib.create_reflog(wfs, rfs, actual_git_dir, refname)
  }
  if should_log ||
    always ||
    create_reflog ||
    @gitlib.reflog_exists(rfs, actual_git_dir, refname) {
    let old_id = current_id.unwrap_or(@git.ObjectId::zero())
    let msg = message.unwrap_or("update-ref: updating")
    @gitlib.append_reflog(
      wfs, rfs, actual_git_dir, refname, old_id, new_id, author, email, timestamp,
      timezone, msg,
    )
  }
}

///|
fn read_ref_value(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @git.ObjectId? {
  let ref_path = git_dir + "/" + refname
  if fs.is_file(ref_path) {
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return None
    }
    let hex = trim_chars(content, " \t\r\n")
    if hex.has_prefix("ref: ") {
      // Symbolic ref - resolve it
      let target = String::unsafe_substring(hex, start=5, end=hex.length())
      return read_ref_value(fs, git_dir, target)
    }
    Some(@git.ObjectId::from_hex(hex)) catch {
      _ => None
    }
  } else {
    // Check packed-refs
    @gitlib.resolve_ref(fs, git_dir, refname) catch {
      _ => None
    }
  }
}

///|
fn get_author_info(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> (String, String) {
  // Try to get from config or environment
  let config_path = git_dir + "/config"
  let mut name = "Unknown"
  let mut email = "unknown@unknown"
  // Check environment variables first
  match @sys.get_env_var("GIT_COMMITTER_NAME") {
    Some(n) => name = n
    None => ()
  }
  match @sys.get_env_var("GIT_COMMITTER_EMAIL") {
    Some(e) => email = e
    None => ()
  }
  // If not in env, try config
  if name == "Unknown" || email == "unknown@unknown" {
    if fs.is_file(config_path) {
      let content = decode_bytes(fs.read_file(config_path)) catch {
        _ => return (name, email)
      }
      let mut in_user = false
      for line_view in content.split("\n") {
        let line = trim_chars(line_view.to_string(), " \t\r")
        if line.has_prefix("[user]") {
          in_user = true
          continue
        }
        if line.has_prefix("[") {
          in_user = false
          continue
        }
        if in_user {
          if line.has_prefix("name") {
            let eq_idx = line.find("=")
            match eq_idx {
              Some(i) =>
                name = trim_chars(
                  String::unsafe_substring(line, start=i + 1, end=line.length()),
                  " \t",
                )
              None => ()
            }
          }
          if line.has_prefix("email") {
            let eq_idx = line.find("=")
            match eq_idx {
              Some(i) =>
                email = trim_chars(
                  String::unsafe_substring(line, start=i + 1, end=line.length()),
                  " \t",
                )
              None => ()
            }
          }
        }
      }
    }
  }
  (name, email)
}

///|
async fn handle_symbolic_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut delete_mode = false
  let mut short_mode = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "-d" | "--delete" => delete_mode = true
      "--short" => short_mode = true
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => ()
    }
  }
  if positional.length() == 0 {
    raise @git.GitError::InvalidObject("usage: git symbolic-ref <name> [<ref>]")
  }
  let name = positional[0]
  let ref_path = if name == "HEAD" {
    git_dir + "/HEAD"
  } else {
    git_dir + "/" + name
  }
  if delete_mode {
    if fs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    return ()
  }
  if positional.length() == 1 {
    // Read mode
    if not(fs.is_file(ref_path)) {
      raise @git.GitError::InvalidObject("ref \{name} not found")
    }
    let content = decode_bytes(fs.read_file(ref_path))
    let trimmed = content.trim_end(chars="\n\r ").to_string()
    if trimmed.has_prefix("ref: ") {
      let target = String::unsafe_substring(
        trimmed,
        start=5,
        end=trimmed.length(),
      )
      if short_mode && target.has_prefix("refs/heads/") {
        print_line(
          String::unsafe_substring(target, start=11, end=target.length()),
        )
      } else {
        print_line(target)
      }
    } else {
      raise @git.GitError::InvalidObject("ref \{name} is not a symbolic ref")
    }
  } else {
    // Write mode
    let target = positional[1]
    fs.write_string(ref_path, "ref: \{target}\n")
  }
}

///|
async fn handle_reflog(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  if args.length() == 0 {
    // Default to show HEAD
    show_reflog(rfs, git_dir, "HEAD")
    return
  }
  let subcmd = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "show" => {
      let refname = if rest.length() > 0 { rest[0] } else { "HEAD" }
      show_reflog(rfs, git_dir, refname)
    }
    "exists" => {
      if rest.length() == 0 {
        eprint_line("usage: git reflog exists <ref>")
        @sys.exit(1)
      }
      let refname = rest[0]
      if @gitlib.reflog_exists(rfs, git_dir, refname) {
        @sys.exit(0)
      } else {
        @sys.exit(1)
      }
    }
    "delete" => {
      if rest.length() == 0 {
        eprint_line("usage: git reflog delete <ref>")
        @sys.exit(1)
      }
      let refname = rest[0]
      @gitlib.delete_reflog(wfs, rfs, git_dir, refname)
    }
    "expire" =>
      // For now, just a no-op (would need to implement expiry logic)
      ()
    _ =>
      // Treat as a ref name for show
      show_reflog(rfs, git_dir, subcmd)
  }
}

///|
async fn show_reflog(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Unit raise Error {
  let entries = @gitlib.read_reflog(fs, git_dir, refname)
  // Show in reverse order (newest first)
  let len = entries.length()
  for i in 0..<len {
    let idx = len - 1 - i
    let entry = entries[idx]
    let short_sha = String::unsafe_substring(
      entry.new_id.to_hex(),
      start=0,
      end=7,
    )
    print_line("\{short_sha} \{refname}@{\{i}}: \{entry.message}")
  }
}
