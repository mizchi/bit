///| Miscellaneous handlers: diff, merge, tag, rm, mv, config, sparse-checkout, rev-parse, cat-file, ls-files, hash-object, ls-tree, write-tree, show-ref, update-ref, symbolic-ref

///|
fn find_git_dir(fs : OsFs) -> String {
  // Check GIT_DIR environment variable first
  if @sys.get_env_var("GIT_DIR") is Some(dir) {
    if fs.is_dir(dir) || fs.is_file(dir) {
      return dir
    }
  }
  // Check if current directory is a .git directory (bare repo or inside .git)
  let cwd = get_work_root()
  if fs.is_file(cwd + "/config") &&
    fs.is_file(cwd + "/HEAD") &&
    fs.is_dir(cwd + "/refs") {
    return cwd
  }
  // Standard case: .git subdirectory
  cwd + "/.git"
}

///|
fn get_config_override(key : String) -> String? {
  let overrides = @sys.get_env_var("GIT_CONFIG_OVERRIDES")
  match overrides {
    Some(data) => {
      for line_view in data.split("\n") {
        let line = line_view.to_string()
        match line.find("=") {
          Some(eq_idx) => {
            let k = String::unsafe_substring(line, start=0, end=eq_idx)
            // Case-insensitive comparison for config keys
            if k.to_lower() == key.to_lower() {
              return Some(
                String::unsafe_substring(
                  line,
                  start=eq_idx + 1,
                  end=line.length(),
                ),
              )
            }
          }
          None => ()
        }
      }
      None
    }
    None => None
  }
}

///|
fn is_gitlink_mode_for_diff(mode : Int) -> Bool {
  mode == 0o160000
}

///|
fn looks_like_cached_diff_revision(token : String) -> Bool {
  token == "HEAD" ||
  token == "@" ||
  token.has_prefix("HEAD^") ||
  token.has_prefix("HEAD~")
}

///|
async fn handle_diff(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let repo_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
  let mut submodule_mode = false
  let mut range_spec : String? = None
  let mut cached = false
  let mut stat_mode = false
  let mut name_only = false
  let mut name_status = false
  let mut ref_target : String? = None
  let paths : Array[String] = []
  for arg in args {
    if arg == "--submodule" || arg.has_prefix("--submodule=") {
      submodule_mode = true
    }
    match arg {
      "--cached" | "--staged" => cached = true
      "--stat" => stat_mode = true
      "--name-only" => name_only = true
      "--name-status" => name_status = true
      "--submodule" => ()
      _ if arg.has_prefix("--submodule=") => ()
      _ if not(arg.has_prefix("-")) =>
        if arg.contains("^!") || arg.contains("..") {
          if range_spec is None {
            range_spec = Some(arg)
          }
        } else if cached &&
          ref_target is None &&
          looks_like_cached_diff_revision(arg) {
          ref_target = Some(arg)
        } else if arg.contains("/") && ref_target is None {
          // Check if it's a ref (contains / like origin/main)
          ref_target = Some(arg)
        } else {
          paths.push(arg)
        }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("diff", arg)
      _ => ()
    }
  }
  // Handle subdir-clone diff with upstream ref
  match (ref_target, get_subdir_info(fs, git_dir)) {
    (Some(refspec), Some((_, subdir_path, _))) => {
      handle_subdir_diff(
        fs, root, git_dir, refspec, subdir_path, stat_mode, name_only, name_status,
      ) catch {
        err => raise err
      }
      return
    }
    _ => ()
  }
  let all_files = match range_spec {
    Some(spec) => {
      if submodule_mode {
        let handled = try_handle_submodule_range_diff(
          fs, root, git_dir, repo_git_dir, spec,
        )
        if handled {
          return
        }
      }
      let db = @gitlib.ObjectDb::load(rfs, repo_git_dir)
      match resolve_submodule_diff_range(db, rfs, repo_git_dir, spec) {
        Some((old_id, new_id)) => {
          let old_tree = resolve_diff_tree_id(db, rfs, old_id)
          let new_tree = resolve_diff_tree_id(db, rfs, new_id)
          match (old_tree, new_tree) {
            (Some(ot), Some(nt)) =>
              @gitdiff.diff_trees(rfs, repo_git_dir, Some(ot), nt)
            _ =>
              raise @git.GitError::InvalidObject(
                "unsupported diff range: " + spec,
              )
          }
        }
        None =>
          raise @git.GitError::InvalidObject("unsupported diff range: " + spec)
      }
    }
    None =>
      if cached {
        @gitdiff.diff_index(fs, root)
      } else {
        @gitdiff.diff_worktree(fs, root)
      }
  }
  // Filter by paths if specified
  let files = if paths.length() > 0 {
    all_files
    .iter()
    .filter(fn(f) {
      paths.iter().any(p => f.path == p || f.path.has_prefix(p + "/"))
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
        @gitdiff.DiffKind::Added => "A"
        @gitdiff.DiffKind::Modified => "M"
        @gitdiff.DiffKind::Deleted => "D"
      }
      print_line("\{status}\t\{f.path}")
    }
  } else if stat_mode {
    let lines = @gitdiff.diff_stat(files)
    for line in lines {
      print_line(line)
    }
  } else {
    let lines = @gitdiff.diff_text(files)
    for line in lines {
      print_line(line)
    }
  }
}

