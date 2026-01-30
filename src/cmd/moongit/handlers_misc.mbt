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
  name : String
  path : String
  url : String
}

///|
/// Parse .gitmodules file to extract submodule info
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
  let mut current_url = ""
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[submodule \"") && line.has_suffix("\"]") {
      // Save previous submodule if any
      if current_name.length() > 0 && current_path.length() > 0 {
        result.push({ name: current_name, path: current_path, url: current_url })
      }
      // Extract name from [submodule "name"]
      current_name = String::unsafe_substring(
        line,
        start=12,
        end=line.length() - 2,
      )
      current_path = ""
      current_url = ""
    } else if line.has_prefix("path") {
      let eq_idx = line.find("=")
      match eq_idx {
        Some(i) =>
          current_path = trim_string(
            String::unsafe_substring(line, start=i + 1, end=line.length()),
          )
        None => ()
      }
    } else if line.has_prefix("url") {
      let eq_idx = line.find("=")
      match eq_idx {
        Some(i) =>
          current_url = trim_string(
            String::unsafe_substring(line, start=i + 1, end=line.length()),
          )
        None => ()
      }
    }
  }
  // Don't forget the last one
  if current_name.length() > 0 && current_path.length() > 0 {
    result.push({ name: current_name, path: current_path, url: current_url })
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
    db, fs, actual_tree_id, "", recursive, show_trees, only_trees, name_only, recurse_submodules,
    root, submodules, path_filters,
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

///|
async fn handle_gc(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut prune_only = false
  let mut aggressive = false
  let mut quiet = false
  for arg in args {
    match arg {
      "--prune" => prune_only = true
      "--aggressive" => aggressive = true
      "-q" | "--quiet" => quiet = true
      _ => ()
    }
  }
  ignore(aggressive) // Not yet implemented, treat as regular gc
  if prune_only {
    let result = @gitlib.prune_repo(fs, fs, root)
    if not(quiet) && result.pruned.length() > 0 {
      print_line("Pruned \{result.pruned.length()} unreachable objects")
    }
    return
  }
  let result = @gitlib.gc_repo(fs, fs, root)
  if not(quiet) {
    match result.pack {
      Some(pack) =>
        print_line(
          "Repacked \{pack.object_count} objects into pack-\{pack.pack_id.to_hex()[:8].to_string()}",
        )
      None => ()
    }
    if result.dangling.length() > 0 {
      print_line("Found \{result.dangling.length()} dangling objects")
    }
  }
}

///|
async fn handle_clean(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut force = false
  let mut dry_run = false
  let mut remove_dirs = false
  let mut remove_ignored = false
  let mut remove_only_ignored = false
  let mut quiet = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "-n" | "--dry-run" => dry_run = true
      "-d" => remove_dirs = true
      "-x" => remove_ignored = true
      "-X" => remove_only_ignored = true
      "-q" | "--quiet" => quiet = true
      "-fd" | "-df" => {
        force = true
        remove_dirs = true
      }
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  // git clean requires -f unless -n is specified
  if not(force) && not(dry_run) {
    eprint_line(
      "fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean",
    )
    @sys.exit(1)
  }
  // Get untracked files from status
  let status = @gitlib.status(fs, root)
  let mut files_to_clean : Array[String] = []
  if remove_only_ignored {
    // -X: only ignored files (not implemented - need gitignore parsing)
    eprint_line("warning: -X (remove only ignored) not fully implemented")
  } else {
    // Regular untracked files
    for p in status.untracked {
      files_to_clean.push(p)
    }
  }
  // Filter by paths if specified
  if paths.length() > 0 {
    files_to_clean = files_to_clean
      .iter()
      .filter(fn(f) {
        paths.iter().any(fn(p) { f == p || f.has_prefix(p + "/") })
      })
      .collect()
  }
  // Process files
  let dirs_to_check : Array[String] = []
  for path in files_to_clean {
    let abs_path = root + "/" + path
    if dry_run {
      print_line("Would remove \{path}")
    } else if fs.is_file(abs_path) {
      fs.remove_file(abs_path)
      if not(quiet) {
        print_line("Removing \{path}")
      }
      // Track parent directory for potential removal
      if remove_dirs {
        match path.rev_find("/") {
          Some(idx) => {
            let parent = String::unsafe_substring(path, start=0, end=idx)
            if not(dirs_to_check.contains(parent)) {
              dirs_to_check.push(parent)
            }
          }
          None => ()
        }
      }
    } else if fs.is_dir(abs_path) && remove_dirs {
      remove_dir_recursive(fs, abs_path)
      if not(quiet) {
        print_line("Removing \{path}/")
      }
    }
  }
  // Remove empty directories if -d flag
  if remove_dirs && not(dry_run) {
    // Sort by depth (deepest first)
    dirs_to_check.sort_by(fn(a, b) { b.length() - a.length() })
    for dir in dirs_to_check {
      let abs_dir = root + "/" + dir
      if fs.is_dir(abs_dir) {
        let rfs : &@git.RepoFileSystem = fs
        let entries = rfs.readdir(abs_dir) catch { _ => continue }
        if entries.length() == 0 {
          let wfs : &@git.FileSystem = fs
          wfs.remove_dir(abs_dir) catch {
            _ => ()
          }
          if not(quiet) {
            print_line("Removing \{dir}/")
          }
        }
      }
    }
  }
  ignore(remove_ignored)
}

///|
fn remove_dir_recursive(fs : OsFs, path : String) -> Unit {
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let entries = rfs.readdir(path) catch { _ => return }
  for entry in entries {
    let full = path + "/" + entry
    if rfs.is_dir(full) {
      remove_dir_recursive(fs, full)
    } else {
      wfs.remove_file(full) catch {
        _ => ()
      }
    }
  }
  wfs.remove_dir(path) catch {
    _ => ()
  }
}

///|
async fn handle_grep(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut show_line_numbers = false
  let mut ignore_case = false
  let mut files_only = false
  let mut count_only = false
  let mut invert_match = false
  let mut pattern : String? = None
  let paths : Array[String] = []
  let mut after_dashdash = false
  for arg in args {
    if after_dashdash {
      paths.push(arg)
      continue
    }
    match arg {
      "--" => after_dashdash = true
      "-n" | "--line-number" => show_line_numbers = true
      "-i" | "--ignore-case" => ignore_case = true
      "-l" | "--files-with-matches" | "--name-only" => files_only = true
      "-c" | "--count" => count_only = true
      "-v" | "--invert-match" => invert_match = true
      "-e" => () // next arg is pattern, handled below
      _ if arg.has_prefix("-e") =>
        pattern = Some(String::unsafe_substring(arg, start=2, end=arg.length()))
      _ if not(arg.has_prefix("-")) =>
        if pattern is None {
          pattern = Some(arg)
        } else {
          paths.push(arg)
        }
      _ => ()
    }
  }
  guard pattern is Some(pat) else {
    raise @git.GitError::InvalidObject("fatal: no pattern given")
  }
  // Get files from index
  let index_entries = @gitlib.read_index_entries(fs, git_dir)
  let files_to_search : Array[String] = []
  if paths.length() == 0 {
    for e in index_entries {
      files_to_search.push(e.path)
    }
  } else {
    for e in index_entries {
      for p in paths {
        if e.path == p || e.path.has_prefix(p + "/") {
          files_to_search.push(e.path)
          break
        }
      }
    }
  }
  // Search each file
  let mut found_any = false
  for file_path in files_to_search {
    let abs_path = root + "/" + file_path
    if not(fs.is_file(abs_path)) {
      continue
    }
    let content = decode_bytes(fs.read_file(abs_path)) catch { _ => continue }
    let lines = content.split("\n")
    let mut match_count = 0
    let mut line_num = 0
    let matches : Array[(Int, String)] = []
    for line_view in lines {
      line_num += 1
      let line = line_view.to_string()
      let matched = if ignore_case {
        line.to_lower().contains(pat.to_lower())
      } else {
        line.contains(pat)
      }
      let should_output = if invert_match { not(matched) } else { matched }
      if should_output {
        match_count += 1
        matches.push((line_num, line))
      }
    }
    if match_count > 0 {
      found_any = true
      if files_only {
        print_line(file_path)
      } else if count_only {
        print_line("\{file_path}:\{match_count}")
      } else {
        for item in matches {
          let (num, line) = item
          if show_line_numbers {
            print_line("\{file_path}:\{num}:\{line}")
          } else {
            print_line("\{file_path}:\{line}")
          }
        }
      }
    }
  }
  if not(found_any) {
    @sys.exit(1)
  }
}

///|
async fn handle_submodule(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let subcmd = args.get(0).unwrap_or("")
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "" | "status" => handle_submodule_status(fs, root, git_dir, rest)
    "init" => handle_submodule_init(fs, root, git_dir, rest)
    "update" => handle_submodule_update(fs, root, git_dir, rest)
    "deinit" => handle_submodule_deinit(fs, root, git_dir, rest)
    "sync" => handle_submodule_sync(fs, root, git_dir, rest)
    _ => {
      eprint_line("error: unknown submodule command: \{subcmd}")
      @sys.exit(1)
    }
  }
}

