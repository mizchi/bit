///|

///|
async fn show_add_command_help() -> Unit {
  show_simple_command_help(
    "git add [<options>] [--] <pathspec>...",
    summary="Add file contents to the index.",
  )
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
  let mut force = false
  let mut refresh = false
  let mut dry_run = false
  let mut ignore_missing = false
  let mut interactive = false
  let mut end_of_options = false
  let paths : Array[String] = []
  for raw_arg in args {
    let arg = raw_arg
    if not(end_of_options) && arg == "--" {
      end_of_options = true
      continue
    }
    match arg {
      "-A" | "--all" if not(end_of_options) => add_all = true
      "-f" | "--force" if not(end_of_options) => force = true
      "--refresh" if not(end_of_options) => refresh = true
      "-n" | "--dry-run" if not(end_of_options) => dry_run = true
      "--ignore-missing" if not(end_of_options) => ignore_missing = true
      "--interactive" if not(end_of_options) => interactive = true
      _ if end_of_options || not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("add", arg)
      _ => ()
    }
  }
  if dry_run {
    handle_add_dry_run(fs, root, paths, force~, ignore_missing~, interactive~)
    return
  }
  if paths.iter().any(p => p.length() == 0) {
    @sys.exit(1)
  }
  if refresh {
    add_refresh_index_entries(fs, root, paths)
    return
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
      stage_submodule_gitlinks(fs, root, all_paths)
    }
    return
  }
  if paths.length() == 0 {
    eprint_line("Nothing specified, nothing added.")
    if add_should_show_empty_pathspec_hint(fs, root) {
      eprint_line("hint: Maybe you wanted to say 'git add .'?")
      eprint_line(
        "hint: Disable this message with \"git config set advice.addEmptyPathspec false\"",
      )
    }
    return
  }
  let stage_paths = expand_add_stage_paths(fs, root, paths, force)
  if stage_paths.length() > 0 {
    @gitlib.add_paths_async(fs, fs, root, stage_paths)
    stage_submodule_gitlinks(fs, root, stage_paths)
  }
  if not(force) && add_has_explicit_ignored_path(fs, root, paths) {
    eprint_line(
      "The following paths are ignored by one of your .gitignore files.",
    )
    eprint_line("hint: Use -f if you really want to add them.")
    @sys.exit(1)
  }
  if stage_paths.length() == 0 {
    let rfs : &@git.RepoFileSystem = fs
    if real_git_delegate_is_available(rfs) {
      delegate_to_real_git("add", args)
      return
    }
    let first = add_first_non_empty_pathspec(paths)
    if first is Some(spec) {
      eprint_line("fatal: pathspec '\{spec}' did not match any files")
      @sys.exit(1)
    }
  }
}

///|
async fn handle_add_dry_run(
  fs : OsFs,
  root : String,
  paths : Array[String],
  force? : Bool = false,
  ignore_missing? : Bool = false,
  interactive? : Bool = false,
) -> Unit raise Error {
  if interactive {
    @sys.exit(1)
  }
  if paths.iter().any(p => p.length() == 0) {
    @sys.exit(1)
  }
  let stage_paths = expand_add_stage_paths(fs, root, paths, force)
  let unmatched = add_collect_unmatched_pathspecs(fs, root, paths, force)
  if unmatched.length() > 0 && not(ignore_missing) {
    eprint_line("fatal: pathspec '\{unmatched[0]}' did not match any files")
    @sys.exit(1)
  }
  let printed : Map[String, Bool] = {}
  for path in stage_paths {
    if printed.contains(path) {
      continue
    }
    printed[path] = true
    print_line("add '\{path}'")
  }
  if unmatched.length() == 0 {
    return
  }
  if ignore_missing {
    let ignored : Array[String] = []
    for spec in unmatched {
      if @ignore.is_ignored_path(fs, root, spec, false) {
        ignored.push(spec)
      }
    }
    if ignored.length() > 0 {
      eprint_line(
        "The following paths are ignored by one of your .gitignore files:",
      )
      for path in ignored {
        eprint_line(path)
      }
      eprint_line("hint: Use -f if you really want to add them.")
      eprint_line(
        "hint: Disable this message with \"git config set advice.addIgnoredFile false\"",
      )
    }
    @sys.exit(1)
  }
  @sys.exit(1)
}