///|
fn resolve_diff_tree_id(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> @git.ObjectId? {
  let mut current = id
  for _ in 0..<8 {
    let obj = db.get(rfs, current) catch { _ => return None }
    guard obj is Some(o) else { return None }
    match o.obj_type {
      @git.ObjectType::Tree => return Some(current)
      @git.ObjectType::Commit => {
        let commit = @git.parse_commit(o.data) catch { _ => return None }
        return Some(commit.tree)
      }
      @git.ObjectType::Tag => {
        let parsed = parse_tag_object(decode_bytes(o.data)) catch { _ => None }
        guard parsed is Some(target) else { return None }
        current = target
      }
      _ => return None
    }
  }
  None
}

///|
async fn try_handle_submodule_range_diff(
  fs : OsFs,
  root : String,
  git_dir : String,
  repo_git_dir : String,
  spec : String,
) -> Bool raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let db = @gitlib.ObjectDb::load(rfs, repo_git_dir)
  guard resolve_submodule_diff_range(db, rfs, repo_git_dir, spec)
    is Some((old_commit, new_commit)) else {
    return false
  }
  let old_entries = @gitlib.collect_tree_files_from_commit(db, rfs, old_commit)
  let new_entries = @gitlib.collect_tree_files_from_commit(db, rfs, new_commit)
  let changes : Array[(String, @git.ObjectId, @git.ObjectId)] = []
  for item in new_entries.to_array() {
    let (path, new_entry) = item
    if not(is_gitlink_mode_for_diff(new_entry.mode)) {
      continue
    }
    match old_entries.get(path) {
      Some(old_entry) =>
        if is_gitlink_mode_for_diff(old_entry.mode) &&
          old_entry.id != new_entry.id {
          changes.push((path, old_entry.id, new_entry.id))
        }
      None => ()
    }
  }
  if changes.length() == 0 {
    return false
  }
  let submodules = parse_gitmodules(rfs, root)
  let mut handled = false
  for item in changes {
    let (path, old_id, new_id) = item
    let submodule_name = resolve_submodule_name_for_path(submodules, path)
    let subjects = collect_submodule_diff_subjects(
      fs, root, git_dir, repo_git_dir, path, submodule_name, old_id, new_id,
    )
    if subjects.length() == 0 {
      continue
    }
    print_line("Submodule \{path} \{old_id.to_hex()}..\{new_id.to_hex()}:")
    for subject in subjects {
      print_line("  > \{subject}")
    }
    handled = true
  }
  handled
}

