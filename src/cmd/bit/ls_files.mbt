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
  let raw_filters : Array[String] = []
  let mut parse_options = true
  for arg in args {
    if parse_options && arg == "--" {
      parse_options = false
      continue
    }
    if parse_options {
      match arg {
        "-s" | "--stage" => show_stage = true
        "-c" | "--cached" => () // default mode, no-op
        "-o" | "--others" => show_others = true
        "-d" | "--deleted" => show_deleted = true
        "--directory" => show_directory = true
        "--recurse-submodules" => recurse_submodules = true
        "-z" => use_nul = true
        _ if arg.has_prefix("-") => warn_unimplemented_arg("ls-files", arg)
        _ => raw_filters.push(arg)
      }
    } else {
      raw_filters.push(arg)
    }
  }
  let terminator = if use_nul { "\u0000" } else { "\n" }
  let cwd_prefix = compute_cwd_prefix(root)
  let filters = normalize_ls_tree_filters(raw_filters, cwd_prefix)
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
        let out_path = dir + "/"
        if ls_files_matches_filters(out_path, filters) {
          print_str(out_path + terminator)
        }
      }
    } else {
      // Show untracked files
      let all_files = @ignore.list_working_files_async(fs, root)
      for path in all_files {
        if not(tracked.contains(path)) &&
          ls_files_matches_filters(path, filters) {
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
      if not(fs.is_file(abs)) && ls_files_matches_filters(e.path, filters) {
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
      if not(ls_files_matches_filters(e.path, filters)) {
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
        let actual_git_dir = @gitlib.resolve_gitdir(fs, sub_git_dir)
        let sub_entries = @gitlib.read_index_entries(fs, actual_git_dir)
        for se in sub_entries {
          let mode = format_mode(se.mode)
          let full_path = submod.path + "/" + se.path
          if not(ls_files_matches_filters(full_path, filters)) {
            continue
          }
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
      if not(ls_files_matches_filters(e.path, filters)) {
        continue
      }
      print_str(e.path + terminator)
    }
    // Recurse into submodules
    for submod in submodules {
      let sub_git_dir = root + "/" + submod.path + "/.git"
      if fs.is_dir(sub_git_dir) || fs.is_file(sub_git_dir) {
        let actual_git_dir = @gitlib.resolve_gitdir(fs, sub_git_dir)
        let sub_entries = @gitlib.read_index_entries(fs, actual_git_dir)
        for se in sub_entries {
          let full_path = submod.path + "/" + se.path
          if not(ls_files_matches_filters(full_path, filters)) {
            continue
          }
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
fn parse_pathspec_magic(filter : String) -> (String, Bool) {
  if filter.has_prefix(":!") {
    let rest = String::unsafe_substring(filter, start=2, end=filter.length())
    return (rest, true)
  }
  if filter.has_prefix(":(") {
    match filter.find(")") {
      Some(idx) => {
        let magic = String::unsafe_substring(filter, start=2, end=idx)
        let rest = String::unsafe_substring(
          filter,
          start=idx + 1,
          end=filter.length(),
        )
        let is_exclude = magic.contains("exclude") || magic.contains("!")
        (rest, is_exclude)
      }
      None => (filter, false)
    }
  } else {
    (filter, false)
  }
}

///|
fn normalize_ls_tree_filters(
  filters : Array[String],
  cwd_prefix : String,
) -> Array[String] raise Error {
  let out : Array[String] = []
  for filter in filters {
    let (raw, is_exclude) = parse_pathspec_magic(filter)
    if is_exclude {
      raise @git.GitError::InvalidObject(
        "pathspec magic not supported by this command: 'exclude' (mnemonic: '!')",
      )
    }
    let mut clean = raw
    if clean.has_suffix("/") && clean.length() > 1 {
      clean = String::unsafe_substring(clean, start=0, end=clean.length() - 1)
    }
    let base = if clean == "" || clean == "." {
      cwd_prefix
    } else if clean.has_prefix("/") {
      String::unsafe_substring(clean, start=1, end=clean.length())
    } else if cwd_prefix.length() == 0 {
      clean
    } else {
      cwd_prefix + "/" + clean
    }
    let normalized = normalize_path(base)
    if normalized != "." && normalized.length() > 0 {
      out.push(normalized)
    }
  }
  out
}

///|
fn compute_cwd_prefix(root : String) -> String {
  match @sys.get_env_var("GIT_SHIM_PWD") {
    None => ""
    Some(cwd) => {
      let cwd_abs = normalize_path(cwd)
      let root_abs = if root.has_prefix("/") {
        normalize_path(root)
      } else {
        normalize_path(cwd_abs + "/" + root)
      }
      if cwd_abs == root_abs {
        ""
      } else {
        let root_prefix = if root_abs == "/" { "/" } else { root_abs + "/" }
        if cwd_abs.has_prefix(root_prefix) {
          String::unsafe_substring(
            cwd_abs,
            start=root_prefix.length(),
            end=cwd_abs.length(),
          )
        } else {
          ""
        }
      }
    }
  }
}

///|
fn count_path_segments(path : String) -> Int {
  let mut count = 0
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part.length() > 0 {
      count += 1
    }
  }
  count
}

///|
fn make_display_path(path : String, cwd_prefix : String) -> String {
  if cwd_prefix.length() == 0 {
    return path
  }
  if path == cwd_prefix {
    return "."
  }
  let prefix = cwd_prefix + "/"
  if path.has_prefix(prefix) {
    return (try! path[prefix.length():]).to_string()
  }
  let depth = count_path_segments(cwd_prefix)
  let mut rel = ""
  for _ in 0..<depth {
    rel = rel + "../"
  }
  rel + path
}

///|
fn ls_files_matches_filters(path : String, filters : Array[String]) -> Bool {
  if filters.length() == 0 {
    return true
  }
  let normalized = if path.has_suffix("/") && path.length() > 1 {
    String::unsafe_substring(path, start=0, end=path.length() - 1)
  } else {
    path
  }
  for filter in filters {
    if normalized == filter {
      return true
    }
    if normalized.has_prefix(filter + "/") {
      return true
    }
  }
  false
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
  digits.iter().fold(init="", (acc, d) => acc + d)
}

///|