///|
async fn add_collect_unmatched_pathspecs(
  fs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
  force : Bool,
) -> Array[String] raise Error {
  let out : Array[String] = []
  let git_dir = resolve_git_dir(fs, root)
  let tracked_entries = @gitlib.read_index_entries(fs, git_dir)
  let tracked : Map[String, Bool] = {}
  let tracked_folded : Map[String, String] = {}
  for entry in tracked_entries {
    let normalized = normalize_add_path(entry.path)
    tracked[normalized] = true
    let folded = normalized.to_lower()
    if not(tracked_folded.contains(folded)) {
      tracked_folded[folded] = normalized
    }
  }
  let visible_paths = if force {
    []
  } else {
    @ignore.list_working_files_async(fs, root)
  }
  let visible_map : Map[String, Bool] = {}
  let visible_folded : Map[String, String] = {}
  for p in visible_paths {
    visible_map[p] = true
    let folded = p.to_lower()
    if not(visible_folded.contains(folded)) {
      visible_folded[folded] = p
    }
  }
  for raw_path in paths {
    let path = add_normalize_input_path(root, raw_path)
    if path.length() == 0 || path == "." {
      continue
    }
    let abs = root + "/" + path
    let matched = if visible_map.get(path) is Some(_) {
      true
    } else if visible_folded.get(path.to_lower()) is Some(_) {
      true
    } else if tracked.contains(path) {
      true
    } else if tracked_folded.get(path.to_lower()) is Some(_) {
      true
    } else if fs.is_dir(abs) {
      let prefix = path + "/"
      visible_paths.iter().any(p => p.has_prefix(prefix))
    } else {
      false
    }
    if not(matched) {
      out.push(path)
    }
  }
  out
}

///|
fn add_first_non_empty_pathspec(paths : Array[String]) -> String? {
  for raw in paths {
    let normalized = normalize_add_path(raw)
    if normalized.length() > 0 && normalized != "." {
      return Some(normalized)
    }
  }
  None
}

///|
async fn add_refresh_index_entries(
  fs : OsFs,
  root : String,
  raw_specs : Array[String],
) -> Unit raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let entries = @gitlib.read_index_entries(fs, git_dir)
  if entries.length() == 0 {
    return
  }
  let tracked_paths : Array[String] = []
  for entry in entries {
    tracked_paths.push(entry.path)
  }
  let selected : Map[String, Bool] = {}
  if raw_specs.length() == 0 {
    for path in tracked_paths {
      selected[path] = true
    }
  } else {
    for raw in raw_specs {
      let (pattern, icase) = add_parse_refresh_pathspec(raw)
      if pattern.length() == 0 {
        continue
      }
      let mut matched = false
      for path in tracked_paths {
        if add_refresh_pathspec_matches(pattern, icase, path) {
          matched = true
          selected[path] = true
        }
      }
      if not(matched) {
        eprint_line("fatal: pathspec '\{raw}' did not match any files")
        @sys.exit(1)
      }
    }
  }
  let refreshed : Array[@gitlib.IndexEntry] = []
  for entry in entries {
    if not(selected.contains(entry.path)) {
      refreshed.push(entry)
      continue
    }
    let abs = root + "/" + entry.path
    if not(fs.is_file(abs)) {
      refreshed.push(entry)
      continue
    }
    let mut size = entry.size
    let size_result : Result[Bytes, Error] = try? fs.read_file(abs)
    match size_result {
      Ok(content) => size = content.length()
      Err(_) => ()
    }
    let mut mtime_sec = entry.mtime_sec
    let mut mtime_nsec = entry.mtime_nsec
    let mtime_result : Result[(Int64, Int), Error] = try? @asyncfs.mtime(
      abs,
      follow_symlink=false,
    )
    match mtime_result {
      Ok((sec, nsec)) => {
        mtime_sec = sec.to_int()
        mtime_nsec = nsec
      }
      Err(_) => ()
    }
    refreshed.push(
      @gitlib.IndexEntry::new(
        entry.path,
        entry.id,
        entry.mode,
        size,
        mtime_sec~,
        mtime_nsec~,
      ),
    )
  }
  @gitlib.write_index_entries(fs, git_dir, refreshed)
}