///|
fn resolve_submodule_diff_range(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> (@git.ObjectId, @git.ObjectId)? raise Error {
  if spec.has_suffix("^!") && spec.length() > 2 {
    let target_ref = String::unsafe_substring(
      spec,
      start=0,
      end=spec.length() - 2,
    )
    let end_id = @gitrepo.rev_parse(rfs, git_dir, target_ref)
    guard end_id is Some(new_id) else { return None }
    guard db.get(rfs, new_id) is Some(obj) else { return None }
    if obj.obj_type != @git.ObjectType::Commit {
      return None
    }
    let info = @git.parse_commit(obj.data)
    if info.parents.length() == 0 {
      return None
    }
    return Some((info.parents[0], new_id))
  }
  match spec.find("..") {
    Some(idx) => {
      let start_ref = String::unsafe_substring(spec, start=0, end=idx)
      let end_ref = String::unsafe_substring(
        spec,
        start=idx + 2,
        end=spec.length(),
      )
      if start_ref.length() == 0 {
        return None
      }
      let start_id = @gitrepo.rev_parse(rfs, git_dir, start_ref)
      let end_id = @gitrepo.rev_parse(
        rfs,
        git_dir,
        if end_ref.length() == 0 {
          "HEAD"
        } else {
          end_ref
        },
      )
      guard start_id is Some(old_id) && end_id is Some(new_id) else {
        return None
      }
      Some((old_id, new_id))
    }
    None => None
  }
}

///|
fn resolve_submodule_name_for_path(
  submodules : Array[SubmoduleInfo],
  path : String,
) -> String {
  for sub in submodules {
    if sub.path == path {
      return sub.name
    }
  }
  path
}

///|
fn collect_submodule_diff_subjects(
  fs : OsFs,
  root : String,
  git_dir : String,
  repo_git_dir : String,
  path : String,
  submodule_name : String,
  old_id : @git.ObjectId,
  new_id : @git.ObjectId,
) -> Array[String] raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let candidates = resolve_submodule_git_dir_candidates(
    rfs, root, git_dir, repo_git_dir, path, submodule_name,
  )
  for sub_git_dir in candidates {
    let commits = collect_commits_in_range(rfs, sub_git_dir, old_id, new_id) catch {
      _ => []
    }
    if commits.length() == 0 {
      continue
    }
    let db = @gitlib.ObjectDb::load(rfs, sub_git_dir) catch { _ => continue }
    let subjects : Array[String] = []
    for commit_id in commits {
      match db.get(rfs, commit_id) {
        Some(obj) =>
          if obj.obj_type == @git.ObjectType::Commit {
            let message = extract_commit_message(obj.data)
            let subject = get_first_line(message)
            if subject.length() > 0 {
              subjects.push(subject)
            }
          }
        None => ()
      }
    }
    if subjects.length() > 0 {
      return subjects
    }
  }
  []
}

///|
fn resolve_submodule_git_dir_candidates(
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  repo_git_dir : String,
  path : String,
  submodule_name : String,
) -> Array[String] {
  let candidates : Array[String] = []
  let worktree_git = root + "/" + path + "/.git"
  if rfs.is_file(worktree_git) {
    let resolved = @gitlib.resolve_gitdir(rfs, worktree_git)
    candidates.push(resolved)
  } else if rfs.is_dir(worktree_git) {
    candidates.push(worktree_git)
  }
  let linked_modules = git_dir + "/modules/" + submodule_name
  if rfs.is_dir(linked_modules) && not(candidates.contains(linked_modules)) {
    candidates.push(linked_modules)
  }
  let common_modules = repo_git_dir + "/modules/" + submodule_name
  if rfs.is_dir(common_modules) && not(candidates.contains(common_modules)) {
    candidates.push(common_modules)
  }
  candidates
}

///|