///|
async fn handle_submodule_status(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--recursive" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let sub_git = sub_path + "/.git"
    // Check if initialized
    if not(rfs.is_file(sub_git)) && not(rfs.is_dir(sub_git)) {
      print_line("-\{String::make(40, '0')} \{sub.path}")
      continue
    }
    // Get HEAD of submodule
    let sub_git_dir = resolve_gitdir(rfs, sub_git)
    let head_id = @gitlib.resolve_head_commit(rfs, sub_git_dir) catch {
      _ => {
        print_line("-\{String::make(40, '0')} \{sub.path}")
        continue
      }
    }
    match head_id {
      Some(id) => {
        // Check against index
        let index_id = get_submodule_index_id(rfs, git_dir, sub.path)
        let prefix = match index_id {
          Some(idx) if idx.to_hex() == id.to_hex() => " "
          Some(_) => "+"
          None => " "
        }
        print_line("\{prefix}\{id.to_hex()} \{sub.path}")
      }
      None => print_line("-\{String::make(40, '0')} \{sub.path}")
    }
    // Handle recursive
    if recursive {
      let nested = sub_path + "/.gitmodules"
      if rfs.is_file(nested) {
        handle_submodule_status(fs, sub_path, sub_git_dir, args)
      }
    }
  }
}

///|
fn get_submodule_index_id(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  path : String,
) -> @git.ObjectId? {
  let entries = @gitlib.read_index_entries(fs, git_dir) catch {
    _ => return None
  }
  for e in entries {
    if e.path == path {
      return Some(e.id)
    }
  }
  None
}

///|
async fn handle_submodule_init(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let paths : Array[String] = []
  for arg in args {
    if not(arg.has_prefix("-")) {
      paths.push(arg)
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    // Write to .git/config
    let config_path = git_dir + "/config"
    let config_content = if rfs.is_file(config_path) {
      decode_bytes(rfs.read_file(config_path))
    } else {
      ""
    }
    let section = "[submodule \"\{sub.name}\"]"
    if config_content.contains(section) {
      continue
    }
    let new_section = "\n\{section}\n\tactive = true\n\turl = \{sub.url}\n"
    wfs.write_string(config_path, config_content + new_section)
    print_line(
      "Submodule '\{sub.name}' (\{sub.url}) registered for path '\{sub.path}'",
    )
  }
}

///|
async fn handle_submodule_update(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut init = false
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--init" => init = true
      "--recursive" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  // Init first if requested
  if init {
    handle_submodule_init(fs, root, git_dir, paths)
  }
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let modules_dir = git_dir + "/modules/" + sub.name
    // Get expected commit from index
    let expected_id = get_submodule_index_id(rfs, git_dir, sub.path)
    guard expected_id is Some(target_id) else { continue }
    let sub_git = sub_path + "/.git"
    // Clone if needed
    if not(rfs.is_file(sub_git)) && not(rfs.is_dir(sub_git)) {
      print_line("Cloning into '\{sub.path}'...")
      wfs.mkdir_p(modules_dir)
      // Use system git for clone
      let clone_result = run_git_command([
        "clone",
        "--bare",
        sub.url,
        modules_dir,
      ])
      if clone_result != 0 {
        eprint_line("Failed to clone \{sub.url}")
        continue
      }
      // Create .git file
      let rel_path = get_rel_path(sub_path, modules_dir)
      wfs.write_string(sub_git, "gitdir: \{rel_path}\n")
    }
    // Checkout target commit
    let sub_git_dir = resolve_gitdir(rfs, sub_git)
    print_line(
      "Submodule path '\{sub.path}': checked out '\{target_id.to_hex()}'",
    )
    // Use checkout command
    run_checkout_in_submodule(wfs, rfs, sub_path, sub_git_dir, target_id)
    // Handle recursive
    if recursive {
      let nested = sub_path + "/.gitmodules"
      if rfs.is_file(nested) {
        handle_submodule_update(fs, sub_path, sub_git_dir, args)
      }
    }
  }
}