///|
fn add_parse_refresh_pathspec(raw : String) -> (String, Bool) {
  let normalized = normalize_add_path(raw)
  if normalized.has_prefix(":(") {
    match normalized.find(")") {
      Some(idx) => {
        let magic = String::unsafe_substring(normalized, start=2, end=idx)
        let rest = String::unsafe_substring(
          normalized,
          start=idx + 1,
          end=normalized.length(),
        )
        let mut icase = false
        for token_view in magic.split(",") {
          let token = trim_string(token_view.to_string())
          if token == "icase" {
            icase = true
          }
        }
        (normalize_add_path(rest), icase)
      }
      None => (normalized, false)
    }
  } else {
    (normalized, false)
  }
}

///|
fn add_refresh_pathspec_matches(
  spec : String,
  icase : Bool,
  path : String,
) -> Bool {
  if spec == "." {
    return true
  }
  if icase {
    let folded_spec = spec.to_lower()
    let folded_path = path.to_lower()
    return folded_path == folded_spec ||
      folded_path.has_prefix(folded_spec + "/")
  }
  path == spec || path.has_prefix(spec + "/")
}

///|
fn normalize_add_path(path : String) -> String {
  let mut out = path
  while out.has_prefix("./") {
    out = String::unsafe_substring(out, start=2, end=out.length())
  }
  while out.length() > 1 && out.has_suffix("/") {
    out = String::unsafe_substring(out, start=0, end=out.length() - 1)
  }
  let sb = StringBuilder::new()
  let mut i = 0
  while i < out.length() {
    let c = out[i].unsafe_to_char()
    if c == '\\' && i + 1 < out.length() {
      let next = out[i + 1].unsafe_to_char()
      if next == '[' || next == ']' || next == '\\' {
        sb.write_char(next)
        i += 2
        continue
      }
    }
    sb.write_char(c)
    i += 1
  }
  sb.to_string()
}

///|
fn add_normalize_input_path(root : String, raw_path : String) -> String {
  let normalized = normalize_add_path(raw_path)
  if normalized.length() == 0 {
    return normalized
  }
  let root_prefix = if root.has_suffix("/") { root } else { root + "/" }
  if normalized.has_prefix(root_prefix) {
    return String::unsafe_substring(
      normalized,
      start=root_prefix.length(),
      end=normalized.length(),
    )
  }
  let normalized_folded = normalized.to_lower()
  let root_folded = root_prefix.to_lower()
  if normalized_folded.has_prefix(root_folded) {
    return String::unsafe_substring(
      normalized,
      start=root_prefix.length(),
      end=normalized.length(),
    )
  }
  normalized
}