///|
async fn run_git_command(args : Array[String]) -> Int {
  // Find real git
  let real_git = @sys.get_env_var("SHIM_REAL_GIT").unwrap_or("git")
  @process.run(real_git, args)
}

///|
fn run_checkout_in_submodule(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  work_tree : String,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit {
  // Read tree from commit and checkout files
  let db = @gitlib.ObjectDb::load(rfs, git_dir) catch { _ => return }
  let obj = db.get(rfs, commit_id) catch { _ => return }
  guard obj is Some(o) else { return }
  let commit_info = @git.parse_commit(o.data) catch { _ => return }
  // Get tree entries
  let tree_obj = db.get(rfs, commit_info.tree) catch { _ => return }
  guard tree_obj is Some(to) else { return }
  // Recursively checkout tree
  checkout_tree_recursive(wfs, rfs, db, work_tree, "", to.data)
}

///|
fn checkout_tree_recursive(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  db : @gitlib.ObjectDb,
  work_tree : String,
  prefix : String,
  tree_data : Bytes,
) -> Unit {
  let entries = @git.parse_tree(tree_data) catch { _ => return }
  for entry in entries {
    let path = if prefix.length() > 0 {
      prefix + "/" + entry.name
    } else {
      entry.name
    }
    let full_path = work_tree + "/" + path
    if entry.mode == "40000" {
      // Directory - recurse
      wfs.mkdir_p(full_path) catch {
        _ => ()
      }
      let sub_obj = db.get(rfs, entry.id) catch { _ => continue }
      guard sub_obj is Some(so) else { continue }
      checkout_tree_recursive(wfs, rfs, db, work_tree, path, so.data)
    } else if entry.mode == "160000" {
      // Submodule - skip
      continue
    } else {
      // File
      let obj = db.get(rfs, entry.id) catch { _ => continue }
      guard obj is Some(o) else { continue }
      // Ensure parent directory exists
      match full_path.rev_find("/") {
        Some(idx) => {
          let parent = String::unsafe_substring(full_path, start=0, end=idx)
          wfs.mkdir_p(parent) catch {
            _ => ()
          }
        }
        None => ()
      }
      wfs.write_file(full_path, o.data) catch {
        _ => ()
      }
    }
  }
}

///|
fn get_rel_path(from : String, to : String) -> String {
  let from_parts : Array[String] = from
    .split("/")
    .filter(fn(s) { s.to_string().length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  let to_parts : Array[String] = to
    .split("/")
    .filter(fn(s) { s.to_string().length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  // Find common prefix
  let mut common = 0
  while common < from_parts.length() && common < to_parts.length() {
    if from_parts[common] == to_parts[common] {
      common += 1
    } else {
      break
    }
  }
  // Build relative path
  let mut result = ""
  for _ in 0..<(from_parts.length() - common) {
    result = result + "../"
  }
  for i in common..<to_parts.length() {
    if result.length() > 0 && not(result.has_suffix("/")) {
      result = result + "/"
    }
    result = result + to_parts[i]
  }
  result
}

///|
async fn handle_submodule_deinit(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut force = false
  let mut all = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "--all" => all = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if not(all) && paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    let sub_path = root + "/" + sub.path
    // Check for local modifications
    if not(force) && rfs.is_dir(sub_path) {
      let sub_git_dir = resolve_gitdir(rfs, sub_path + "/.git")
      if rfs.is_dir(sub_git_dir) {
        let status = @gitlib.status(rfs, sub_path) catch { _ => continue }
        if status.unstaged_modified.length() > 0 {
          eprint_line(
            "error: '\{sub.path}' has local modifications (use --force)",
          )
          @sys.exit(1)
        }
      }
    }
    // Remove from .git/config
    let config_path = git_dir + "/config"
    if rfs.is_file(config_path) {
      let content = decode_bytes(rfs.read_file(config_path))
      let new_content = remove_config_section(content, "submodule", sub.name)
      wfs.write_string(config_path, new_content)
    }
    // Clear working directory
    if rfs.is_dir(sub_path) {
      let entries = rfs.readdir(sub_path) catch { _ => continue }
      for e in entries {
        if e == ".git" {
          continue
        }
        let full = sub_path + "/" + e
        if rfs.is_dir(full) {
          remove_dir_recursive(fs, full)
        } else {
          wfs.remove_file(full) catch {
            _ => ()
          }
        }
      }
    }
    print_line("Cleared directory '\{sub.path}'")
  }
}

///|
fn remove_config_section(
  content : String,
  section_type : String,
  name : String,
) -> String {
  let lines : Array[String] = []
  let mut skip = false
  let target = "[\{section_type} \"\{name}\"]"
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      skip = trimmed == target
    }
    if not(skip) {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
async fn handle_submodule_sync(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--recursive" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    // Update .git/config
    let config_path = git_dir + "/config"
    if rfs.is_file(config_path) {
      let content = decode_bytes(rfs.read_file(config_path))
      let section = "[submodule \"\{sub.name}\"]"
      if content.contains(section) {
        let updated = update_config_value(content, sub.name, "url", sub.url)
        wfs.write_string(config_path, updated)
      }
    }
    // Update submodule's origin URL
    let sub_path = root + "/" + sub.path
    let sub_git_dir = resolve_gitdir(rfs, sub_path + "/.git")
    let sub_config = sub_git_dir + "/config"
    if rfs.is_file(sub_config) {
      let content = decode_bytes(rfs.read_file(sub_config))
      let updated = update_remote_origin(content, sub.url)
      wfs.write_string(sub_config, updated)
    }
    print_line("Synchronizing submodule url for '\{sub.path}'")
    // Handle recursive
    if recursive {
      let nested = sub_path + "/.gitmodules"
      if rfs.is_file(nested) {
        handle_submodule_sync(fs, sub_path, sub_git_dir, args)
      }
    }
  }
}

///|
fn update_config_value(
  content : String,
  name : String,
  key : String,
  value : String,
) -> String {
  let lines : Array[String] = []
  let mut in_section = false
  let mut updated = false
  let target = "[submodule \"\{name}\"]"
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      in_section = trimmed == target
    }
    if in_section && trimmed.has_prefix(key + " =") && not(updated) {
      lines.push("\t\{key} = \{value}")
      updated = true
    } else {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
fn update_remote_origin(content : String, url : String) -> String {
  let lines : Array[String] = []
  let mut in_origin = false
  let mut updated = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      in_origin = trimmed == "[remote \"origin\"]"
    }
    if in_origin && trimmed.has_prefix("url =") && not(updated) {
      lines.push("\turl = \{url}")
      updated = true
    } else {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
async fn handle_revert(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut no_commit = false
  let mut mainline : Int? = None
  let mut do_continue = false
  let mut do_abort = false
  let mut do_skip = false
  let commits : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--no-commit" => no_commit = true
      "-m" if i + 1 < args.length() => {
        mainline = Some(@strconv.parse_int(args[i + 1]))
        i += 1
      }
      _ if arg.has_prefix("-m") =>
        mainline = Some(
          @strconv.parse_int(
            String::unsafe_substring(arg, start=2, end=arg.length()),
          ),
        )
      "--continue" => do_continue = true
      "--abort" => do_abort = true
      "--skip" => do_skip = true
      _ if not(arg.has_prefix("-")) => commits.push(arg)
      _ => ()
    }
    i += 1
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let revert_head_path = git_dir + "/REVERT_HEAD"
  let merge_msg_path = git_dir + "/MERGE_MSG"
  let orig_head_path = git_dir + "/ORIG_HEAD"
  // Handle --abort
  if do_abort {
    if not(rfs.is_file(revert_head_path)) {
      eprint_line("error: no revert in progress")
      @sys.exit(1)
    }
    // Restore ORIG_HEAD if exists
    if rfs.is_file(orig_head_path) {
      let orig_hex = trim_chars(
        decode_bytes(rfs.read_file(orig_head_path)),
        " \t\r\n",
      )
      // Reset to ORIG_HEAD
      ignore(@gitlib.reset(wfs, rfs, root, orig_hex, @gitlib.ResetMode::Hard))
      wfs.remove_file(orig_head_path) catch {
        _ => ()
      }
    }
    // Clean up state files
    wfs.remove_file(revert_head_path) catch {
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      _ => ()
    }
    print_line("Revert aborted.")
    return
  }
  // Handle --skip
  if do_skip {
    if not(rfs.is_file(revert_head_path)) {
      eprint_line("error: no revert in progress")
      @sys.exit(1)
    }
    // Clean up state files (skip current revert)
    wfs.remove_file(revert_head_path) catch {
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      _ => ()
    }
    // Reset index to HEAD
    ignore(@gitlib.reset(wfs, rfs, root, "HEAD", @gitlib.ResetMode::Mixed))
    print_line("Revert skipped.")
    return
  }
  // Handle --continue
  if do_continue {
    if not(rfs.is_file(revert_head_path)) {
      eprint_line("error: no revert in progress")
      @sys.exit(1)
    }
    // Read the commit message from MERGE_MSG
    let msg = if rfs.is_file(merge_msg_path) {
      decode_bytes(rfs.read_file(merge_msg_path))
    } else {
      "Revert commit\n"
    }
    // Create the commit
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    let new_commit_id = @gitlib.commit(wfs, rfs, root, msg, author, timestamp)
    let short_id = (try! new_commit_id.to_hex()[:7]).to_string()
    let first_line = match msg.find("\n") {
      Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
      None => msg
    }
    print_line("[\{short_id}] \{first_line}")
    // Clean up state files
    wfs.remove_file(revert_head_path) catch {
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      _ => ()
    }
    wfs.remove_file(orig_head_path) catch {
      _ => ()
    }
    return
  }
  // Normal revert
  if commits.length() == 0 {
    raise @git.GitError::InvalidObject("usage: git revert <commit>...")
  }
  // Check if revert already in progress
  if rfs.is_file(revert_head_path) {
    eprint_line(
      "error: revert already in progress, use --continue, --abort, or --skip",
    )
    @sys.exit(1)
  }
  // Save ORIG_HEAD
  let current_head = @gitlib.resolve_head_commit(rfs, git_dir)
  match current_head {
    Some(hid) => wfs.write_string(orig_head_path, hid.to_hex() + "\n")
    None => ()
  }
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  for commit_ref in commits {
    // Resolve commit
    let commit_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
    guard commit_id is Some(cid) else {
      raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
    }
    // Load commit
    let obj = db.get(rfs, cid)
    guard obj is Some(o) else {
      raise @git.GitError::InvalidObject("commit not found: \{cid.to_hex()}")
    }
    let commit_info = @git.parse_commit(o.data)
    // Get parent (for merge commits, use mainline)
    let parent_id = if commit_info.parents.length() == 0 {
      raise @git.GitError::InvalidObject(
        "cannot revert initial commit without --root",
      )
    } else if commit_info.parents.length() > 1 {
      // Merge commit
      match mainline {
        Some(m) =>
          if m < 1 || m > commit_info.parents.length() {
            raise @git.GitError::InvalidObject(
              "mainline must be 1..\{commit_info.parents.length()}",
            )
          } else {
            commit_info.parents[m - 1]
          }
        None =>
          raise @git.GitError::InvalidObject(
            "commit is a merge, -m option required",
          )
      }
    } else {
      commit_info.parents[0]
    }
    // Get trees for commit and parent
    let commit_files = @gitlib.collect_tree_files_from_commit(db, rfs, cid)
    let parent_files = @gitlib.collect_tree_files_from_commit(
      db, rfs, parent_id,
    )
    // Apply reverse changes
    let mut has_conflicts = false
    // Files that were added in commit -> delete them
    for item in commit_files.to_array() {
      let (path, _) = item
      if not(parent_files.contains(path)) {
        // File was added in commit, remove it
        let abs_path = root + "/" + path
        if rfs.is_file(abs_path) {
          wfs.remove_file(abs_path)
        }
        // Remove from index
        remove_from_index(wfs, rfs, git_dir, path)
      }
    }
    // Files that were deleted in commit -> restore them
    for item in parent_files.to_array() {
      let (path, entry) = item
      if not(commit_files.contains(path)) {
        // File was deleted in commit, restore it
        let blob_obj = db.get(rfs, entry.id)
        guard blob_obj is Some(bo) else { continue }
        let abs_path = root + "/" + path
        // Ensure parent dir exists
        match abs_path.rev_find("/") {
          Some(idx) => {
            let parent = String::unsafe_substring(abs_path, start=0, end=idx)
            wfs.mkdir_p(parent)
          }
          None => ()
        }
        wfs.write_file(abs_path, bo.data)
        // Add to index
        @gitlib.add_paths(wfs, rfs, root, [path])
      }
    }
    // Files that were modified in commit -> restore parent version
    for item in commit_files.to_array() {
      let (path, commit_entry) = item
      match parent_files.get(path) {
        Some(parent_entry) =>
          if commit_entry.id.to_hex() != parent_entry.id.to_hex() {
            // File was modified, restore parent version
            let abs_path = root + "/" + path
            // Check if current file matches commit version (clean revert)
            let current_content = rfs.read_file(abs_path) catch { _ => b"" }
            let current_id = @git.hash_blob(current_content)
            if current_id.to_hex() != commit_entry.id.to_hex() {
              // Current file differs from commit, potential conflict
              eprint_line("warning: \{path} has local modifications")
              has_conflicts = true
              continue
            }
            // Restore parent version
            let blob_obj = db.get(rfs, parent_entry.id)
            guard blob_obj is Some(bo) else { continue }
            wfs.write_file(abs_path, bo.data)
            @gitlib.add_paths(wfs, rfs, root, [path])
          }
        None => ()
      }
    }
    // Prepare revert message
    let original_msg = extract_commit_message(o.data)
    let first_line = match original_msg.find("\n") {
      Some(idx) => String::unsafe_substring(original_msg, start=0, end=idx)
      None => original_msg
    }
    let revert_msg = "Revert \"\{first_line}\"\n\nThis reverts commit \{cid.to_hex()}.\n"
    if has_conflicts {
      // Save state for --continue
      wfs.write_string(revert_head_path, cid.to_hex() + "\n")
      wfs.write_string(merge_msg_path, revert_msg)
      eprint_line("error: could not revert \{commit_ref}")
      eprint_line(
        "hint: after resolving conflicts, run 'git revert --continue'",
      )
      eprint_line("hint: to skip this commit, run 'git revert --skip'")
      eprint_line("hint: to abort, run 'git revert --abort'")
      @sys.exit(1)
    }
    // Create revert commit unless --no-commit
    if not(no_commit) {
      let author = get_author_string()
      let timestamp = get_commit_timestamp()
      let new_commit_id = @gitlib.commit(
        wfs, rfs, root, revert_msg, author, timestamp,
      )
      let short_id = (try! new_commit_id.to_hex()[:7]).to_string()
      print_line("[\{short_id}] Revert \"\{first_line}\"")
    }
  }
  // Clean up ORIG_HEAD on success
  wfs.remove_file(orig_head_path) catch {
    _ => ()
  }
}

///|
fn extract_commit_message(data : Bytes) -> String {
  let text = decode_bytes(data)
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
  msg_lines.join("\n")
}

///|
fn remove_from_index(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  path : String,
) -> Unit {
  let entries = @gitlib.read_index_entries(rfs, git_dir) catch { _ => return }
  let new_entries : Array[@gitlib.IndexEntry] = []
  for e in entries {
    if e.path != path {
      new_entries.push(e)
    }
  }
  @gitlib.write_index_entries(wfs, git_dir, new_entries) catch {
    _ => ()
  }
}

///|
/// Handle git notes command
async fn handle_notes(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  let notes_ref = "refs/notes/commits"
  let notes_ref_path = git_dir + "/" + notes_ref
  // Parse subcommand
  let subcmd = args.get(0).unwrap_or("list")
  match subcmd {
    "list" => notes_list(rfs, git_dir, notes_ref_path)
    "show" => {
      let commit_ref = args.get(1).unwrap_or("HEAD")
      notes_show(rfs, git_dir, notes_ref_path, commit_ref)
    }
    "add" => {
      let mut message : String? = None
      let mut force = false
      let mut commit_ref = "HEAD"
      let mut i = 1
      while i < args.length() {
        match args[i] {
          "-m" | "--message" =>
            if i + 1 < args.length() {
              message = Some(args[i + 1])
              i += 2
            } else {
              i += 1
            }
          "-f" | "--force" => {
            force = true
            i += 1
          }
          _ if not(args[i].has_prefix("-")) => {
            commit_ref = args[i]
            i += 1
          }
          _ => i += 1
        }
      }
      guard message is Some(msg) else {
        eprint_line("error: notes add requires -m <message>")
        @sys.exit(1)
      }
      notes_add(wfs, rfs, git_dir, notes_ref_path, commit_ref, msg, force)
    }
    "remove" => {
      let commit_ref = args.get(1).unwrap_or("HEAD")
      notes_remove(wfs, rfs, git_dir, notes_ref_path, commit_ref)
    }
    "prune" => notes_prune(wfs, rfs, git_dir, notes_ref_path)
    _ => {
      eprint_line("usage: git notes [list | show | add | remove | prune]")
      @sys.exit(1)
    }
  }
}

///|
async fn notes_list(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
) -> Unit raise Error {
  if not(rfs.is_file(notes_ref_path)) {
    return
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return }
  let commit_info = @git.parse_commit(o.data)
  // Read tree
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else { return }
  let entries = @git.parse_tree(to.data)
  for entry in entries {
    print_line("\{entry.id.to_hex()} \{entry.name}")
  }
}

///|
async fn notes_show(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
  commit_ref : String,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Check if notes ref exists
  if not(rfs.is_file(notes_ref_path)) {
    eprint_line("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    eprint_line("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @git.parse_commit(o.data)
  // Read tree
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else {
    eprint_line("error: notes tree corrupt")
    @sys.exit(1)
  }
  let entries = @git.parse_tree(to.data)
  // Find entry matching target commit
  for entry in entries {
    if entry.name == target_hex {
      let note_obj = db.get(rfs, entry.id)
      guard note_obj is Some(no) else {
        eprint_line("error: note blob corrupt")
        @sys.exit(1)
      }
      print_line(decode_bytes(no.data))
      return
    }
  }
  eprint_line("error: no note found for \{target_hex}")
  @sys.exit(1)
}

///|
async fn notes_add(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
  commit_ref : String,
  message : String,
  force : Bool,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Create blob for note content
  let note_content = Bytes::from_array(
    message.to_array().map(fn(c) { c.to_int().to_byte() }),
  )
  let note_id = @gitlib.write_loose_object(
    wfs,
    git_dir,
    @git.ObjectType::Blob,
    note_content,
  )
  // Get existing tree entries if notes ref exists
  let entries : Array[@git.TreeEntry] = []
  let mut parent_commit : @git.ObjectId? = None
  if rfs.is_file(notes_ref_path) {
    let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
    let commit_hex = trim_string(ref_content)
    let commit_id = @git.ObjectId::from_hex(commit_hex)
    parent_commit = Some(commit_id)
    let db = @gitlib.ObjectDb::load(rfs, git_dir)
    let obj = db.get(rfs, commit_id)
    match obj {
      Some(o) => {
        let commit_info = @git.parse_commit(o.data)
        let tree_obj = db.get(rfs, commit_info.tree)
        match tree_obj {
          Some(to) => {
            let existing = @git.parse_tree(to.data)
            for e in existing {
              if e.name == target_hex {
                if not(force) {
                  eprint_line("error: note already exists for \{target_hex}")
                  eprint_line("Use -f to overwrite existing note")
                  @sys.exit(1)
                }
                // Skip existing note (will be replaced)
              } else {
                entries.push(e)
              }
            }
          }
          None => ()
        }
      }
      None => ()
    }
  }
  // Add new note entry
  entries.push(@git.TreeEntry::new("100644", target_hex, note_id))
  // Sort entries by name (git requires sorted trees)
  entries.sort_by(fn(a, b) { a.name.compare(b.name) })
  // Create tree
  let (tree_id, tree_data) = @git.create_tree(entries)
  @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
  // Create commit
  let author = get_author_string()
  let timestamp = @sys.get_env_var("GIT_COMMITTER_DATE")
    .map(fn(d) { parse_commit_date(d) })
    .unwrap_or(get_current_timestamp())
  let parents = match parent_commit {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000", "Notes added by 'git notes add'\n",
  )
  let (commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, commit_id, commit_data)
  // Ensure refs/notes directory exists
  wfs.mkdir_p(git_dir + "/refs/notes")
  // Update notes ref
  wfs.write_string(notes_ref_path, commit_id.to_hex() + "\n")
}

///|
async fn notes_remove(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
  commit_ref : String,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Check if notes ref exists
  if not(rfs.is_file(notes_ref_path)) {
    eprint_line("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    eprint_line("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @git.parse_commit(o.data)
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else {
    eprint_line("error: notes tree corrupt")
    @sys.exit(1)
  }
  let existing = @git.parse_tree(to.data)
  // Filter out target entry
  let mut found = false
  let entries : Array[@git.TreeEntry] = []
  for e in existing {
    if e.name == target_hex {
      found = true
    } else {
      entries.push(e)
    }
  }
  if not(found) {
    eprint_line("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  // Create new tree
  let (tree_id, tree_data) = @git.create_tree(entries)
  @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
  // Create commit
  let author = get_author_string()
  let timestamp = get_current_timestamp()
  let commit = @git.Commit::new(
    tree_id,
    [commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "Notes removed by 'git notes remove'\n",
  )
  let (new_commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  // Update notes ref
  wfs.write_string(notes_ref_path, new_commit_id.to_hex() + "\n")
  print_line("Removing note for \{target_hex}")
}

///|
async fn notes_prune(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
) -> Unit raise Error {
  // Check if notes ref exists
  if not(rfs.is_file(notes_ref_path)) {
    return
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return }
  let commit_info = @git.parse_commit(o.data)
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else { return }
  let existing = @git.parse_tree(to.data)
  // Filter entries where the referenced commit still exists
  let entries : Array[@git.TreeEntry] = []
  let mut pruned = 0
  for e in existing {
    let ref_id = @git.ObjectId::from_hex(e.name)
    let ref_obj = db.get(rfs, ref_id) catch { _ => None }
    match ref_obj {
      Some(_) => entries.push(e)
      None => pruned += 1
    }
  }
  if pruned == 0 {
    return
  }
  // Create new tree
  let (tree_id, tree_data) = @git.create_tree(entries)
  @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
  // Create commit
  let author = get_author_string()
  let timestamp = get_current_timestamp()
  let commit = @git.Commit::new(
    tree_id,
    [commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "Notes pruned by 'git notes prune'\n",
  )
  let (new_commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  // Update notes ref
  wfs.write_string(notes_ref_path, new_commit_id.to_hex() + "\n")
  print_line("Pruned \{pruned} notes")
}

///|
/// Handle git bisect command
async fn handle_bisect(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  let subcmd = args.get(0).unwrap_or("help")
  match subcmd {
    "start" => bisect_start(wfs, rfs, root, git_dir, args)
    "bad" | "new" => bisect_mark(wfs, rfs, git_dir, args, "bad")
    "good" | "old" => bisect_mark(wfs, rfs, git_dir, args, "good")
    "skip" => bisect_skip(wfs, rfs, git_dir, args)
    "reset" => bisect_reset(wfs, rfs, root, git_dir, args)
    "log" => bisect_log(rfs, git_dir)
    "visualize" | "view" => {
      eprint_line("bisect visualize not implemented")
      @sys.exit(1)
    }
    "replay" => {
      eprint_line("bisect replay not implemented")
      @sys.exit(1)
    }
    "run" => {
      eprint_line("bisect run not implemented")
      @sys.exit(1)
    }
    "help" | _ => {
      print_line("usage: git bisect [start|bad|good|skip|reset|log]")
      print_line("")
      print_line("  start [bad [good...]] - Start bisect session")
      print_line("  bad [commit]          - Mark commit as bad")
      print_line("  good [commit]         - Mark commit as good")
      print_line("  skip [commit]         - Skip commit")
      print_line("  reset [commit]        - End bisect and checkout commit")
      print_line("  log                   - Show bisect log")
    }
  }
}

///|
async fn bisect_start(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  _root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_terms_path = git_dir + "/BISECT_TERMS"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check if already in bisect
  if rfs.is_file(bisect_start_path) {
    eprint_line("error: bisect already in progress")
    eprint_line("use 'git bisect reset' to abort")
    @sys.exit(1)
  }
  // Get current branch
  let head_content = decode_bytes(rfs.read_file(git_dir + "/HEAD"))
  let current_branch = if head_content.has_prefix("ref: refs/heads/") {
    trim_string(
      String::unsafe_substring(
        head_content,
        start=16,
        end=head_content.length(),
      ),
    )
  } else {
    "HEAD"
  }
  // Create bisect directory
  wfs.mkdir_p(bisect_refs_dir)
  // Save start state
  wfs.write_string(bisect_start_path, current_branch + "\n")
  wfs.write_string(bisect_terms_path, "bad\ngood\n")
  wfs.write_string(bisect_log_path, "git bisect start\n")
  print_line("status: waiting for both good and bad commits")
  // Handle optional bad/good arguments
  // git bisect start [bad [good...]] [--] [paths...]
  let mut i = 1
  let mut bad_set = false
  while i < args.length() {
    let arg = args[i]
    if arg == "--" {
      break
    }
    if not(arg.has_prefix("-")) {
      if not(bad_set) {
        // First positional arg is bad commit
        bisect_mark(wfs, rfs, git_dir, ["bad", arg], "bad")
        bad_set = true
      } else {
        // Subsequent args are good commits
        bisect_mark(wfs, rfs, git_dir, ["good", arg], "good")
      }
    }
    i += 1
  }
}

///|
async fn bisect_mark(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  args : Array[String],
  mark_type : String,
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check if bisect is in progress
  if not(rfs.is_file(bisect_start_path)) {
    eprint_line("error: not in a bisect session")
    eprint_line("use 'git bisect start' first")
    @sys.exit(1)
  }
  // Get commit to mark (default HEAD)
  let commit_ref = args.get(1).unwrap_or("HEAD")
  let commit_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let commit_hex = cid.to_hex()
  // Get commit message for log
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, cid)
  let commit_msg = match obj {
    Some(o) => {
      let msg = extract_commit_message(o.data)
      let first_line = match msg.find("\n") {
        Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
        None => msg
      }
      first_line
    }
    None => ""
  }
  // Write ref
  if mark_type == "bad" {
    wfs.write_string(bisect_refs_dir + "/bad", commit_hex + "\n")
  } else {
    wfs.write_string(bisect_refs_dir + "/good-" + commit_hex, commit_hex + "\n")
  }
  // Append to log
  let log_entry = "# \{mark_type}: [\{commit_hex}] \{commit_msg}\ngit bisect \{mark_type} \{commit_hex}\n"
  let existing_log = decode_bytes(rfs.read_file(bisect_log_path)) catch {
    _ => ""
  }
  wfs.write_string(bisect_log_path, existing_log + log_entry)
  // Check if we can compute next bisect point
  bisect_next(wfs, rfs, git_dir)
}

///|
async fn bisect_skip(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check if bisect is in progress
  if not(rfs.is_file(bisect_start_path)) {
    eprint_line("error: not in a bisect session")
    @sys.exit(1)
  }
  // Get commit to skip (default HEAD)
  let commit_ref = args.get(1).unwrap_or("HEAD")
  let commit_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let commit_hex = cid.to_hex()
  // Write skip ref
  wfs.write_string(bisect_refs_dir + "/skip-" + commit_hex, commit_hex + "\n")
  // Append to log
  let log_entry = "git bisect skip \{commit_hex}\n"
  let existing_log = decode_bytes(rfs.read_file(bisect_log_path)) catch {
    _ => ""
  }
  wfs.write_string(bisect_log_path, existing_log + log_entry)
  // Compute next
  bisect_next(wfs, rfs, git_dir)
}

///|
async fn bisect_next(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let bisect_refs_dir = git_dir + "/refs/bisect"
  let bisect_expected_path = git_dir + "/BISECT_EXPECTED_REV"
  // Read bad commit
  let bad_path = bisect_refs_dir + "/bad"
  if not(rfs.is_file(bad_path)) {
    print_line("status: waiting for bad commit")
    return
  }
  let bad_hex = trim_string(decode_bytes(rfs.read_file(bad_path)))
  let bad_id = @git.ObjectId::from_hex(bad_hex)
  // Read good commits
  let good_commits : Array[@git.ObjectId] = []
  let bisect_entries = (rfs : &@git.RepoFileSystem).readdir(bisect_refs_dir) catch {
    _ => []
  }
  for entry in bisect_entries {
    if entry.has_prefix("good-") {
      let good_hex = trim_string(
        decode_bytes(rfs.read_file(bisect_refs_dir + "/" + entry)),
      )
      good_commits.push(@git.ObjectId::from_hex(good_hex))
    }
  }
  if good_commits.length() == 0 {
    print_line("status: waiting for good commit(s), bad commit known")
    return
  }
  // Read skip commits
  let skip_commits : Array[@git.ObjectId] = []
  for entry in bisect_entries {
    if entry.has_prefix("skip-") {
      let skip_hex = trim_string(
        decode_bytes(rfs.read_file(bisect_refs_dir + "/" + entry)),
      )
      skip_commits.push(@git.ObjectId::from_hex(skip_hex))
    }
  }
  // Get all commits between good and bad using rev-list logic
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let candidates = bisect_get_candidates(
    db, rfs, bad_id, good_commits, skip_commits,
  )
  if candidates.length() == 0 {
    // Found the first bad commit
    print_line("\{bad_hex} is the first bad commit")
    return
  }
  // Pick middle commit
  let mid_idx = candidates.length() / 2
  let mid_id = candidates[mid_idx]
  let mid_hex = mid_id.to_hex()
  // Get commit info for output
  let obj = db.get(rfs, mid_id)
  let commit_msg = match obj {
    Some(o) => {
      let msg = extract_commit_message(o.data)
      match msg.find("\n") {
        Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
        None => msg
      }
    }
    None => ""
  }
  // Calculate steps remaining
  let remaining = candidates.length()
  let steps = bisect_steps(remaining)
  // Write expected rev
  wfs.write_string(bisect_expected_path, mid_hex + "\n")
  // Checkout the commit (detached HEAD)
  let root = git_dir + "/.."
  ignore(@gitlib.checkout(wfs, rfs, root, mid_hex, detach=true))
  print_line(
    "Bisecting: \{remaining} revisions left to test after this (roughly \{steps} steps)",
  )
  print_line("[\{mid_hex}] \{commit_msg}")
}

///|
fn bisect_steps(n : Int) -> Int {
  // log2(n) rounded
  if n <= 1 {
    return 0
  }
  let mut steps = 0
  let mut val = n
  while val > 1 {
    val = val / 2
    steps += 1
  }
  steps
}

///|
fn bisect_get_candidates(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  bad : @git.ObjectId,
  goods : Array[@git.ObjectId],
  skips : Array[@git.ObjectId],
) -> Array[@git.ObjectId] raise Error {
  // Get all ancestors of bad that are not ancestors of any good
  let good_set : Map[String, Bool] = {}
  // Mark all good commits and their ancestors
  for g in goods {
    mark_ancestors(db, rfs, g, good_set)
  }
  // Collect candidates: ancestors of bad that are not in good_set
  let candidates : Array[@git.ObjectId] = []
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [bad]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited.set(hex, true)
    // Skip if in good set (boundary)
    if good_set.get(hex).unwrap_or(false) {
      continue
    }
    // Skip if in skip list
    let mut is_skipped = false
    for s in skips {
      if s.to_hex() == hex {
        is_skipped = true
        break
      }
    }
    if not(is_skipped) && cid != bad {
      candidates.push(cid)
    }
    // Add parents to queue
    let obj = db.get(rfs, cid)
    match obj {
      Some(o) => {
        let info = @git.parse_commit(o.data)
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
  candidates
}

///|
fn mark_ancestors(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  start : @git.ObjectId,
  set : Map[String, Bool],
) -> Unit {
  let queue : Array[@git.ObjectId] = [start]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if set.get(hex).unwrap_or(false) {
      continue
    }
    set.set(hex, true)
    let obj = db.get(rfs, cid) catch { _ => None }
    match obj {
      Some(o) => {
        let info = @git.parse_commit(o.data) catch { _ => continue }
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
}

///|
async fn bisect_reset(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_terms_path = git_dir + "/BISECT_TERMS"
  let bisect_expected_path = git_dir + "/BISECT_EXPECTED_REV"
  let bisect_ancestors_path = git_dir + "/BISECT_ANCESTORS_OK"
  let bisect_names_path = git_dir + "/BISECT_NAMES"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check what to checkout
  let checkout_ref = if args.length() > 1 {
    args[1]
  } else if rfs.is_file(bisect_start_path) {
    trim_string(decode_bytes(rfs.read_file(bisect_start_path)))
  } else {
    "HEAD"
  }
  // Checkout the ref
  if checkout_ref != "HEAD" && checkout_ref.length() > 0 {
    // Try to checkout branch
    if rfs.is_file(git_dir + "/refs/heads/" + checkout_ref) {
      // Checkout the branch (not detached)
      ignore(@gitlib.checkout(wfs, rfs, root, checkout_ref, detach=false))
    } else {
      // Try to checkout as a commit (detached)
      let target = @gitlib.rev_parse(rfs, git_dir, checkout_ref)
      match target {
        Some(_) =>
          ignore(@gitlib.checkout(wfs, rfs, root, checkout_ref, detach=true))
        None => ()
      }
    }
  }
  // Clean up bisect state files
  wfs.remove_file(bisect_start_path) catch {
    _ => ()
  }
  wfs.remove_file(bisect_log_path) catch {
    _ => ()
  }
  wfs.remove_file(bisect_terms_path) catch {
    _ => ()
  }
  wfs.remove_file(bisect_expected_path) catch {
    _ => ()
  }
  wfs.remove_file(bisect_ancestors_path) catch {
    _ => ()
  }
  wfs.remove_file(bisect_names_path) catch {
    _ => ()
  }
  // Clean up refs/bisect
  let entries = (rfs : &@git.RepoFileSystem).readdir(bisect_refs_dir) catch {
    _ => []
  }
  for entry in entries {
    wfs.remove_file(bisect_refs_dir + "/" + entry) catch {
      _ => ()
    }
  }
  wfs.remove_file(bisect_refs_dir) catch {
    _ => ()
  }
  print_line("Bisect reset")
}

///|
async fn bisect_log(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let bisect_log_path = git_dir + "/BISECT_LOG"
  if not(rfs.is_file(bisect_log_path)) {
    eprint_line("error: no bisect log found")
    @sys.exit(1)
  }
  let content = decode_bytes(rfs.read_file(bisect_log_path))
  print_line(content)
}