///|
fn add_should_show_empty_pathspec_hint(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Bool {
  let git_dir = resolve_git_dir(fs, root)
  match get_config_override("advice.addEmptyPathspec") {
    Some(value) => add_parse_bool(value).unwrap_or(true)
    None =>
      @gitlib.read_config_bool(
        fs,
        git_dir + "/config",
        "advice",
        "addemptypathspec",
      ).unwrap_or(true)
  }
}

///|
fn add_parse_bool(value : String) -> Bool? {
  let lowered = trim_string(value).to_lower()
  if lowered == "true" || lowered == "yes" || lowered == "on" || lowered == "1" {
    Some(true)
  } else if lowered == "false" ||
    lowered == "no" ||
    lowered == "off" ||
    lowered == "0" {
    Some(false)
  } else {
    None
  }
}

///|
async fn expand_add_stage_paths(
  fs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
  force : Bool,
) -> Array[String] raise Error {
  let out : Array[String] = []
  let visible_paths = if force {
    []
  } else {
    @ignore.list_working_files_async(fs, root)
  }
  let git_dir = resolve_git_dir(fs, root)
  let tracked_entries = @gitlib.read_index_entries(fs, git_dir)
  let tracked_map : Map[String, Bool] = {}
  let tracked_folded : Map[String, String] = {}
  for entry in tracked_entries {
    let normalized = normalize_add_path(entry.path)
    tracked_map[normalized] = true
    let folded = normalized.to_lower()
    if not(tracked_folded.contains(folded)) {
      tracked_folded[folded] = normalized
    }
  }
  let visible_map : Map[String, Bool] = {}
  let visible_folded : Map[String, String] = {}
  for p in visible_paths {
    visible_map[p] = true
    let folded = p.to_lower()
    if not(visible_folded.contains(folded)) {
      visible_folded[folded] = p
    }
  }
  for raw_path in paths {
    let path = add_normalize_input_path(root, raw_path)
    if path.length() == 0 {
      continue
    }
    if force {
      expand_force_add_path(fs, root, path, out)
      continue
    }
    if path == "." {
      for p in visible_paths {
        out.push(p)
      }
      continue
    }
    let abs = root + "/" + path
    if fs.is_dir(abs) {
      let prefix = path + "/"
      for p in visible_paths {
        if p.has_prefix(prefix) {
          out.push(p)
        }
      }
      continue
    }
    if visible_map.get(path) is Some(_) {
      out.push(path)
      continue
    }
    match visible_folded.get(path.to_lower()) {
      Some(actual) => {
        out.push(actual)
        continue
      }
      None => ()
    }
    if tracked_map.contains(path) {
      out.push(path)
      continue
    }
    match tracked_folded.get(path.to_lower()) {
      Some(actual) => out.push(actual)
      None => ()
    }
  }
  out
}

///|
fn expand_force_add_path(
  fs : &@git.RepoFileSystem,
  root : String,
  path : String,
  out : Array[String],
) -> Unit raise Error {
  if path == "." {
    collect_all_addable_paths(fs, root, "", out)
    return
  }
  let abs = root + "/" + path
  if fs.is_dir(abs) {
    collect_all_addable_paths(fs, root, path, out)
  } else {
    out.push(path)
  }
}

///|
fn collect_all_addable_paths(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
  out : Array[String],
) -> Unit raise Error {
  let dir = if rel.length() == 0 { root } else { root + "/" + rel }
  if not(fs.is_dir(dir)) {
    return
  }
  for name in fs.readdir(dir) {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel.length() == 0 { name } else { rel + "/" + name }
    let child_abs = root + "/" + child_rel
    if fs.is_dir(child_abs) {
      collect_all_addable_paths(fs, root, child_rel, out)
    } else {
      out.push(child_rel)
    }
  }
}

///|
fn add_has_explicit_ignored_path(
  fs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Bool raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let tracked_entries = @gitlib.read_index_entries(fs, git_dir)
  let tracked : Map[String, Bool] = {}
  for entry in tracked_entries {
    tracked[normalize_add_path(entry.path)] = true
  }
  for raw_path in paths {
    let rel = add_normalize_input_path(root, raw_path)
    if rel.length() == 0 {
      continue
    }
    if rel == "." {
      continue
    }
    if tracked.contains(rel) {
      continue
    }
    let abs = root + "/" + rel
    if fs.is_dir(abs) {
      if add_has_ignored_under(fs, root, rel) {
        return true
      }
    } else if @ignore.is_ignored_path(fs, root, rel, false) {
      return true
    }
  }
  false
}

///|
fn add_has_ignored_under(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
) -> Bool raise Error {
  let dir = if rel.length() == 0 { root } else { root + "/" + rel }
  if not(fs.is_dir(dir)) {
    return false
  }
  for name in fs.readdir(dir) {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel.length() == 0 { name } else { rel + "/" + name }
    let child_abs = root + "/" + child_rel
    let is_dir = fs.is_dir(child_abs)
    if @ignore.is_ignored_path(fs, root, child_rel, is_dir) {
      return true
    }
    if is_dir && add_has_ignored_under(fs, root, child_rel) {
      return true
    }
  }
  false
}

///|
fn stage_submodule_gitlinks(
  fs : OsFs,
  root : String,
  paths : Array[String],
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(fs, root)
  for raw_path in paths {
    let rel_path = normalize_add_path(raw_path)
    if rel_path == "." || rel_path.length() == 0 {
      continue
    }
    let sub_path = root + "/" + rel_path
    let sub_git = sub_path + "/.git"
    let sub_git_dir = if rfs.is_file(sub_git) {
      @gitlib.resolve_gitdir(rfs, sub_git)
    } else if rfs.is_dir(sub_git) {
      sub_git
    } else {
      continue
    }
    match @gitlib.resolve_head_commit(rfs, sub_git_dir) {
      Some(id) => update_submodule_index_entry(fs, git_dir, rel_path, id)
      None => ()
    }
  }
}
