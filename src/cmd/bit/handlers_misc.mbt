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
        Some((old_id, new_id)) =>
          @gitlib.diff_trees(rfs, repo_git_dir, Some(old_id), new_id)
        None =>
          raise @git.GitError::InvalidObject(
            "unsupported diff range: " + spec,
          )
      }
    }
    None =>
      if cached {
        @gitlib.diff_index(fs, root)
      } else {
        @gitlib.diff_worktree(fs, root)
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
    let end_id = @gitlib.rev_parse(rfs, git_dir, target_ref)
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
      let start_id = @gitlib.rev_parse(rfs, git_dir, start_ref)
      let end_id = @gitlib.rev_parse(
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
async fn handle_merge(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  let mut target_ref : String? = None
  let mut message : String? = None
  let mut no_ff = false
  let mut ff_only = false
  let mut squash = false
  let mut abort_merge = false
  let mut continue_merge = false
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
      "--no-ff" => {
        no_ff = true
        i += 1
        continue
      }
      "--ff-only" => {
        ff_only = true
        i += 1
        continue
      }
      "--squash" => {
        squash = true
        i += 1
        continue
      }
      "--abort" => {
        abort_merge = true
        i += 1
        continue
      }
      "--continue" => {
        continue_merge = true
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) => target_ref = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("merge", arg)
      _ => ()
    }
    i += 1
  }
  // Handle --abort
  if abort_merge {
    let orig_head_path = git_dir + "/ORIG_HEAD"
    let merge_head_path = git_dir + "/MERGE_HEAD"
    if rfs.is_file(orig_head_path) {
      let orig_hex = rfs.read_file(orig_head_path)
        |> decode_bytes
        |> trim_string
      ignore(@gitlib.reset(wfs, rfs, root, orig_hex, @gitlib.ResetMode::Hard))
      wfs.remove_file(orig_head_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      wfs.remove_file(merge_head_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      wfs.remove_file(git_dir + "/MERGE_MSG") catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      print_line("Merge aborted.")
    } else {
      @stdio.stderr.write(
        "fatal: There is no merge to abort (ORIG_HEAD missing).",
      )
      @sys.exit(128)
    }
    return
  }
  // Handle --continue
  if continue_merge {
    let merge_head_path = git_dir + "/MERGE_HEAD"
    let merge_msg_path = git_dir + "/MERGE_MSG"
    if not(rfs.is_file(merge_head_path)) {
      @stdio.stderr.write(
        "fatal: There is no merge in progress (MERGE_HEAD missing).",
      )
      @sys.exit(128)
    }
    // Commit the merge
    let msg = if rfs.is_file(merge_msg_path) {
      rfs.read_file(merge_msg_path) |> decode_bytes |> trim_string
    } else {
      "Merge commit"
    }
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    let commit_id = @gitlib.commit(wfs, rfs, root, msg, author, timestamp)
    let short = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
    // Clean up merge state
    wfs.remove_file(merge_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(git_dir + "/ORIG_HEAD") catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    print_line("[\{short}] \{msg}")
    return
  }
  guard target_ref is Some(refspec) else {
    raise @git.GitError::InvalidObject("No commit to merge specified")
  }
  // Check if subdir-clone and handle specially
  match get_subdir_info(fs, git_dir) {
    Some((_, subdir_path, _)) => {
      handle_subdir_merge(fs, root, git_dir, refspec, subdir_path, message) catch {
        err => raise err
      }
      return
    }
    None => ()
  }
  // Resolve target
  let target_id = @gitlib.rev_parse(fs, git_dir, refspec)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{refspec}")
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let msg = message.unwrap_or("Merge \{refspec}")
  // Handle --squash
  if squash {
    // Squash merge: apply changes but don't commit
    let result = @gitlib.merge(fs, fs, root, tid, msg, author, timestamp)
    match result.status {
      @gitlib.MergeStatus::AlreadyUpToDate => print_line("Already up to date.")
      @gitlib.MergeStatus::FastForward | @gitlib.MergeStatus::Merged => {
        // Reset HEAD but keep working tree changes
        let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
        match head {
          Some(h) =>
            // Reset index to HEAD but keep working tree
            ignore(
              @gitlib.reset(wfs, rfs, root, h.to_hex(), @gitlib.ResetMode::Soft),
            )
          None => ()
        }
        print_line("Squash commit -- not updating HEAD")
        // Save merge message for later commit
        wfs.write_string(
          git_dir + "/SQUASH_MSG",
          "Squashed commit of the following:\n\n" + msg + "\n",
        )
      }
      @gitlib.MergeStatus::Conflicted => {
        print_line("CONFLICT: Merge conflict")
        for path in result.conflicts {
          print_line("  \{path}")
        }
      }
    }
    return
  }
  // Check if fast-forward is possible
  let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  let is_ff = match head {
    Some(h) => is_ancestor(rfs, git_dir, h, tid)
    None => false
  }
  // Handle --ff-only
  if ff_only && not(is_ff) {
    @stdio.stderr.write("fatal: Not possible to fast-forward, aborting.")
    @sys.exit(128)
  }
  // Handle --no-ff: force merge commit even if fast-forward possible
  if no_ff && is_ff {
    // Create merge commit even though ff is possible
    let db = @gitlib.ObjectDb::load(rfs, git_dir)
    let head_id = @gitlib.rev_parse(rfs, git_dir, "HEAD")
    guard head_id is Some(hid) else {
      raise @git.GitError::InvalidObject("Cannot resolve HEAD")
    }
    // Use target's tree
    let target_obj = db.get(rfs, tid)
    guard target_obj is Some(to) else {
      raise @git.GitError::InvalidObject("Cannot read target commit")
    }
    let target_info = @git.parse_commit(to.data)
    // Write tree (use target's tree)
    let tree_id = target_info.tree
    // Create merge commit with two parents
    let commit = @git.Commit::new(
      tree_id,
      [hid, tid],
      author,
      timestamp,
      "+0000",
      author,
      timestamp,
      "+0000",
      msg + "\n",
    )
    let (commit_id, commit_data) = @git.create_commit(commit)
    @gitlib.write_object_bytes(wfs, git_dir, commit_id, commit_data)
    // Update HEAD
    let head_path = git_dir + "/HEAD"
    let head_content = rfs.read_file(head_path) |> decode_bytes |> trim_string
    if head_content.has_prefix("ref: ") {
      let ref_path = git_dir +
        "/" +
        String::unsafe_substring(
          head_content,
          start=5,
          end=head_content.length(),
        )
      wfs.write_string(ref_path, commit_id.to_hex() + "\n")
    } else {
      wfs.write_string(head_path, commit_id.to_hex() + "\n")
    }
    // Checkout the new tree
    ignore(@gitlib.checkout(wfs, rfs, root, commit_id.to_hex(), detach=false))
    let short = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
    print_line("Merge made by the 'ort' strategy (--no-ff). [\{short}]")
    return
  }
  // Regular merge
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
fn is_ancestor(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  ancestor : @git.ObjectId,
  descendant : @git.ObjectId,
) -> Bool {
  // Check if ancestor is an ancestor of descendant
  let db = @gitlib.ObjectDb::load(rfs, git_dir) catch { _ => return false }
  let ancestor_hex = ancestor.to_hex()
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [descendant]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if hex == ancestor_hex {
      return true
    }
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    let obj = db.get(rfs, cid) catch { _ => continue }
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
  false
}

///|
async fn handle_tag(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut list_mode = true
  let mut delete_mode = false
  let mut annotated = false
  let mut force = false
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
      "-f" | "--force" => {
        force = true
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("tag", arg)
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
  if force {
    if @gitlib.resolve_ref(fs, git_dir, "refs/tags/" + name) is Some(_) {
      @gitlib.delete_tag(fs, git_dir, name)
    }
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
async fn handle_rm(args : Array[String]) -> Unit raise Error {
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rm", arg)
      _ => ()
    }
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("No pathspec given")
  }
  @gitlib.rm_paths(fs, fs, root, paths, cached~, force~, recursive~)
}

///|
async fn handle_mv(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut force = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("mv", arg)
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
  let fs = OsFs::new()
  // Parse arguments
  let mut get_mode = false
  let mut get_bool = false
  let mut list_mode = false
  let mut unset_mode = false
  let mut unset_all = false
  let mut add_mode = false
  let mut remove_section_mode = false
  let mut fixed_value_mode = false
  let mut local_mode = false
  let mut global_mode = false
  let mut system_mode = false
  let mut key : String? = None
  let mut value : String? = None
  for arg in args {
    match arg {
      "--local" => local_mode = true
      "--global" => global_mode = true
      "--system" => system_mode = true
      "--get" => get_mode = true
      "--bool" => get_bool = true
      "--list" | "-l" => list_mode = true
      "--unset" => unset_mode = true
      "--unset-all" => unset_all = true
      "--add" => add_mode = true
      "--remove-section" => remove_section_mode = true
      "--fixed-value" => fixed_value_mode = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("config", arg)
      _ =>
        if key is None {
          key = Some(arg)
        } else if value is None {
          value = Some(arg)
        }
    }
  }
  if global_mode && system_mode {
    raise @git.GitError::InvalidObject(
      "only one config scope can be specified",
    )
  }
  if local_mode && (global_mode || system_mode) {
    raise @git.GitError::InvalidObject(
      "--local cannot be used with --global or --system",
    )
  }
  let config_path = if global_mode {
    match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
      Some(path) => path
      None =>
        match @sys.get_env_var("HOME") {
          Some(home) => home + "/.gitconfig"
          None => ".gitconfig"
        }
    }
  } else if system_mode {
    @sys.get_env_var("GIT_CONFIG_SYSTEM").unwrap_or("/etc/gitconfig")
  } else {
    let rfs : &@git.RepoFileSystem = fs
    let git_dir = find_git_dir(fs)
    let git_dir = if rfs.is_file(git_dir) {
      @gitlib.resolve_gitdir(rfs, git_dir)
    } else {
      git_dir
    }
    git_dir + "/config"
  }
  // Handle --list
  if list_mode {
    if fs.is_file(config_path) {
      list_config(fs, config_path)
    }
    return
  }
  if remove_section_mode {
    guard key is Some(section_key) else {
      raise @git.GitError::InvalidObject("section name required")
    }
    remove_config_section_file(fs, config_path, section_key)
    return
  }
  guard key is Some(k) else {
    raise @git.GitError::InvalidObject("key required")
  }
  // Handle --unset / --unset-all
  if unset_mode || unset_all {
    if fixed_value_mode && value is None {
      raise @git.GitError::InvalidObject("value required for --fixed-value")
    }
    let fixed = if fixed_value_mode { value } else { None }
    unset_config(fs, config_path, k, fixed, unset_all)
    return
  }
  if get_mode || value is None {
    // Read config - check overrides first
    let result = match get_config_override(k) {
      Some(v) => Some(v)
      None =>
        if fs.is_file(config_path) {
          get_config_value(fs, config_path, k)
        } else {
          (None : String?)
        }
    }
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
    if code_in_string(c, chars) {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if code_in_string(c, chars) {
      end -= 1
    } else {
      break
    }
  }
  String::unsafe_substring(s, start~, end~)
}

///|
fn code_in_string(c : UInt16, s : String) -> Bool {
  for i in 0..<s.length() {
    if s.unsafe_get(i) == c {
      return true
    }
  }
  false
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
  let slash_parts : Array[String] = []
  for part in value.split("\\") {
    slash_parts.push(part.to_string())
  }
  let escaped_backslash = slash_parts.join("\\\\")
  let quote_parts : Array[String] = []
  for part in escaped_backslash.split("\"") {
    quote_parts.push(part.to_string())
  }
  let encoded_value = quote_parts.join("\\\"")
  if not(rfs.is_file(config_path)) {
    // Create new config file
    wfs.write_string(
      config_path,
      section_header + "\n\t" + name + " = " + encoded_value + "\n",
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
        result.push("\t" + name + " = " + encoded_value)
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
            result.push("\t" + name + " = " + encoded_value)
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
          new_result.push("\t" + name + " = " + encoded_value)
          found = true
        }
      }
      wfs.write_string(config_path, new_result.join("\n"))
      return
    }
    // Add new section at end
    result.push(section_header)
    result.push("\t" + name + " = " + encoded_value)
  }
  wfs.write_string(config_path, result.join("\n"))
}

///|
fn unset_config(
  fs : OsFs,
  config_path : String,
  key : String,
  fixed_value : String?,
  unset_all : Bool,
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
  let mut removed = false
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
            let value_part = trim_chars(
              String::unsafe_substring(
                trimmed,
                start=idx + 1,
                end=trimmed.length(),
              ),
              " \t",
            )
            if fixed_value is Some(fv) && value_part != fv {
              ()
            } else if unset_all {
              continue
            } else if not(removed) {
              removed = true
              continue
            }
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
fn remove_config_section_file(
  fs : OsFs,
  config_path : String,
  section_key : String,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  if not(rfs.is_file(config_path)) {
    return
  }
  let parts : Array[String] = []
  for p in section_key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() == 0 {
    return
  }
  let (section, subsection) = if parts.length() == 1 {
    (parts[0], (None : String?))
  } else {
    let sub : Array[String] = []
    for i in 1..<parts.length() {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")))
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
      let matched = match subsection {
        Some(sub) => {
          let expected = section + " \"" + sub + "\""
          sec_content == expected || sec_content == section + " " + sub
        }
        None => sec_content == section
      }
      in_section = matched
      if matched {
        continue
      }
      result.push(line)
      continue
    }
    if in_section {
      continue
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
        .filter(arg => not(arg.has_prefix("-")))
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
        .filter(arg => not(arg.has_prefix("-")))
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
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let default_git_dir = root + "/.git"
  let git_dir = if rfs.is_file(default_git_dir) {
    @gitlib.resolve_gitdir(rfs, default_git_dir)
  } else {
    default_git_dir
  }
  let cwd_abs = @sys.get_env_var("PWD").unwrap_or(root)
  let abs_git_dir = if git_dir.has_prefix("/") {
    git_dir
  } else if git_dir == "." {
    cwd_abs
  } else {
    cwd_abs + "/" + git_dir
  }
  let mut revs_only = false
  for arg in args {
    match arg {
      "--revs-only" => revs_only = true
      _ => ()
    }
  }
  for arg in args {
    match arg {
      "--git-dir" => print_line(git_dir)
      "--absolute-git-dir" => print_line(abs_git_dir)
      "--show-toplevel" => {
        let abs = if root == "." {
          @sys.get_env_var("PWD").unwrap_or(root)
        } else {
          root
        }
        print_line(abs)
      }
      "--revs-only" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rev-parse", arg)
      _ => {
        let id = @gitlib.rev_parse(fs, git_dir, arg)
        match id {
          Some(oid) => print_line(oid.to_hex())
          None =>
            if not(revs_only) {
              raise @git.GitError::InvalidObject("unknown revision: " + arg)
            }
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("cat-file", arg)
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("ls-files", arg)
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
      let all_files = @gitlib.list_working_files_async(fs, root)
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
        let actual_git_dir = @gitlib.resolve_gitdir(fs, sub_git_dir)
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
        let actual_git_dir = @gitlib.resolve_gitdir(fs, sub_git_dir)
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("hash-object", arg)
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("ls-tree", arg)
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
  let cwd_prefix = compute_cwd_prefix(root)
  let normalized_filters = normalize_ls_tree_filters(path_filters, cwd_prefix)
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
    root, submodules, cwd_prefix, normalized_filters,
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
  cwd_prefix : String,
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
        if path == filter || path.has_prefix(filter + "/") {
          match_found = true
        }
        // Filter is under the entry path (need to recurse into this tree to find it)
        if filter.has_prefix(path + "/") {
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
        let sub_git_dir = @gitlib.resolve_gitdir(fs, sub_git_path)
        // Load the submodule's object database
        let sub_db = @gitlib.ObjectDb::load(fs, sub_git_dir)
        // entry.id is the commit SHA in the submodule
        // Resolve it to a tree
        let sub_tree_id = resolve_to_tree(sub_db, fs, entry.id) catch {
          err if @async.is_cancellation_error(err) => raise err
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
          cwd_prefix,
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
      let display_path = make_display_path(path, cwd_prefix)
      if name_only {
        print_line(display_path)
      } else {
        let mode_str = if entry.mode == "40000" { "040000" } else { entry.mode }
        let type_str = if is_tree {
          "tree"
        } else if is_submodule {
          "commit"
        } else {
          "blob"
        }
        print_line(
          "\{mode_str} \{type_str} \{entry.id.to_hex()}\t\{display_path}",
        )
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
        cwd_prefix,
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
    } else if arg.has_prefix("-") {
      warn_unimplemented_arg("write-tree", arg)
    }
  }
  let entries = @gitlib.read_index_entries(fs, git_dir)
  let tree_id = @gitlib.write_tree_from_index(fs, git_dir, entries, prefix~)
  print_line(tree_id.to_hex())
}

///|
async fn handle_show_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  let mut heads_only = false
  let mut tags_only = false
  let mut hash_only = false
  let mut verify = false
  let mut quiet = false
  let patterns : Array[String] = []
  for arg in args {
    match arg {
      "--heads" => heads_only = true
      "--tags" => tags_only = true
      "-s" | "--hash" => hash_only = true
      "--verify" => verify = true
      "-q" | "--quiet" => quiet = true
      "--" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("show-ref", arg)
      _ => patterns.push(arg)
    }
  }
  if verify {
    if patterns.length() == 0 {
      @sys.exit(1)
    }
    let mut has_missing = false
    for refname in patterns {
      match @gitlib.resolve_ref(fs, git_dir, refname) {
        Some(id) =>
          if not(quiet) {
            if hash_only {
              print_line(id.to_hex())
            } else {
              print_line("\{id.to_hex()} \{refname}")
            }
          }
        None => has_missing = true
      }
    }
    if has_missing {
      @sys.exit(1)
    }
    return
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
    if patterns.length() > 0 {
      let mut matched = false
      for pattern in patterns {
        if refname == pattern || refname.has_suffix("/" + pattern) {
          matched = true
          break
        }
      }
      if not(matched) {
        continue
      }
    }
    if hash_only {
      print_line(id.to_hex())
    } else {
      print_line("\{id.to_hex()} \{refname}")
    }
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("update-ref", arg)
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
            @stdio.stderr.write(
              "error: cannot lock ref '\{refname}': is at \{cur_id.to_hex()} but expected \{ov}",
            )
            @sys.exit(1)
          }
        None => {
          @stdio.stderr.write(
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
  let new_id = @git.ObjectId::from_hex(new_value) catch {
    _ =>
      match @gitlib.rev_parse(fs, actual_git_dir, new_value) {
        Some(id) => id
        None =>
          raise @git.GitError::InvalidObject("unknown revision: " + new_value)
      }
  }
  // Get current value
  let current_id = read_ref_value(fs, actual_git_dir, refname)
  // Check oldvalue if specified
  match old_value {
    Some(ov) => {
      let expected_id = @git.ObjectId::from_hex(ov)
      match current_id {
        Some(cur_id) =>
          if cur_id.to_hex() != expected_id.to_hex() {
            @stdio.stderr.write(
              "error: cannot lock ref '\{refname}': is at \{cur_id.to_hex()} but expected \{expected_id.to_hex()}",
            )
            @sys.exit(1)
          }
        None =>
          if expected_id.to_hex() != @git.ObjectId::zero().to_hex() {
            @stdio.stderr.write(
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
    (hex |> @git.ObjectId::from_hex |> Some) catch {
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
  if @sys.get_env_var("GIT_COMMITTER_NAME") is Some(n) {
    name = n
  }
  if @sys.get_env_var("GIT_COMMITTER_EMAIL") is Some(e) {
    email = e
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("symbolic-ref", arg)
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
        @stdio.stderr.write("usage: git reflog exists <ref>")
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
        @stdio.stderr.write("usage: git reflog delete <ref>")
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("gc", arg)
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("clean", arg)
      _ => ()
    }
  }
  // git clean requires -f unless -n is specified
  if not(force) && not(dry_run) {
    @stdio.stderr.write(
      "fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean",
    )
    @sys.exit(1)
  }
  // Get untracked files from status
  let status = @gitlib.status(fs, root)
  let mut files_to_clean : Array[String] = []
  if remove_only_ignored {
    // -X: only ignored files (not implemented - need gitignore parsing)
    @stdio.stderr.write(
      "warning: -X (remove only ignored) not fully implemented",
    )
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
      .filter(fn(f) { paths.iter().any(p => f == p || f.has_prefix(p + "/")) })
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
    dirs_to_check.sort_by((a, b) => b.length() - a.length())
    for dir in dirs_to_check {
      let abs_dir = root + "/" + dir
      if fs.is_dir(abs_dir) {
        let rfs : &@git.RepoFileSystem = fs
        let entries = rfs.readdir(abs_dir) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => continue
        }
        if entries.length() == 0 {
          let wfs : &@git.FileSystem = fs
          wfs.remove_dir(abs_dir) catch {
            err if @async.is_cancellation_error(err) => raise err
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("grep", arg)
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
    let content = decode_bytes(fs.read_file(abs_path)) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => continue
    }
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
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let subcmd = args.get(0).unwrap_or("")
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "" | "status" => handle_submodule_status(fs, root, git_dir, rest)
    "add" => handle_submodule_add(fs, root, git_dir, rest)
    "init" => handle_submodule_init(fs, root, git_dir, rest)
    "update" => handle_submodule_update(fs, root, git_dir, rest)
    "deinit" => handle_submodule_deinit(fs, root, git_dir, rest)
    "sync" => handle_submodule_sync(fs, root, git_dir, rest)
    _ => {
      @stdio.stderr.write("error: unknown submodule command: \{subcmd}")
      @sys.exit(1)
    }
  }
}

///|
fn resolve_submodule_common_git_dir(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if fs.is_file(commondir_path) {
    let raw = decode_bytes(
      fs.read_file(commondir_path) catch {
        _ => Bytes::default()
      },
    )
    let rel = trim_string(raw)
    if rel.length() > 0 {
      if rel.has_prefix("/") {
        return normalize_path(rel)
      } else {
        return normalize_path(git_dir + "/" + rel)
      }
    }
  }
  git_dir
}

///|
fn resolve_submodule_fetch_url(
  fs : OsFs,
  root : String,
  git_dir : String,
  url : String,
) -> String {
  let rfs : &@git.RepoFileSystem = fs
  match @gitlib.resolve_local_repo_path(rfs, root, url) {
    Some(local_path) => return local_path
    None => ()
  }
  let config_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
  let (remotes, _) = @gitlib.read_repo_config(fs, config_git_dir)
  let origin_url = match remotes.get("origin") {
    Some(rc) if rc.urls.length() > 0 => Some(rc.urls[0])
    _ => None
  }
  match origin_url {
    Some(base_url) =>
      match @gitlib.resolve_local_repo_path(rfs, root, base_url) {
        Some(base_path) =>
          match @gitlib.resolve_local_repo_path(rfs, base_path, url) {
            Some(resolved) => resolved
            None => url
          }
        None => url
      }
    None => url
  }
}

///|
async fn handle_submodule_add(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut branch : String? = None
  let mut url = ""
  let mut path = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--branch" | "-b" => {
        i += 1
        if i >= args.length() {
          raise @git.GitError::InvalidObject(
            "submodule add requires a branch name",
          )
        }
        branch = Some(args[i])
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("submodule add", arg)
      _ =>
        if url.length() == 0 {
          url = arg
        } else if path.length() == 0 {
          path = arg
        }
    }
    i += 1
  }
  if url.length() == 0 {
    raise @git.GitError::InvalidObject("submodule add requires a repository")
  }
  if path.length() == 0 {
    path = derive_submodule_path(url)
  }
  let name = path
  write_gitmodules_entry(fs, root, name, path, url, branch)
  let config_path = git_dir + "/config"
  set_config(fs, config_path, "submodule." + name + ".url", url, false)
  set_config(fs, config_path, "submodule." + name + ".path", path, false)
  if branch is Some(b) {
    set_config(fs, config_path, "submodule." + name + ".branch", b, false)
  }
  let fetch_url = resolve_submodule_fetch_url(fs, root, git_dir, url)
  let target_id = resolve_submodule_head_id(fs, root, fetch_url)
  let modules_dir = git_dir + "/modules/" + name
  if not(fs.is_dir(modules_dir)) {
    @gitlib.init_repo(fs, modules_dir, bare=true)
  }
  let modules_config = modules_dir + "/config"
  set_config(fs, modules_config, "remote.origin.url", fetch_url, false)
  set_config(
    fs, modules_config, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*",
    false,
  )
  fetch_submodule_objects(fs, root, modules_dir, fetch_url, target_id)
  let sub_path = root + "/" + path
  if not(fs.is_dir(sub_path)) {
    fs.mkdir_p(sub_path)
  }
  let rel_path = get_rel_path(sub_path, modules_dir)
  fs.write_string(sub_path + "/.git", "gitdir: \{rel_path}\n")
  ensure_submodule_gitdir_config(fs, modules_dir, sub_path)
  run_checkout_in_submodule(fs, fs, sub_path, modules_dir, target_id)
  let checkout_branch = match branch {
    Some(name) => Some(name)
    None =>
      match @gitlib.read_remote_head_branch(fs, modules_dir) {
        Some(name) => Some(name)
        None => Some("main")
      }
  }
  match checkout_branch {
    Some(branch_name) => {
      let branch_ref = modules_dir + "/refs/heads/" + branch_name
      match branch_ref.rev_find("/") {
        Some(i) =>
          fs.mkdir_p(String::unsafe_substring(branch_ref, start=0, end=i))
        None => ()
      }
      fs.write_string(branch_ref, target_id.to_hex() + "\n")
      fs.write_string(
        modules_dir + "/HEAD",
        "ref: refs/heads/" + branch_name + "\n",
      )
      set_config(
        fs,
        modules_config,
        "branch." + branch_name + ".remote",
        "origin",
        false,
      )
      set_config(
        fs,
        modules_config,
        "branch." + branch_name + ".merge",
        "refs/heads/" + branch_name,
        false,
      )
    }
    None => ()
  }
  @gitlibnative.apply_worktree_modes_from_commit(
    fs, fs, sub_path, modules_dir, target_id,
  ) catch {
    err if @async.is_cancellation_error(err) => raise err
    err =>
      eprint_line(
        "warning: failed to apply worktree modes in submodule '\{path}': \{err}",
      )
  }
  @gitlib.add_paths_async(fs, fs, root, [".gitmodules"])
  update_submodule_index_entry(fs, git_dir, path, target_id)
}

///|
fn derive_submodule_path(url : String) -> String {
  let mut name = url
  for part_view in url.split("/") {
    let part = part_view.to_string()
    if part.length() > 0 {
      name = part
    }
  }
  if name.has_suffix(".git") && name.length() > 4 {
    name = String::unsafe_substring(name, start=0, end=name.length() - 4)
  }
  name
}

///|
fn write_gitmodules_entry(
  fs : OsFs,
  root : String,
  name : String,
  path : String,
  url : String,
  branch : String?,
) -> Unit raise Error {
  let gitmodules_path = root + "/.gitmodules"
  let rfs : &@git.RepoFileSystem = fs
  let mut content = if rfs.is_file(gitmodules_path) {
    decode_bytes(rfs.read_file(gitmodules_path))
  } else {
    ""
  }
  let section = "[submodule \"\{name}\"]"
  if content.contains(section) {
    return
  }
  let mut entry = section + "\n\tpath = " + path + "\n\turl = " + url + "\n"
  if branch is Some(b) {
    entry = entry + "\tbranch = " + b + "\n"
  }
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  fs.write_string(gitmodules_path, content + entry)
}

///|
async fn resolve_submodule_head_id(
  fs : OsFs,
  root : String,
  url : String,
) -> @git.ObjectId raise Error {
  let rfs : &@git.RepoFileSystem = fs
  match @gitlib.resolve_local_repo_path(rfs, root, url) {
    Some(src_path) =>
      match @gitlib.detect_git_dir(rfs, src_path) {
        Some((src_git_dir, _)) => {
          let head = @gitlib.resolve_head_commit(rfs, src_git_dir)
          match head {
            Some(id) => id
            None =>
              raise @git.GitError::InvalidObject(
                "Invalid HEAD in submodule: " + url,
              )
          }
        }
        None =>
          raise @git.GitError::InvalidObject("Not a git repository: " + url)
      }
    None => {
      let resolved = resolve_remote_ref_id(url, "HEAD")
      match resolved {
        Some((id, _)) => id
        None =>
          raise @git.GitError::InvalidObject(
            "Failed to resolve submodule HEAD: " + url,
          )
      }
    }
  }
}

///|
fn update_submodule_index_entry(
  fs : OsFs,
  git_dir : String,
  path : String,
  id : @git.ObjectId,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let entries = @gitlib.read_index_entries(rfs, git_dir) catch { _ => [] }
  let out : Array[@gitlib.IndexEntry] = []
  for e in entries {
    if e.path != path {
      out.push(e)
    }
  }
  out.push(
    @gitlib.IndexEntry::new(path, id, 57344, 0, mtime_sec=0, mtime_nsec=0),
  )
  @gitlib.write_index_entries(fs, git_dir, out)
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
    let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_git)
    let head_id = @gitlib.resolve_head_commit(rfs, sub_git_dir) catch {
      err if @async.is_cancellation_error(err) => raise err
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
  let mut has_init_flag = false
  for arg in args {
    if arg == "--init" {
      has_init_flag = true
      break
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let gitfile = root + "/.git"
  if has_init_flag && rfs.is_file(gitfile) {
    let _gitfile_content = decode_bytes(
      rfs.read_file(gitfile) catch {
        _ => Bytes::default()
      },
    )
  }
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
    let sub_git_is_dir = rfs.is_dir(sub_git)
    let mut has_modules = rfs.is_dir(modules_dir)
    // Clone if needed
    if not(sub_git_is_dir) && not(has_modules) {
      print_line("Cloning into '\{sub.path}'...")
      @gitlib.init_repo(wfs, modules_dir, bare=true)
      let config_path = modules_dir + "/config"
      set_config(fs, config_path, "remote.origin.url", sub.url, false)
      set_config(
        fs, config_path, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*",
        false,
      )
      has_modules = true
    }
    if has_modules {
      let config_path = modules_dir + "/config"
      let fetch_url = resolve_submodule_fetch_url(fs, root, git_dir, sub.url)
      set_config(fs, config_path, "remote.origin.url", fetch_url, false)
      set_config(
        fs, config_path, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*",
        false,
      )
      fetch_submodule_objects(fs, root, modules_dir, fetch_url, target_id)
    }
    if not(sub_git_is_dir) && has_modules {
      // Create or refresh .git file to point to modules dir
      let rel_path = get_rel_path(sub_path, modules_dir)
      wfs.write_string(sub_git, "gitdir: \{rel_path}\n")
    }
    if has_modules {
      ensure_submodule_gitdir_config(fs, modules_dir, sub_path)
    }
    // Checkout target commit
    let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_git)
    print_line(
      "Submodule path '\{sub.path}': checked out '\{target_id.to_hex()}'",
    )
    // Use checkout command
    run_checkout_in_submodule(wfs, rfs, sub_path, sub_git_dir, target_id)
    @gitlibnative.apply_worktree_modes_from_commit(
      fs, fs, sub_path, sub_git_dir, target_id,
    ) catch {
      err if @async.is_cancellation_error(err) => raise err
      err =>
        eprint_line(
          "warning: failed to apply worktree modes in submodule '\{sub.path}': \{err}",
        )
    }
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

///|
async fn fetch_submodule_objects(
  fs : OsFs,
  root : String,
  modules_dir : String,
  url : String,
  target_id : @git.ObjectId,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  match @gitlib.resolve_local_repo_path(rfs, root, url) {
    Some(src_path) => {
      fetch_local_repo(fs, src_path, modules_dir, "origin", url, [])
      return ()
    }
    None => ()
  }
  let pack = @gitnative.fetch_pack_http(url, [target_id], true)
  let objects = @pack.parse_packfile(pack)
  @pack.write_packfile_with_index(fs, modules_dir, pack, objects)
}

///|
fn ensure_submodule_gitdir_config(
  fs : OsFs,
  modules_dir : String,
  work_tree : String,
) -> Unit raise Error {
  let config_path = modules_dir + "/config"
  let rel_work_tree = get_rel_path(modules_dir, work_tree)
  set_config(fs, config_path, "core.worktree", rel_work_tree, false)
  set_config(fs, config_path, "core.bare", "false", false)
}

///|
fn run_checkout_in_submodule(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  work_tree : String,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit {
  let db = @gitlib.ObjectDb::load(rfs, git_dir) catch { _ => return }
  let head_path = git_dir + "/HEAD"
  wfs.write_string(head_path, commit_id.to_hex() + "\n") catch {
    _ => ()
  }
  let files = @gitlib.collect_tree_files_from_commit(db, rfs, commit_id) catch {
    _ => return
  }
  @gitlib.write_worktree_from_files(
    db,
    wfs,
    rfs,
    work_tree,
    git_dir,
    files,
    remove_missing=true,
  ) catch {
    _ => return
  }
  let entries = @gitlib.tree_files_to_index(db, rfs, files) catch {
    _ => return
  }
  @gitlib.write_index_entries(wfs, git_dir, entries) catch {
    _ => return
  }
}

///|

///|
fn get_rel_path(from : String, to : String) -> String {
  let from_parts : Array[String] = from
    .split("/")
    .filter(s => s.to_string().length() > 0)
    .map(s => s.to_string())
    .collect()
  let to_parts : Array[String] = to
    .split("/")
    .filter(s => s.to_string().length() > 0)
    .map(s => s.to_string())
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
      let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_path + "/.git")
      if rfs.is_dir(sub_git_dir) {
        let status = @gitlib.status(rfs, sub_path) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => continue
        }
        if status.unstaged_modified.length() > 0 {
          @stdio.stderr.write(
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
      let entries = rfs.readdir(sub_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => continue
      }
      for e in entries {
        if e == ".git" {
          continue
        }
        let full = sub_path + "/" + e
        if rfs.is_dir(full) {
          remove_dir_recursive(fs, full)
        } else {
          wfs.remove_file(full) catch {
            err if @async.is_cancellation_error(err) => raise err
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
    let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_path + "/.git")
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
        mainline = args[i + 1] |> @strconv.parse_int |> Some
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
      @stdio.stderr.write("error: no revert in progress")
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
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
    }
    // Clean up state files
    wfs.remove_file(revert_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    print_line("Revert aborted.")
    return
  }
  // Handle --skip
  if do_skip {
    if not(rfs.is_file(revert_head_path)) {
      @stdio.stderr.write("error: no revert in progress")
      @sys.exit(1)
    }
    // Clean up state files (skip current revert)
    wfs.remove_file(revert_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
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
      @stdio.stderr.write("error: no revert in progress")
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
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(orig_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
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
    @stdio.stderr.write(
      "error: revert already in progress, use --continue, --abort, or --skip",
    )
    @sys.exit(1)
  }
  // Save ORIG_HEAD
  let current_head = @gitlib.resolve_head_commit(rfs, git_dir)
  if current_head is Some(hid) {
    wfs.write_string(orig_head_path, hid.to_hex() + "\n")
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
        @gitlib.add_paths_async(wfs, rfs, root, [path])
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
            let current_content = rfs.read_file(abs_path) catch {
              err if @async.is_cancellation_error(err) => raise err
              _ => b""
            }
            let current_id = @git.hash_blob(current_content)
            if current_id.to_hex() != commit_entry.id.to_hex() {
              // Current file differs from commit, potential conflict
              @stdio.stderr.write("warning: \{path} has local modifications")
              has_conflicts = true
              continue
            }
            // Restore parent version
            let blob_obj = db.get(rfs, parent_entry.id)
            guard blob_obj is Some(bo) else { continue }
            wfs.write_file(abs_path, bo.data)
            @gitlib.add_paths_async(wfs, rfs, root, [path])
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
      @stdio.stderr.write("error: could not revert \{commit_ref}")
      @stdio.stderr.write(
        "hint: after resolving conflicts, run 'git revert --continue'",
      )
      @stdio.stderr.write("hint: to skip this commit, run 'git revert --skip'")
      @stdio.stderr.write("hint: to abort, run 'git revert --abort'")
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
    err if @async.is_cancellation_error(err) => raise err
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
fn normalize_notes_ref(ref_name : String?) -> String {
  let name = ref_name.unwrap_or("commits")
  if name.has_prefix("refs/") {
    name
  } else {
    "refs/notes/" + name
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
  let mut ref_name : String? = None
  let rest : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ref" if i + 1 < args.length() => {
        ref_name = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ref=") => {
        ref_name = Some((try! arg[6:]).to_string())
        i += 1
        continue
      }
      _ => {
        rest.push(arg)
        i += 1
        continue
      }
    }
  }
  let notes_ref = normalize_notes_ref(ref_name)
  let notes_ref_path = git_dir + "/" + notes_ref
  // Parse subcommand
  let subcmd = rest.get(0).unwrap_or("list")
  let subargs : Array[String] = []
  for i in 1..<rest.length() {
    subargs.push(rest[i])
  }
  match subcmd {
    "list" => notes_list(rfs, git_dir, notes_ref_path)
    "show" => {
      let commit_ref = subargs.get(0).unwrap_or("HEAD")
      notes_show(rfs, git_dir, notes_ref_path, commit_ref)
    }
    "add" => {
      let mut message : String? = None
      let mut force = false
      let mut commit_ref = "HEAD"
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-m" | "--message" if i + 1 < subargs.length() => {
            message = Some(subargs[i + 1])
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
          "-f" | "--force" => {
            force = true
            i += 1
            continue
          }
          _ if not(arg.has_prefix("-")) => {
            commit_ref = arg
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard message is Some(msg) else {
        @stdio.stderr.write("error: notes add requires -m <message>")
        @sys.exit(1)
      }
      notes_add(wfs, rfs, git_dir, notes_ref_path, commit_ref, msg, force)
    }
    "append" => {
      let mut message : String? = None
      let mut commit_ref = "HEAD"
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-m" | "--message" if i + 1 < subargs.length() => {
            message = Some(subargs[i + 1])
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
          _ if not(arg.has_prefix("-")) => {
            commit_ref = arg
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard message is Some(msg) else {
        @stdio.stderr.write("error: notes append requires -m <message>")
        @sys.exit(1)
      }
      notes_append(wfs, rfs, git_dir, notes_ref_path, commit_ref, msg)
    }
    "edit" => {
      let mut message : String? = None
      let mut commit_ref = "HEAD"
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-m" | "--message" if i + 1 < subargs.length() => {
            message = Some(subargs[i + 1])
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
          _ if not(arg.has_prefix("-")) => {
            commit_ref = arg
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard message is Some(msg) else {
        @stdio.stderr.write("error: notes edit requires -m <message>")
        @sys.exit(1)
      }
      notes_add(wfs, rfs, git_dir, notes_ref_path, commit_ref, msg, true)
    }
    "copy" => {
      let mut force = false
      let mut from_ref : String? = None
      let mut to_ref : String? = None
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-f" | "--force" => {
            force = true
            i += 1
            continue
          }
          _ if not(arg.has_prefix("-")) => {
            if from_ref is None {
              from_ref = Some(arg)
            } else if to_ref is None {
              to_ref = Some(arg)
            }
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard from_ref is Some(from_commit) else {
        @stdio.stderr.write("usage: git notes copy <from> <to>")
        @sys.exit(1)
      }
      guard to_ref is Some(to_commit) else {
        @stdio.stderr.write("usage: git notes copy <from> <to>")
        @sys.exit(1)
      }
      notes_copy(
        wfs, rfs, git_dir, notes_ref_path, from_commit, to_commit, force,
      )
    }
    "merge" => {
      let mut strategy : String? = None
      let mut other_ref : String? = None
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-s" if i + 1 < subargs.length() => {
            strategy = Some(subargs[i + 1])
            i += 2
            continue
          }
          "--strategy" if i + 1 < subargs.length() => {
            strategy = Some(subargs[i + 1])
            i += 2
            continue
          }
          _ if arg.has_prefix("--strategy=") => {
            strategy = Some((try! arg[11:]).to_string())
            i += 1
            continue
          }
          _ if not(arg.has_prefix("-")) => {
            other_ref = Some(arg)
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard other_ref is Some(other_name) else {
        @stdio.stderr.write("usage: git notes merge <ref>")
        @sys.exit(1)
      }
      match strategy {
        Some(s) =>
          if s != "ours" &&
            s != "theirs" &&
            s != "union" &&
            s != "cat_sort_uniq" {
            @stdio.stderr.write("error: unsupported merge strategy: \{s}")
            @sys.exit(1)
          }
        None => ()
      }
      let other_ref_path = git_dir +
        "/" +
        (other_name |> Some |> normalize_notes_ref)
      notes_merge(wfs, rfs, git_dir, notes_ref_path, other_ref_path, strategy)
    }
    "rewrite" => {
      let mut force = false
      let mut use_stdin = false
      let mut from_ref : String? = None
      let mut to_ref : String? = None
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "--stdin" => {
            use_stdin = true
            i += 1
            continue
          }
          "-f" | "--force" => {
            force = true
            i += 1
            continue
          }
          _ if not(arg.has_prefix("-")) => {
            if from_ref is None {
              from_ref = Some(arg)
            } else if to_ref is None {
              to_ref = Some(arg)
            }
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      if use_stdin {
        if from_ref is Some(_) || to_ref is Some(_) {
          @stdio.stderr.write(
            "usage: git notes rewrite [--stdin] [-f] [<from> <to>]",
          )
          @sys.exit(1)
        }
        let data = read_all_stdin()
        let text = decode_bytes(data)
        let lines = split_lines(text)
        for line in lines {
          let parts = split_whitespace_tokens(line)
          if parts.length() != 2 {
            @stdio.stderr.write("error: invalid rewrite line: \{line}")
            @sys.exit(1)
          }
          let from = parts[0]
          let to = parts[1]
          notes_rewrite(wfs, rfs, git_dir, notes_ref_path, from, to, force)
        }
        return
      }
      guard from_ref is Some(from_commit) else {
        @stdio.stderr.write("usage: git notes rewrite <from> <to>")
        @sys.exit(1)
      }
      guard to_ref is Some(to_commit) else {
        @stdio.stderr.write("usage: git notes rewrite <from> <to>")
        @sys.exit(1)
      }
      notes_rewrite(
        wfs, rfs, git_dir, notes_ref_path, from_commit, to_commit, force,
      )
    }
    "remove" => {
      let commit_ref = subargs.get(0).unwrap_or("HEAD")
      notes_remove(wfs, rfs, git_dir, notes_ref_path, commit_ref)
    }
    "prune" => notes_prune(wfs, rfs, git_dir, notes_ref_path)
    _ => {
      @stdio.stderr.write(
        "usage: git notes [--ref <name>] [list | show | add | append | edit | copy | merge | rewrite | remove | prune]",
      )
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
    @stdio.stderr.write("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @git.parse_commit(o.data)
  // Read tree
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else {
    @stdio.stderr.write("error: notes tree corrupt")
    @sys.exit(1)
  }
  let entries = @git.parse_tree(to.data)
  // Find entry matching target commit
  for entry in entries {
    if entry.name == target_hex {
      let note_obj = db.get(rfs, entry.id)
      guard note_obj is Some(no) else {
        @stdio.stderr.write("error: note blob corrupt")
        @sys.exit(1)
      }
      no.data |> decode_bytes |> print_line
      return
    }
  }
  @stdio.stderr.write("error: no note found for \{target_hex}")
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
    message.to_array().map(c => c.to_int().to_byte()),
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
                  @stdio.stderr.write(
                    "error: note already exists for \{target_hex}",
                  )
                  @stdio.stderr.write("Use -f to overwrite existing note")
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
  entries.sort_by((a, b) => a.name.compare(b.name))
  // Create tree
  let (tree_id, tree_data) = @git.create_tree(entries)
  @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
  // Create commit
  let author = get_author_string()
  let timestamp = @sys.get_env_var("GIT_COMMITTER_DATE")
    .map(parse_commit_date)
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
async fn notes_append(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
  commit_ref : String,
  message : String,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Get existing tree entries and note content if present
  let entries : Array[@git.TreeEntry] = []
  let mut parent_commit : @git.ObjectId? = None
  let mut existing_text : String? = None
  if rfs.is_file(notes_ref_path) {
    let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
    let commit_hex = trim_string(ref_content)
    let commit_id = @git.ObjectId::from_hex(commit_hex)
    parent_commit = Some(commit_id)
    let db = @gitlib.ObjectDb::load(rfs, git_dir)
    let obj = db.get(rfs, commit_id)
    guard obj is Some(o) else {
      @stdio.stderr.write("error: notes ref corrupt")
      @sys.exit(1)
    }
    let commit_info = @git.parse_commit(o.data)
    let tree_obj = db.get(rfs, commit_info.tree)
    guard tree_obj is Some(to) else {
      @stdio.stderr.write("error: notes tree corrupt")
      @sys.exit(1)
    }
    let existing = @git.parse_tree(to.data)
    for e in existing {
      if e.name == target_hex {
        let note_obj = db.get(rfs, e.id)
        guard note_obj is Some(no) else {
          @stdio.stderr.write("error: note blob corrupt")
          @sys.exit(1)
        }
        existing_text = no.data |> decode_bytes |> Some
      } else {
        entries.push(e)
      }
    }
  }
  let new_text = match existing_text {
    Some(text) => {
      let sep = if text == "" || text.has_suffix("\n") { "" } else { "\n" }
      text + sep + message
    }
    None => message
  }
  // Create blob for note content
  let note_content = Bytes::from_array(
    new_text.to_array().map(c => c.to_int().to_byte()),
  )
  let note_id = @gitlib.write_loose_object(
    wfs,
    git_dir,
    @git.ObjectType::Blob,
    note_content,
  )
  // Add new note entry
  entries.push(@git.TreeEntry::new("100644", target_hex, note_id))
  // Sort entries by name (git requires sorted trees)
  entries.sort_by((a, b) => a.name.compare(b.name))
  // Create tree
  let (tree_id, tree_data) = @git.create_tree(entries)
  @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
  // Create commit
  let author = get_author_string()
  let timestamp = get_current_timestamp()
  let parents = match parent_commit {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000", "Notes appended by 'git notes append'\n",
  )
  let (commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, commit_id, commit_data)
  // Ensure refs/notes directory exists
  wfs.mkdir_p(git_dir + "/refs/notes")
  // Update notes ref
  wfs.write_string(notes_ref_path, commit_id.to_hex() + "\n")
}

///|
async fn notes_copy(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
  from_ref : String,
  to_ref : String,
  force : Bool,
) -> Unit raise Error {
  // Resolve commits
  let from_id = @gitlib.rev_parse(rfs, git_dir, from_ref)
  guard from_id is Some(fid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{from_ref}")
  }
  let to_id = @gitlib.rev_parse(rfs, git_dir, to_ref)
  guard to_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{to_ref}")
  }
  let from_hex = fid.to_hex()
  let to_hex = tid.to_hex()
  if from_hex == to_hex {
    @stdio.stderr.write("error: note already exists for \{to_hex}")
    @sys.exit(1)
  }
  // Load notes tree
  if not(rfs.is_file(notes_ref_path)) {
    @stdio.stderr.write("error: no note found for \{from_hex}")
    @sys.exit(1)
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @git.parse_commit(o.data)
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else {
    @stdio.stderr.write("error: notes tree corrupt")
    @sys.exit(1)
  }
  let existing = @git.parse_tree(to.data)
  let entries : Array[@git.TreeEntry] = []
  let mut source_entry : @git.TreeEntry? = None
  let mut dest_exists = false
  for e in existing {
    if e.name == from_hex {
      source_entry = Some(e)
      entries.push(e)
    } else if e.name == to_hex {
      dest_exists = true
      if force {
        // skip existing destination
      } else {
        entries.push(e)
      }
    } else {
      entries.push(e)
    }
  }
  guard source_entry is Some(src) else {
    @stdio.stderr.write("error: no note found for \{from_hex}")
    @sys.exit(1)
  }
  if dest_exists && not(force) {
    @stdio.stderr.write("error: note already exists for \{to_hex}")
    @sys.exit(1)
  }
  entries.push(@git.TreeEntry::new("100644", to_hex, src.id))
  entries.sort_by((a, b) => a.name.compare(b.name))
  let (tree_id, tree_data) = @git.create_tree(entries)
  @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
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
    "Notes copied by 'git notes copy'\n",
  )
  let (new_commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  wfs.mkdir_p(git_dir + "/refs/notes")
  wfs.write_string(notes_ref_path, new_commit_id.to_hex() + "\n")
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
    @stdio.stderr.write("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @git.parse_commit(o.data)
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else {
    @stdio.stderr.write("error: notes tree corrupt")
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
    @stdio.stderr.write("error: no note found for \{target_hex}")
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
    let ref_obj = db.get(rfs, ref_id) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => None
    }
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
async fn load_notes_tree(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
) -> (@git.ObjectId, Array[@git.TreeEntry])? raise Error {
  if not(rfs.is_file(notes_ref_path)) {
    return None
  }
  let ref_content = decode_bytes(rfs.read_file(notes_ref_path))
  let commit_hex = trim_string(ref_content)
  let commit_id = @git.ObjectId::from_hex(commit_hex)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
    return None
  }
  let commit_info = @git.parse_commit(o.data)
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else {
    @stdio.stderr.write("error: notes tree corrupt")
    @sys.exit(1)
    return None
  }
  let entries = @git.parse_tree(to.data)
  Some((commit_id, entries))
}

///|
async fn note_text(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  entry : @git.TreeEntry,
) -> String raise Error {
  let obj = db.get(rfs, entry.id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: note blob corrupt")
    @sys.exit(1)
    return ""
  }
  decode_bytes(o.data)
}

///|
fn merge_notes_union(ours : String, theirs : String) -> String {
  if ours == "" {
    return theirs
  }
  if theirs == "" {
    return ours
  }
  let sep = if ours.has_suffix("\n") { "" } else { "\n" }
  ours + sep + theirs
}

///|
fn join_lines(lines : Array[String]) -> String {
  let mut out = ""
  let mut first = true
  for line in lines {
    if first {
      out = line
      first = false
    } else {
      out = out + "\n" + line
    }
  }
  out
}

///|
fn merge_notes_cat_sort_uniq(ours : String, theirs : String) -> String {
  let lines : Array[String] = []
  for line in split_lines(ours) {
    if line != "" {
      lines.push(line)
    }
  }
  for line in split_lines(theirs) {
    if line != "" {
      lines.push(line)
    }
  }
  if lines.length() == 0 {
    return ""
  }
  lines.sort()
  let uniq : Array[String] = []
  let mut prev : String? = None
  for line in lines {
    match prev {
      Some(p) if p == line => ()
      _ => {
        uniq.push(line)
        prev = Some(line)
      }
    }
  }
  join_lines(uniq)
}

///|
fn split_whitespace_tokens(line : String) -> Array[String] {
  let tokens : Array[String] = []
  let mut current = StringBuilder::new()
  let mut in_token = false
  for c in line {
    if c == ' ' || c == '\t' {
      if in_token {
        tokens.push(current.to_string())
        current = StringBuilder::new()
        in_token = false
      }
    } else {
      current.write_char(c)
      in_token = true
    }
  }
  if in_token {
    tokens.push(current.to_string())
  }
  tokens
}

///|
async fn notes_merge(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
  other_ref_path : String,
  strategy : String?,
) -> Unit raise Error {
  let current = load_notes_tree(rfs, git_dir, notes_ref_path)
  let other = load_notes_tree(rfs, git_dir, other_ref_path)
  guard other is Some((other_commit_id, other_entries)) else {
    @stdio.stderr.write("error: no notes found to merge")
    @sys.exit(1)
  }
  match current {
    None => {
      wfs.mkdir_p(git_dir + "/refs/notes")
      wfs.write_string(notes_ref_path, other_commit_id.to_hex() + "\n")
      return
    }
    Some((current_commit_id, current_entries)) => {
      let db = @gitlib.ObjectDb::load(rfs, git_dir)
      let entries : Map[String, @git.TreeEntry] = Map::new()
      for e in current_entries {
        entries.set(e.name, e)
      }
      let mut conflicts = 0
      for e in other_entries {
        match entries.get(e.name) {
          None => entries.set(e.name, e)
          Some(existing) =>
            if existing.id == e.id {
              ()
            } else if strategy == Some("theirs") {
              entries.set(e.name, e)
            } else if strategy == Some("ours") {
              ()
            } else if strategy == Some("union") {
              let ours = note_text(db, rfs, existing)
              let theirs = note_text(db, rfs, e)
              let merged = merge_notes_union(ours, theirs)
              let merged_content = Bytes::from_array(
                merged.to_array().map(c => c.to_int().to_byte()),
              )
              let merged_id = @gitlib.write_loose_object(
                wfs,
                git_dir,
                @git.ObjectType::Blob,
                merged_content,
              )
              entries.set(
                e.name,
                @git.TreeEntry::new("100644", e.name, merged_id),
              )
            } else if strategy == Some("cat_sort_uniq") {
              let ours = note_text(db, rfs, existing)
              let theirs = note_text(db, rfs, e)
              let merged = merge_notes_cat_sort_uniq(ours, theirs)
              let merged_content = Bytes::from_array(
                merged.to_array().map(c => c.to_int().to_byte()),
              )
              let merged_id = @gitlib.write_loose_object(
                wfs,
                git_dir,
                @git.ObjectType::Blob,
                merged_content,
              )
              entries.set(
                e.name,
                @git.TreeEntry::new("100644", e.name, merged_id),
              )
            } else {
              conflicts += 1
            }
        }
      }
      if conflicts > 0 {
        @stdio.stderr.write("error: notes merge conflict")
        @sys.exit(1)
      }
      let merged_entries : Array[@git.TreeEntry] = []
      entries.each((_k, v) => merged_entries.push(v))
      merged_entries.sort_by((a, b) => a.name.compare(b.name))
      let (tree_id, tree_data) = @git.create_tree(merged_entries)
      @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
      let author = get_author_string()
      let timestamp = get_current_timestamp()
      let current_hex = current_commit_id.to_hex()
      let other_hex = other_commit_id.to_hex()
      let parents = if current_hex == other_hex {
        [current_commit_id]
      } else {
        [current_commit_id, other_commit_id]
      }
      let commit = @git.Commit::new(
        tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000",
        "Notes merged by 'git notes merge'\n",
      )
      let (new_commit_id, commit_data) = @git.create_commit(commit)
      @gitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
      wfs.mkdir_p(git_dir + "/refs/notes")
      wfs.write_string(notes_ref_path, new_commit_id.to_hex() + "\n")
    }
  }
}

///|
async fn notes_rewrite(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  notes_ref_path : String,
  from_ref : String,
  to_ref : String,
  force : Bool,
) -> Unit raise Error {
  let from_id = @gitlib.rev_parse(rfs, git_dir, from_ref)
  guard from_id is Some(fid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{from_ref}")
  }
  let to_id = @gitlib.rev_parse(rfs, git_dir, to_ref)
  guard to_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{to_ref}")
  }
  let from_hex = fid.to_hex()
  let to_hex = tid.to_hex()
  if from_hex == to_hex {
    return
  }
  let current = load_notes_tree(rfs, git_dir, notes_ref_path)
  guard current is Some((current_commit_id, current_entries)) else { return }
  let entries : Map[String, @git.TreeEntry] = Map::new()
  let mut source : @git.TreeEntry? = None
  let mut dest_exists = false
  for e in current_entries {
    if e.name == from_hex {
      source = Some(e)
    } else if e.name == to_hex {
      dest_exists = true
      entries.set(e.name, e)
    } else {
      entries.set(e.name, e)
    }
  }
  guard source is Some(src) else { return }
  if dest_exists && not(force) {
    @stdio.stderr.write("error: note already exists for \{to_hex}")
    @sys.exit(1)
  }
  entries.remove(from_hex)
  entries.set(to_hex, @git.TreeEntry::new("100644", to_hex, src.id))
  let rewritten_entries : Array[@git.TreeEntry] = []
  entries.each((_k, v) => rewritten_entries.push(v))
  rewritten_entries.sort_by((a, b) => a.name.compare(b.name))
  let (tree_id, tree_data) = @git.create_tree(rewritten_entries)
  @gitlib.write_object_bytes(wfs, git_dir, tree_id, tree_data)
  let author = get_author_string()
  let timestamp = get_current_timestamp()
  let commit = @git.Commit::new(
    tree_id,
    [current_commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "Notes rewritten by 'git notes rewrite'\n",
  )
  let (new_commit_id, commit_data) = @git.create_commit(commit)
  @gitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  wfs.mkdir_p(git_dir + "/refs/notes")
  wfs.write_string(notes_ref_path, new_commit_id.to_hex() + "\n")
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
      @stdio.stderr.write("bisect visualize not implemented")
      @sys.exit(1)
    }
    "replay" => {
      @stdio.stderr.write("bisect replay not implemented")
      @sys.exit(1)
    }
    "run" => {
      @stdio.stderr.write("bisect run not implemented")
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
    @stdio.stderr.write("error: bisect already in progress")
    @stdio.stderr.write("use 'git bisect reset' to abort")
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
    @stdio.stderr.write("error: not in a bisect session")
    @stdio.stderr.write("use 'git bisect start' first")
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
    err if @async.is_cancellation_error(err) => raise err
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
    @stdio.stderr.write("error: not in a bisect session")
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
    err if @async.is_cancellation_error(err) => raise err
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
  let bad_hex = rfs.read_file(bad_path) |> decode_bytes |> trim_string
  let bad_id = @git.ObjectId::from_hex(bad_hex)
  // Read good commits
  let good_commits : Array[@git.ObjectId] = []
  let bisect_entries = (rfs : &@git.RepoFileSystem).readdir(bisect_refs_dir) catch {
    err if @async.is_cancellation_error(err) => raise err
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
    rfs.read_file(bisect_start_path) |> decode_bytes |> trim_string
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
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_log_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_terms_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_expected_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_ancestors_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_names_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  // Clean up refs/bisect
  let entries = (rfs : &@git.RepoFileSystem).readdir(bisect_refs_dir) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => []
  }
  for entry in entries {
    wfs.remove_file(bisect_refs_dir + "/" + entry) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
  }
  wfs.remove_file(bisect_refs_dir) catch {
    err if @async.is_cancellation_error(err) => raise err
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
    @stdio.stderr.write("error: no bisect log found")
    @sys.exit(1)
  }
  let content = decode_bytes(rfs.read_file(bisect_log_path))
  print_line(content)
}

///|
/// Handle git describe command
async fn handle_describe(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  // Parse options
  let mut use_tags = false // --tags: use lightweight tags too
  let mut always = false // --always: show abbreviated commit if no tag
  let mut long_format = false // --long: always use long format
  let mut abbrev = 7 // --abbrev=N: abbreviation length
  let mut commit_ref = "HEAD"
  let mut dirty_mark = ""
  for arg in args {
    match arg {
      "--tags" => use_tags = true
      "--always" => always = true
      "--long" => long_format = true
      "--dirty" => dirty_mark = "-dirty"
      _ if arg.has_prefix("--abbrev=") =>
        abbrev = parse_int(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
      _ if arg.has_prefix("--dirty=") =>
        dirty_mark = String::unsafe_substring(arg, start=8, end=arg.length())
      _ if not(arg.has_prefix("-")) => commit_ref = arg
      _ => ()
    }
  }
  // Resolve target commit
  let target_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  // Get all tags
  let tags = get_all_tags(rfs, git_dir, use_tags)
  if tags.length() == 0 && not(always) {
    @stdio.stderr.write("fatal: No names found, cannot describe anything.")
    @sys.exit(128)
  }
  // Find closest tag using BFS
  let result = find_closest_tag(rfs, git_dir, tid, tags)
  match result {
    Some((tag_name, distance, tag_commit)) => {
      let output = if distance == 0 && not(long_format) {
        tag_name + dirty_mark
      } else {
        let short_sha = String::unsafe_substring(
          tid.to_hex(),
          start=0,
          end=abbrev,
        )
        "\{tag_name}-\{distance}-g\{short_sha}\{dirty_mark}"
      }
      ignore(tag_commit)
      print_line(output)
    }
    None =>
      if always {
        let short_sha = String::unsafe_substring(
          tid.to_hex(),
          start=0,
          end=abbrev,
        )
        print_line(short_sha + dirty_mark)
      } else {
        @stdio.stderr.write(
          "fatal: No tags can describe '\{tid.to_hex()}'.\nTry --always, or create a tag.",
        )
        @sys.exit(128)
      }
  }
}

///|
fn get_all_tags(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  include_lightweight : Bool,
) -> Map[String, @git.ObjectId] raise Error {
  let tags : Map[String, @git.ObjectId] = {}
  let tags_dir = git_dir + "/refs/tags"
  if not(rfs.is_dir(tags_dir)) {
    return tags
  }
  let entries = rfs.readdir(tags_dir) catch { _ => return tags }
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  for entry in entries {
    let tag_path = tags_dir + "/" + entry
    if rfs.is_file(tag_path) {
      let ref_hex = rfs.read_file(tag_path) |> decode_bytes |> trim_string
      let ref_id = @git.ObjectId::from_hex(ref_hex)
      // Check if it's an annotated tag (tag object) or lightweight (commit)
      let obj = db.get(rfs, ref_id)
      match obj {
        Some(o) =>
          if o.obj_type == @git.ObjectType::Tag {
            // Annotated tag - dereference to commit
            let tag_data = decode_bytes(o.data)
            let commit_id = parse_tag_object(tag_data)
            match commit_id {
              Some(cid) => tags[entry] = cid
              None => ()
            }
          } else if o.obj_type == @git.ObjectType::Commit && include_lightweight {
            // Lightweight tag
            tags[entry] = ref_id
          }
        None => ()
      }
    }
  }
  tags
}

///|
fn parse_tag_object(data : String) -> @git.ObjectId? raise Error {
  // Tag object format:
  // object <sha>
  // type commit
  // tag <name>
  // ...
  for line_view in data.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("object ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      return hex |> trim_string |> @git.ObjectId::from_hex |> Some
    }
  }
  None
}

///|
fn find_closest_tag(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  target : @git.ObjectId,
  tags : Map[String, @git.ObjectId],
) -> (String, Int, @git.ObjectId)? raise Error {
  // BFS from target to find closest tag
  // Queue entries: (commit_id, distance)
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let visited : Map[String, Bool] = {}
  let queue : Array[(@git.ObjectId, Int)] = [(target, 0)]
  while queue.length() > 0 {
    // Dequeue from front (FIFO for BFS)
    let (current, distance) = queue[0]
    let new_queue : Array[(@git.ObjectId, Int)] = []
    for i in 1..<queue.length() {
      new_queue.push(queue[i])
    }
    // Clear and refill queue
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
    // Check if this commit has a tag
    for tag_name, tag_commit in tags {
      if tag_commit.to_hex() == hex {
        return Some((tag_name, distance, tag_commit))
      }
    }
    // Add parents to queue
    let obj = db.get(rfs, current)
    match obj {
      Some(o) => {
        let info = @git.parse_commit(o.data)
        for p in info.parents {
          if not(visited.get(p.to_hex()).unwrap_or(false)) {
            queue.push((p, distance + 1))
          }
        }
      }
      None => ()
    }
  }
  None
}

///|
fn parse_int(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
    }
  }
  result
}

///|
/// Handle git format-patch command
async fn handle_format_patch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  // Parse options
  let mut output_dir = "."
  let mut start_number = 1
  let mut numbered = false
  let mut stdout_mode = false
  let mut cover_letter = false
  let revisions : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-o" | "--output-directory" if i + 1 < args.length() => {
        output_dir = args[i + 1]
        i += 2
      }
      "--start-number" if i + 1 < args.length() => {
        start_number = parse_int(args[i + 1])
        i += 2
      }
      "-n" | "--numbered" => {
        numbered = true
        i += 1
      }
      "--stdout" => {
        stdout_mode = true
        i += 1
      }
      "--cover-letter" => {
        cover_letter = true
        i += 1
      }
      _ if arg.has_prefix("-o") => {
        output_dir = String::unsafe_substring(arg, start=2, end=arg.length())
        i += 1
      }
      _ if not(arg.has_prefix("-")) => {
        revisions.push(arg)
        i += 1
      }
      _ => i += 1
    }
  }
  // Parse revision range
  let (base_commit, commits) = parse_format_patch_revisions(
    rfs, git_dir, revisions,
  )
  if commits.length() == 0 {
    @stdio.stderr.write("fatal: no commits specified")
    @sys.exit(128)
  }
  // Create output directory if needed
  if not(stdout_mode) && not(rfs.is_dir(output_dir)) {
    wfs.mkdir_p(output_dir)
  }
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let total = commits.length()
  // Generate cover letter if requested
  if cover_letter && not(stdout_mode) {
    let cover_path = output_dir + "/0000-cover-letter.patch"
    let cover_content = generate_cover_letter(commits.length())
    wfs.write_string(cover_path, cover_content)
    print_line(cover_path)
  }
  // Generate patches
  for idx in 0..<commits.length() {
    let commit_id = commits[idx]
    let patch_num = start_number + idx
    let patch = generate_patch(
      db, rfs, commit_id, base_commit, patch_num, total, numbered,
    )
    if stdout_mode {
      print_line(patch)
      if idx < commits.length() - 1 {
        print_line("--")
      }
    } else {
      let filename = format_patch_filename(
        db, rfs, commit_id, patch_num, total, numbered,
      )
      let patch_path = output_dir + "/" + filename
      wfs.write_string(patch_path, patch)
      print_line(patch_path)
    }
  }
  ignore(base_commit)
}

///|
fn parse_format_patch_revisions(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  revisions : Array[String],
) -> (@git.ObjectId?, Array[@git.ObjectId]) raise Error {
  if revisions.length() == 0 {
    // Default: HEAD~1..HEAD (last commit)
    let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
    guard head is Some(h) else { return (None, []) }
    return (None, [h])
  }
  let rev = revisions[0]
  // Check for range notation
  match rev.find("..") {
    Some(idx) => {
      let base_ref = String::unsafe_substring(rev, start=0, end=idx)
      let end_ref = String::unsafe_substring(
        rev,
        start=idx + 2,
        end=rev.length(),
      )
      let base_id = @gitlib.rev_parse(rfs, git_dir, base_ref)
      let end_id = @gitlib.rev_parse(
        rfs,
        git_dir,
        if end_ref.length() == 0 {
          "HEAD"
        } else {
          end_ref
        },
      )
      guard base_id is Some(bid) && end_id is Some(eid) else {
        return (None, [])
      }
      // Collect commits from end to base
      let commits = collect_commits_in_range(rfs, git_dir, bid, eid)
      (Some(bid), commits)
    }
    None =>
      // Check for -N notation (last N commits)
      if rev.has_prefix("-") {
        let n = parse_int(
          String::unsafe_substring(rev, start=1, end=rev.length()),
        )
        let commits = collect_last_n_commits(rfs, git_dir, n)
        (None, commits)
      } else {
        // Single commit
        let id = @gitlib.rev_parse(rfs, git_dir, rev)
        guard id is Some(cid) else { return (None, []) }
        (None, [cid])
      }
  }
}

///|
fn collect_commits_in_range(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  base : @git.ObjectId,
  end : @git.ObjectId,
) -> Array[@git.ObjectId] raise Error {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let result : Array[@git.ObjectId] = []
  let mut current = end
  let base_hex = base.to_hex()
  while current.to_hex() != base_hex {
    result.push(current)
    let obj = db.get(rfs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data)
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get chronological order
  result.rev_in_place()
  result
}

///|
fn collect_last_n_commits(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  n : Int,
) -> Array[@git.ObjectId] raise Error {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else { return [] }
  let result : Array[@git.ObjectId] = []
  let mut current = h
  for _ in 0..<n {
    result.push(current)
    let obj = db.get(rfs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data)
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  result.rev_in_place()
  result
}

///|
fn generate_cover_letter(num_patches : Int) -> String {
  let sb = StringBuilder::new()
  sb.write_string(
    "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n",
  )
  sb.write_string("Subject: [PATCH 0/")
  sb.write_string(num_patches.to_string())
  sb.write_string("] *** SUBJECT HERE ***\n\n")
  sb.write_string("*** BLURB HERE ***\n\n")
  sb.to_string()
}

///|
fn generate_patch(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  _base : @git.ObjectId?,
  patch_num : Int,
  total : Int,
  numbered : Bool,
) -> String raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("commit not found")
  }
  let commit_text = decode_bytes(o.data)
  let info = @git.parse_commit(o.data)
  // Extract commit details
  let author_line = extract_author_line(commit_text)
  let message = extract_commit_message(o.data)
  let subject = get_first_line(message)
  let body = get_rest_lines(message)
  // Build patch header
  let sb = StringBuilder::new()
  sb.write_string("From ")
  sb.write_string(commit_id.to_hex())
  sb.write_string(" Mon Sep 17 00:00:00 2001\n")
  sb.write_string("From: ")
  sb.write_string(author_line)
  sb.write_string("\n")
  // Date from author line
  let (_, author_time, author_tz) = parse_author_info(author_line)
  sb.write_string("Date: ")
  sb.write_string(format_email_date(author_time, author_tz))
  sb.write_string("\n")
  // Subject
  sb.write_string("Subject: ")
  if numbered || total > 1 {
    sb.write_string("[PATCH ")
    sb.write_string(patch_num.to_string())
    sb.write_string("/")
    sb.write_string(total.to_string())
    sb.write_string("] ")
  }
  sb.write_string(subject)
  sb.write_string("\n\n")
  // Body
  if body.length() > 0 {
    sb.write_string(body)
    sb.write_string("\n")
  }
  sb.write_string("---\n")
  // Generate diff
  let parent_id = if info.parents.length() > 0 {
    Some(info.parents[0])
  } else {
    None
  }
  let diff = generate_commit_diff(db, rfs, commit_id, parent_id)
  sb.write_string(diff)
  sb.write_string("\n-- \n2.47.0 (bit)\n\n")
  sb.to_string()
}

///|
fn format_patch_filename(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  patch_num : Int,
  _total : Int,
  _numbered : Bool,
) -> String raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    return pad_left_zero(patch_num.to_string(), 4) + "-patch.patch"
  }
  let message = extract_commit_message(o.data)
  let subject = get_first_line(message)
  // Sanitize subject for filename
  let sanitized = sanitize_filename(subject)
  let num_str = pad_left_zero(patch_num.to_string(), 4)
  num_str + "-" + sanitized + ".patch"
}

///|
fn sanitize_filename(s : String) -> String {
  let sb = StringBuilder::new()
  let mut last_was_dash = false
  for c in s {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') {
      sb.write_char(c)
      last_was_dash = false
    } else if not(last_was_dash) {
      sb.write_char('-')
      last_was_dash = true
    }
  }
  let result = sb.to_string()
  // Trim trailing dash
  if result.length() > 0 && result[result.length() - 1] == '-' {
    String::unsafe_substring(result, start=0, end=result.length() - 1)
  } else {
    result
  }
}

///|
fn get_first_line(s : String) -> String {
  match s.find("\n") {
    Some(idx) => String::unsafe_substring(s, start=0, end=idx)
    None => s
  }
}

///|
fn get_rest_lines(s : String) -> String {
  match s.find("\n") {
    Some(idx) =>
      trim_string(String::unsafe_substring(s, start=idx + 1, end=s.length()))
    None => ""
  }
}

///|
fn format_email_date(ts : Int64, tz : String) -> String {
  let secs = ts.to_int()
  let days = secs / 86400
  let time_of_day = secs % 86400
  let hours = time_of_day / 3600
  let minutes = time_of_day % 3600 / 60
  let seconds = time_of_day % 60
  let (year, month, day) = days_to_date(days)
  let weekday = (days + 4) % 7 // Jan 1, 1970 was Thursday (4)
  let weekday_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  let month_names = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let wd = weekday_names[weekday]
  let mn = month_names[month - 1]
  "\{wd}, \{day} \{mn} \{year} \{pad_left_zero(hours.to_string(), 2)}:\{pad_left_zero(minutes.to_string(), 2)}:\{pad_left_zero(seconds.to_string(), 2)} \{tz}"
}

///|
fn generate_commit_diff(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  parent_id : @git.ObjectId?,
) -> String raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return "" }
  let info = @git.parse_commit(o.data)
  let tree = info.tree
  let parent_tree = match parent_id {
    Some(pid) => {
      let pobj = db.get(rfs, pid)
      match pobj {
        Some(po) => {
          let pinfo = @git.parse_commit(po.data)
          Some(pinfo.tree)
        }
        None => None
      }
    }
    None => None
  }
  // Generate diff between trees
  diff_trees(db, rfs, parent_tree, tree, "")
}

///|
fn diff_trees(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  old_tree : @git.ObjectId?,
  new_tree : @git.ObjectId,
  prefix : String,
) -> String raise Error {
  let sb = StringBuilder::new()
  let new_entries = get_tree_entries(db, rfs, new_tree)
  let old_entries : Map[String, @git.TreeEntry] = {}
  match old_tree {
    Some(ot) => {
      let entries = get_tree_entries(db, rfs, ot)
      for e in entries {
        old_entries[e.name] = e
      }
    }
    None => ()
  }
  // Check for new/modified files
  for entry in new_entries {
    let path = if prefix.length() > 0 {
      prefix + "/" + entry.name
    } else {
      entry.name
    }
    if entry.mode == "40000" {
      // Directory - recurse
      let old_subtree = match old_entries.get(entry.name) {
        Some(oe) if oe.mode == "40000" => Some(oe.id)
        _ => None
      }
      let sub_diff = diff_trees(db, rfs, old_subtree, entry.id, path)
      sb.write_string(sub_diff)
    } else {
      // File
      match old_entries.get(entry.name) {
        Some(oe) if oe.id.to_hex() != entry.id.to_hex() => {
          // Modified
          let diff = diff_blobs(db, rfs, Some(oe.id), entry.id, path)
          sb.write_string(diff)
        }
        None => {
          // New file
          let diff = diff_blobs(db, rfs, None, entry.id, path)
          sb.write_string(diff)
        }
        _ => ()
      }
    }
  }
  // Check for deleted files
  for name, entry in old_entries {
    if entry.mode != "40000" {
      let mut found = false
      for ne in new_entries {
        if ne.name == name {
          found = true
          break
        }
      }
      if not(found) {
        let path = if prefix.length() > 0 { prefix + "/" + name } else { name }
        let diff = diff_blobs(db, rfs, Some(entry.id), entry.id, path) // Deleted
        sb.write_string(diff)
      }
    }
  }
  sb.to_string()
}

///|
fn get_tree_entries(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.TreeEntry] raise Error {
  let obj = db.get(rfs, tree_id)
  guard obj is Some(o) else { return [] }
  @git.parse_tree(o.data)
}

///|
fn diff_blobs(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  old_id : @git.ObjectId?,
  new_id : @git.ObjectId,
  path : String,
) -> String raise Error {
  let sb = StringBuilder::new()
  let old_content = match old_id {
    Some(oid) => {
      let obj = db.get(rfs, oid)
      match obj {
        Some(o) => decode_bytes(o.data)
        None => ""
      }
    }
    None => ""
  }
  let new_obj = db.get(rfs, new_id)
  let new_content = match new_obj {
    Some(o) => decode_bytes(o.data)
    None => ""
  }
  sb.write_string("diff --git a/")
  sb.write_string(path)
  sb.write_string(" b/")
  sb.write_string(path)
  sb.write_string("\n")
  if old_id is None {
    sb.write_string("new file mode 100644\n")
  }
  sb.write_string("--- ")
  if old_id is Some(_) {
    sb.write_string("a/")
    sb.write_string(path)
  } else {
    sb.write_string("/dev/null")
  }
  sb.write_string("\n+++ b/")
  sb.write_string(path)
  sb.write_string("\n")
  // Simple line-by-line diff
  let old_lines = split_lines(old_content)
  let new_lines = split_lines(new_content)
  sb.write_string("@@ -1,")
  sb.write_string(old_lines.length().to_string())
  sb.write_string(" +1,")
  sb.write_string(new_lines.length().to_string())
  sb.write_string(" @@\n")
  for line in old_lines {
    sb.write_string("-")
    sb.write_string(line)
    sb.write_string("\n")
  }
  for line in new_lines {
    sb.write_string("+")
    sb.write_string(line)
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
/// Handle git shortlog command
async fn handle_shortlog(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  // Parse options
  let mut numbered = false
  let mut summary = false
  let mut email = false
  let mut max_count = -1
  for arg in args {
    match arg {
      "-n" | "--numbered" => numbered = true
      "-s" | "--summary" => summary = true
      "-e" | "--email" => email = true
      _ if arg.has_prefix("-") && not(arg.has_prefix("--")) => {
        // Could be -N for count
        let num_str = String::unsafe_substring(arg, start=1, end=arg.length())
        let n = parse_int(num_str)
        if n > 0 {
          max_count = n
        }
      }
      _ => ()
    }
  }
  // Collect commits and group by author
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let head = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else { return }
  let author_commits : Map[String, Array[String]] = {}
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [h]
  let mut count = 0
  while queue.length() > 0 {
    if max_count > 0 && count >= max_count {
      break
    }
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    count += 1
    let obj = db.get(rfs, cid)
    match obj {
      Some(o) => {
        let commit_text = decode_bytes(o.data)
        let author_line = extract_author_line(commit_text)
        let author_key = if email {
          author_line
        } else {
          // Extract just name
          match author_line.find("<") {
            Some(idx) =>
              trim_string(
                String::unsafe_substring(author_line, start=0, end=idx),
              )
            None => author_line
          }
        }
        let message = extract_commit_message(o.data)
        let subject = get_first_line(message)
        if author_commits.get(author_key) is Some(arr) {
          arr.push(subject)
        } else {
          author_commits[author_key] = [subject]
        }
        let info = @git.parse_commit(o.data)
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
  // Sort authors
  let authors : Array[(String, Array[String])] = []
  for author, commits in author_commits {
    authors.push((author, commits))
  }
  if numbered {
    // Sort by commit count descending
    authors.sort_by((a, b) => b.1.length().compare(a.1.length()))
  } else {
    // Sort alphabetically
    authors.sort_by((a, b) => a.0.compare(b.0))
  }
  // Output
  for entry in authors {
    let (author, commits) = entry
    print_line("\{author} (\{commits.length()}):")
    if not(summary) {
      for commit in commits {
        print_line("      \{commit}")
      }
      print_line("")
    }
  }
}

///|
/// Handle git blame command
async fn handle_blame(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  // Parse options
  let mut long_sha = false
  let mut porcelain = false
  let mut incremental = false
  let mut ignore_whitespace = false
  let mut detect_moves = false
  let mut detect_copies = false
  let mut line_start = 0
  let mut line_end = 0
  let mut commit_ref = "HEAD"
  let mut file_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-l" => {
        long_sha = true
        i += 1
      }
      "--porcelain" | "-p" => {
        porcelain = true
        i += 1
      }
      "--incremental" => {
        incremental = true
        i += 1
      }
      "-w" => {
        ignore_whitespace = true
        i += 1
      }
      "-M" => {
        detect_moves = true
        i += 1
      }
      "-C" => {
        detect_copies = true
        i += 1
      }
      "-L" if i + 1 < args.length() => {
        let range = args[i + 1]
        let parsed = parse_line_range(range)
        line_start = parsed.0
        line_end = parsed.1
        i += 2
      }
      _ if arg.has_prefix("-L") => {
        let range = String::unsafe_substring(arg, start=2, end=arg.length())
        let parsed = parse_line_range(range)
        line_start = parsed.0
        line_end = parsed.1
        i += 1
      }
      _ if not(arg.has_prefix("-")) =>
        // Could be commit ref or file path
        if file_path is None {
          // First positional - check if it looks like a file
          let test_path = root + "/" + arg
          if fs.is_file(test_path) {
            file_path = Some(arg)
          } else {
            commit_ref = arg
          }
          i += 1
        } else {
          i += 1
        }
      "--" => {
        // After -- comes file path
        if i + 1 < args.length() {
          file_path = Some(args[i + 1])
        }
        i += 2
      }
      _ => i += 1
    }
  }
  guard file_path is Some(path) else {
    @stdio.stderr.write("fatal: no file specified")
    @sys.exit(128)
  }
  // Get blame info
  let blame_opts = BlameOptions::new(
    ignore_whitespace, detect_moves, detect_copies,
  )
  let blame_lines = compute_blame_with_opts(
    rfs, git_dir, root, commit_ref, path, blame_opts,
  )
  // Apply line range filter
  let filtered = if line_start > 0 {
    let end_val = if line_end > 0 { line_end } else { blame_lines.length() }
    let end_clamped = if end_val < blame_lines.length() {
      end_val
    } else {
      blame_lines.length()
    }
    let result : Array[BlameLine] = []
    for idx in (line_start - 1)..<end_clamped {
      result.push(blame_lines[idx])
    }
    result
  } else {
    blame_lines
  }
  // Output
  if incremental {
    output_blame_incremental(filtered)
  } else if porcelain {
    output_blame_porcelain(filtered)
  } else {
    output_blame_standard(filtered, long_sha)
  }
}

///|
struct BlameOptions {
  ignore_whitespace : Bool
  detect_moves : Bool
  detect_copies : Bool
}

///|
fn BlameOptions::new(
  ignore_whitespace : Bool,
  detect_moves : Bool,
  detect_copies : Bool,
) -> BlameOptions {
  { ignore_whitespace, detect_moves, detect_copies }
}

///|
struct BlameLine {
  commit_id : @git.ObjectId
  author : String
  author_time : Int64
  author_tz : String
  line_no : Int
  content : String
  is_boundary : Bool
}

///|
fn BlameLine::new(
  commit_id : @git.ObjectId,
  author : String,
  author_time : Int64,
  author_tz : String,
  line_no : Int,
  content : String,
  is_boundary : Bool,
) -> BlameLine {
  { commit_id, author, author_time, author_tz, line_no, content, is_boundary }
}

///|
fn parse_line_range(range : String) -> (Int, Int) {
  // Parse "start,end" format
  match range.find(",") {
    Some(idx) => {
      let start_str = String::unsafe_substring(range, start=0, end=idx)
      let end_str = String::unsafe_substring(
        range,
        start=idx + 1,
        end=range.length(),
      )
      (parse_int(start_str), parse_int(end_str))
    }
    None => (parse_int(range), 0)
  }
}

///|
fn compute_blame_with_opts(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  root : String,
  commit_ref : String,
  file_path : String,
  opts : BlameOptions,
) -> Array[BlameLine] raise Error {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  // Get target commit
  let target_id = @gitlib.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  // Get file content at target commit
  let file_content = get_file_at_commit(db, rfs, tid, file_path)
  guard file_content is Some(content) else {
    raise @git.GitError::InvalidObject("file not found: \{file_path}")
  }
  let lines = split_lines(content)
  if lines.length() == 0 {
    return []
  }
  // Build commit history for this file
  let history = build_file_history(db, rfs, tid, file_path)
  // For -M/-C: also collect other files in commits
  let other_files : Map[String, Array[(String, @git.ObjectId)]] = {}
  if opts.detect_moves || opts.detect_copies {
    collect_other_files(db, rfs, history, file_path, other_files)
  }
  // Attribute each line to a commit
  let result : Array[BlameLine] = []
  for line_idx in 0..<lines.length() {
    let line = lines[line_idx]
    let blame = find_line_origin_with_opts(
      db, rfs, history, file_path, line, line_idx, opts, other_files,
    )
    result.push(
      BlameLine::new(
        blame.0,
        blame.1,
        blame.2,
        blame.3,
        line_idx + 1,
        line,
        blame.4,
      ),
    )
  }
  ignore(root)
  result
}

///|
fn collect_other_files(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  history : Array[@git.ObjectId],
  exclude_path : String,
  result : Map[String, Array[(String, @git.ObjectId)]],
) -> Unit {
  for commit_id in history {
    let obj = db.get(rfs, commit_id) catch { _ => continue }
    guard obj is Some(o) else { continue }
    let info = @git.parse_commit(o.data) catch { _ => continue }
    let files = collect_files_in_tree(db, rfs, info.tree, "") catch {
      _ => continue
    }
    for file_entry in files {
      let (path, blob_id) = file_entry
      if path != exclude_path {
        let hex = commit_id.to_hex()
        match result.get(hex) {
          Some(arr) => arr.push((path, blob_id))
          None => result[hex] = [(path, blob_id)]
        }
      }
    }
  }
}

///|
fn collect_files_in_tree(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
) -> Array[(String, @git.ObjectId)] raise Error {
  let result : Array[(String, @git.ObjectId)] = []
  let tree_obj = db.get(rfs, tree_id)
  guard tree_obj is Some(to) else { return result }
  let entries = @git.parse_tree(to.data)
  for entry in entries {
    let path = if prefix.length() > 0 {
      prefix + "/" + entry.name
    } else {
      entry.name
    }
    if entry.mode.has_prefix("100") {
      // Regular file
      result.push((path, entry.id))
    } else if entry.mode == "40000" {
      // Directory - recurse
      let sub_files = collect_files_in_tree(db, rfs, entry.id, path)
      for f in sub_files {
        result.push(f)
      }
    }
  }
  result
}

///|
fn get_file_at_commit(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  file_path : String,
) -> String? raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return None }
  let info = @git.parse_commit(o.data)
  // Walk tree to find file
  let blob_id = find_blob_in_tree(db, rfs, info.tree, file_path)
  guard blob_id is Some(bid) else { return None }
  let blob = db.get(rfs, bid)
  guard blob is Some(b) else { return None }
  b.data |> decode_bytes |> Some
}

///|
fn find_blob_in_tree(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? raise Error {
  let tree_obj = db.get(rfs, tree_id)
  guard tree_obj is Some(to) else { return None }
  let entries = @git.parse_tree(to.data)
  // Split path into components
  let parts = split_path(path)
  if parts.length() == 0 {
    return None
  }
  let first = parts[0]
  for entry in entries {
    if entry.name == first {
      if parts.length() == 1 {
        // Found the file
        return Some(entry.id)
      } else {
        // Need to traverse subtree
        let rest = join_path(parts, 1)
        return find_blob_in_tree(db, rfs, entry.id, rest)
      }
    }
  }
  None
}

///|
fn split_path(path : String) -> Array[String] {
  let result : Array[String] = []
  let mut start_pos = 0
  for i in 0..<path.length() {
    if path[i] == '/' {
      if i > start_pos {
        result.push(String::unsafe_substring(path, start=start_pos, end=i))
      }
      start_pos = i + 1
    }
  }
  if start_pos < path.length() {
    result.push(
      String::unsafe_substring(path, start=start_pos, end=path.length()),
    )
  }
  result
}

///|
fn join_path(parts : Array[String], start_idx : Int) -> String {
  let result : Array[String] = []
  for i in start_idx..<parts.length() {
    result.push(parts[i])
  }
  result.join("/")
}

///|
fn split_lines(content : String) -> Array[String] {
  let result : Array[String] = []
  for line_view in content.split("\n") {
    result.push(line_view.to_string())
  }
  // Remove trailing empty line if content ends with newline
  if result.length() > 0 && result[result.length() - 1] == "" {
    ignore(result.pop())
  }
  result
}

///|
fn build_file_history(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  start : @git.ObjectId,
  file_path : String,
) -> Array[@git.ObjectId] raise Error {
  // Walk commit history, collecting commits that touch the file
  let result : Array[@git.ObjectId] = []
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [start]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    // Check if file exists at this commit
    let content = get_file_at_commit(db, rfs, cid, file_path)
    if content is Some(_) {
      result.push(cid)
    }
    // Add parents
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
  result
}

///|
fn find_line_origin_with_opts(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  history : Array[@git.ObjectId],
  file_path : String,
  line : String,
  _line_idx : Int,
  opts : BlameOptions,
  other_files : Map[String, Array[(String, @git.ObjectId)]],
) -> (@git.ObjectId, String, Int64, String, Bool) raise Error {
  // Find oldest commit in history that contains this line
  let mut best_commit = history[0]
  let mut is_boundary = false
  let compare_line = if opts.ignore_whitespace {
    normalize_whitespace(line)
  } else {
    line
  }
  for i in 0..<history.length() {
    let commit_id = history[i]
    let content = get_file_at_commit(db, rfs, commit_id, file_path)
    match content {
      Some(c) => {
        let lines = split_lines(c)
        let mut found = false
        for l in lines {
          let compare_l = if opts.ignore_whitespace {
            normalize_whitespace(l)
          } else {
            l
          }
          if compare_l == compare_line {
            found = true
            break
          }
        }
        if found {
          best_commit = commit_id
          // Check if this is the first commit (boundary)
          if i == history.length() - 1 {
            is_boundary = true
          }
        } else {
          // Line doesn't exist in this commit
          // For -M/-C: check other files in this commit
          if opts.detect_moves || opts.detect_copies {
            let hex = commit_id.to_hex()
            match other_files.get(hex) {
              Some(files) =>
                for file_entry in files {
                  let (other_path, blob_id) = file_entry
                  let other_content = get_blob_content(db, rfs, blob_id)
                  match other_content {
                    Some(oc) => {
                      let other_lines = split_lines(oc)
                      for ol in other_lines {
                        let compare_ol = if opts.ignore_whitespace {
                          normalize_whitespace(ol)
                        } else {
                          ol
                        }
                        if compare_ol == compare_line {
                          // Found in another file - attribute to this commit
                          best_commit = commit_id
                          if i == history.length() - 1 {
                            is_boundary = true
                          }
                          break
                        }
                      }
                      ignore(other_path)
                    }
                    None => ()
                  }
                }
              None => ()
            }
          }
          break
        }
      }
      None => break
    }
  }
  // Get commit info - parse author from raw data
  let obj = db.get(rfs, best_commit)
  guard obj is Some(o) else {
    return (best_commit, "unknown", 0L, "+0000", is_boundary)
  }
  // Extract author line from commit object
  let commit_text = decode_bytes(o.data)
  let author_line = extract_author_line(commit_text)
  // Parse author info
  let (author_name, author_time, author_tz) = parse_author_info(author_line)
  (best_commit, author_name, author_time, author_tz, is_boundary)
}

///|
fn normalize_whitespace(s : String) -> String {
  // Collapse all whitespace to single spaces and trim
  let result = StringBuilder::new()
  let mut in_space = true // Start true to trim leading spaces
  for c in s {
    if c == ' ' || c == '\t' {
      if not(in_space) {
        result.write_char(' ')
        in_space = true
      }
    } else {
      result.write_char(c)
      in_space = false
    }
  }
  // Trim trailing space
  let str = result.to_string()
  if str.length() > 0 && str[str.length() - 1] == ' ' {
    String::unsafe_substring(str, start=0, end=str.length() - 1)
  } else {
    str
  }
}

///|
fn get_blob_content(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  blob_id : @git.ObjectId,
) -> String? raise Error {
  let blob = db.get(rfs, blob_id)
  guard blob is Some(b) else { return None }
  b.data |> decode_bytes |> Some
}

///|
fn extract_author_line(commit_text : String) -> String {
  for line_view in commit_text.split("\n") {
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
fn parse_author_info(author : String) -> (String, Int64, String) {
  // Format: "Name <email> timestamp tz"
  match author.rev_find(">") {
    Some(email_end) => {
      let name_part = String::unsafe_substring(
        author,
        start=0,
        end=email_end + 1,
      )
      let name = match name_part.find("<") {
        Some(idx) =>
          trim_string(String::unsafe_substring(name_part, start=0, end=idx))
        None => name_part
      }
      let time_part = String::unsafe_substring(
        author,
        start=email_end + 2,
        end=author.length(),
      )
      // Parse "timestamp tz"
      match time_part.find(" ") {
        Some(space_idx) => {
          let ts_str = String::unsafe_substring(
            time_part,
            start=0,
            end=space_idx,
          )
          let tz = String::unsafe_substring(
            time_part,
            start=space_idx + 1,
            end=time_part.length(),
          )
          let timestamp = ts_str |> trim_string |> parse_int64
          (name, timestamp, trim_string(tz))
        }
        None => (name, 0L, "+0000")
      }
    }
    None => (author, 0L, "+0000")
  }
}

///|
async fn output_blame_standard(
  lines : Array[BlameLine],
  long_sha : Bool,
) -> Unit raise Error {
  // Find max author name length for alignment
  let mut max_author = 0
  for line in lines {
    if line.author.length() > max_author {
      max_author = line.author.length()
    }
  }
  // Find max line number width
  let max_line_no = if lines.length() > 0 {
    lines[lines.length() - 1].line_no
  } else {
    0
  }
  let line_width = int_width(max_line_no)
  for line in lines {
    let sha = if long_sha {
      line.commit_id.to_hex()
    } else {
      let hex = line.commit_id.to_hex()
      String::unsafe_substring(hex, start=0, end=8)
    }
    let prefix = if line.is_boundary { "^" } else { "" }
    let date_str = format_timestamp(line.author_time, line.author_tz)
    let padded_author = pad_right(line.author, max_author)
    let padded_line_no = pad_left(line.line_no.to_string(), line_width)
    print_line(
      "\{prefix}\{sha} (\{padded_author} \{date_str} \{padded_line_no}) \{line.content}",
    )
  }
}

///|
async fn output_blame_porcelain(lines : Array[BlameLine]) -> Unit raise Error {
  for line in lines {
    let sha = line.commit_id.to_hex()
    print_line("\{sha} \{line.line_no} \{line.line_no} 1")
    print_line("author \{line.author}")
    print_line("author-time \{line.author_time}")
    print_line("author-tz \{line.author_tz}")
    if line.is_boundary {
      print_line("boundary")
    }
    print_line("\t\{line.content}")
  }
}

///|
async fn output_blame_incremental(lines : Array[BlameLine]) -> Unit raise Error {
  // Incremental format: each entry is immediately flushed
  // Track which commits we've already output headers for
  let seen_commits : Map[String, Bool] = {}
  for line in lines {
    let sha = line.commit_id.to_hex()
    print_line("\{sha} \{line.line_no} \{line.line_no} 1")
    // Only output full header for first occurrence of each commit
    if not(seen_commits.get(sha).unwrap_or(false)) {
      seen_commits[sha] = true
      print_line("author \{line.author}")
      print_line("author-time \{line.author_time}")
      print_line("author-tz \{line.author_tz}")
      if line.is_boundary {
        print_line("boundary")
      }
    }
    print_line("\t\{line.content}")
  }
}

///|
fn format_timestamp(ts : Int64, tz : String) -> String {
  // Convert Unix timestamp to YYYY-MM-DD HH:MM:SS format
  // Simplified: just output timestamp as date string
  let secs = ts.to_int()
  // Calculate date parts (simplified, assumes UTC)
  let days = secs / 86400
  let time_of_day = secs % 86400
  let hours = time_of_day / 3600
  let minutes = time_of_day % 3600 / 60
  let seconds = time_of_day % 60
  // Calculate year/month/day from days since epoch (1970-01-01)
  let (year, month, day) = days_to_date(days)
  let y = pad_left_zero(year.to_string(), 4)
  let m = pad_left_zero(month.to_string(), 2)
  let d = pad_left_zero(day.to_string(), 2)
  let h = pad_left_zero(hours.to_string(), 2)
  let mi = pad_left_zero(minutes.to_string(), 2)
  let s = pad_left_zero(seconds.to_string(), 2)
  "\{y}-\{m}-\{d} \{h}:\{mi}:\{s} \{tz}"
}

///|
fn pad_left_zero(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let padding = width - s.length()
  let mut result = ""
  for _ in 0..<padding {
    result = result + "0"
  }
  result + s
}

///|
fn days_to_date(days : Int) -> (Int, Int, Int) {
  // Convert days since epoch to (year, month, day)
  let mut remaining = days
  let mut year = 1970
  while true {
    let days_in_year = if is_leap_year(year) { 366 } else { 365 }
    if remaining < days_in_year {
      break
    }
    remaining = remaining - days_in_year
    year = year + 1
  }
  // Now find month and day
  let days_in_months = if is_leap_year(year) {
    [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  } else {
    [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  }
  let mut month = 1
  for m in days_in_months {
    if remaining < m {
      break
    }
    remaining = remaining - m
    month = month + 1
  }
  (year, month, remaining + 1)
}

///|
fn is_leap_year(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
fn int_width(n : Int) -> Int {
  if n == 0 {
    return 1
  }
  let mut width = 0
  let mut val = n
  while val > 0 {
    width = width + 1
    val = val / 10
  }
  width
}

///|
fn pad_left(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let padding = width - s.length()
  let mut result = ""
  for _ in 0..<padding {
    result = result + " "
  }
  result + s
}

///|
fn pad_right(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let padding = width - s.length()
  let mut result = s
  for _ in 0..<padding {
    result = result + " "
  }
  result
}

///|
/// Handle diff for subdir-clone with upstream ref
async fn handle_subdir_diff(
  fs : OsFs,
  _root : String,
  git_dir : String,
  refspec : String,
  subdir_path : String,
  stat_mode : Bool,
  name_only : Bool,
  name_status : Bool,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  print_line("# Comparing with \{refspec} (subdir: \{subdir_path})")
  print_line("")
  // Resolve upstream ref
  let upstream_id = resolve_ref_for_subdir(fs, git_dir, refspec)
  guard upstream_id is Some(uid) else {
    raise @git.GitError::InvalidObject("Cannot resolve ref: \{refspec}")
  }
  // Get local HEAD
  let head_id = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head_id is Some(hid) else {
    raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  // Load object database
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Get upstream subdir tree
  let upstream_tree = get_subdir_tree_from_commit(db, fs, uid, subdir_path) catch {
    err => raise err
  }
  guard upstream_tree is Some(utree) else {
    raise @git.GitError::InvalidObject(
      "Subdirectory not found in upstream: \{subdir_path}",
    )
  }
  // Get local tree (root is the subdir)
  let local_obj = db.get(rfs, hid)
  guard local_obj is Some(lo) else {
    raise @git.GitError::InvalidObject("Cannot read local HEAD")
  }
  let local_info = @git.parse_commit(lo.data) catch { err => raise err }
  let local_tree = local_info.tree
  // Compare trees
  let diffs = compare_trees(db, rfs, utree, local_tree, "")
  if diffs.length() == 0 {
    print_line("No differences with \{refspec}")
    return
  }
  // Output
  if name_only {
    for d in diffs {
      print_line(d.path)
    }
  } else if name_status {
    for d in diffs {
      let status = match d.kind {
        SubdirDiffKind::Added => "A"
        SubdirDiffKind::Modified => "M"
        SubdirDiffKind::Deleted => "D"
      }
      print_line("\{status}\t\{d.path}")
    }
  } else if stat_mode {
    for d in diffs {
      let status = match d.kind {
        SubdirDiffKind::Added => " (new)"
        SubdirDiffKind::Modified => ""
        SubdirDiffKind::Deleted => " (deleted)"
      }
      print_line(" \{d.path}\{status}")
    }
    print_line("")
    print_line(" \{diffs.length()} files changed")
  } else {
    for d in diffs {
      let header = match d.kind {
        SubdirDiffKind::Added => "new file: \{d.path}"
        SubdirDiffKind::Modified => "modified: \{d.path}"
        SubdirDiffKind::Deleted => "deleted: \{d.path}"
      }
      print_line("diff --git a/\{d.path} b/\{d.path}")
      print_line(header)
    }
  }
}

///|
pub(all) enum SubdirDiffKind {
  Added
  Modified
  Deleted
}

///|
struct SubdirDiffEntry {
  path : String
  kind : SubdirDiffKind
}

///|
fn compare_trees(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_a : @git.ObjectId,
  tree_b : @git.ObjectId,
  prefix : String,
) -> Array[SubdirDiffEntry] raise Error {
  let result : Array[SubdirDiffEntry] = []
  // Get entries from both trees
  let entries_a = get_tree_entries(db, rfs, tree_a)
  let entries_b = get_tree_entries(db, rfs, tree_b)
  // Build maps
  let map_a : Map[String, @git.TreeEntry] = {}
  let map_b : Map[String, @git.TreeEntry] = {}
  for e in entries_a {
    map_a[e.name] = e
  }
  for e in entries_b {
    map_b[e.name] = e
  }
  // Find deleted (in A but not in B)
  for e in entries_a {
    let path = if prefix.length() > 0 { prefix + "/" + e.name } else { e.name }
    if not(map_b.contains(e.name)) {
      if e.mode == "40000" || e.mode == "040000" {
        // Recurse into deleted directory
        let sub = compare_trees_deleted(db, rfs, e.id, path)
        for s in sub {
          result.push(s)
        }
      } else {
        result.push({ path, kind: SubdirDiffKind::Deleted })
      }
    }
  }
  // Find added (in B but not in A) and modified
  for e in entries_b {
    let path = if prefix.length() > 0 { prefix + "/" + e.name } else { e.name }
    match map_a.get(e.name) {
      None =>
        if e.mode == "40000" || e.mode == "040000" {
          // Recurse into added directory
          let sub = compare_trees_added(db, rfs, e.id, path)
          for s in sub {
            result.push(s)
          }
        } else {
          result.push({ path, kind: SubdirDiffKind::Added })
        }
      Some(ea) =>
        if e.id.to_hex() != ea.id.to_hex() {
          if (e.mode == "40000" || e.mode == "040000") &&
            (ea.mode == "40000" || ea.mode == "040000") {
            // Both are directories, recurse
            let sub = compare_trees(db, rfs, ea.id, e.id, path)
            for s in sub {
              result.push(s)
            }
          } else {
            result.push({ path, kind: SubdirDiffKind::Modified })
          }
        }
    }
  }
  result
}

///|
fn compare_trees_deleted(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
) -> Array[SubdirDiffEntry] raise Error {
  let result : Array[SubdirDiffEntry] = []
  let entries = get_tree_entries(db, rfs, tree_id)
  for e in entries {
    let path = prefix + "/" + e.name
    if e.mode == "40000" || e.mode == "040000" {
      let sub = compare_trees_deleted(db, rfs, e.id, path)
      for s in sub {
        result.push(s)
      }
    } else {
      result.push({ path, kind: SubdirDiffKind::Deleted })
    }
  }
  result
}

///|
fn compare_trees_added(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
) -> Array[SubdirDiffEntry] raise Error {
  let result : Array[SubdirDiffEntry] = []
  let entries = get_tree_entries(db, rfs, tree_id)
  for e in entries {
    let path = prefix + "/" + e.name
    if e.mode == "40000" || e.mode == "040000" {
      let sub = compare_trees_added(db, rfs, e.id, path)
      for s in sub {
        result.push(s)
      }
    } else {
      result.push({ path, kind: SubdirDiffKind::Added })
    }
  }
  result
}

///|
/// Handle merge for subdir-clone
async fn handle_subdir_merge(
  fs : OsFs,
  root : String,
  git_dir : String,
  refspec : String,
  subdir_path : String,
  message : String?,
) -> Unit raise Error {
  print_line("Merging from upstream (subdir: \{subdir_path})...")
  // Resolve upstream ref
  let upstream_id = resolve_ref_for_subdir(fs, git_dir, refspec) catch {
    err => raise err
  }
  guard upstream_id is Some(uid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{refspec}")
  }
  // Load object database
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Get upstream subdir tree
  let upstream_tree = get_subdir_tree_from_commit(db, fs, uid, subdir_path) catch {
    err => raise err
  }
  guard upstream_tree is Some(utree) else {
    raise @git.GitError::InvalidObject(
      "Subdirectory not found in upstream: \{subdir_path}",
    )
  }
  // Get local HEAD tree
  let rfs : &@git.RepoFileSystem = fs
  let head_id = @gitlib.rev_parse(rfs, git_dir, "HEAD")
  guard head_id is Some(hid) else {
    raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  let local_obj = db.get(rfs, hid)
  guard local_obj is Some(lo) else {
    raise @git.GitError::InvalidObject("Cannot read local HEAD")
  }
  let local_info = @git.parse_commit(lo.data) catch { err => raise err }
  let local_tree = local_info.tree
  // Check if already up to date
  if local_tree.to_hex() == utree.to_hex() {
    print_line("Already up to date.")
    return
  }
  // For simplicity, we replace local tree with upstream subdir tree
  // This is a "theirs" strategy - in a real impl we'd do proper 3-way merge
  print_line("  Applying upstream changes...")
  // Write upstream tree to worktree
  write_subdir_tree_to_worktree(db, fs, utree, root)
  // Create merge commit
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let msg = message.unwrap_or("Merge \{refspec} (subdir: \{subdir_path})")
  // Stage all changes
  let status = @gitlib.status(fs, root)
  let paths_to_add : Array[String] = []
  for p in status.untracked {
    paths_to_add.push(p)
  }
  for p in status.unstaged_modified {
    paths_to_add.push(p)
  }
  for p in status.unstaged_deleted {
    paths_to_add.push(p)
  }
  if paths_to_add.length() > 0 {
    @gitlib.add_paths_async(fs, fs, root, paths_to_add)
  }
  // Commit
  let commit_id = @gitlib.commit(fs, fs, root, msg, author, timestamp)
  let short = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
  print_line("[\{short}] \{msg}")
}

///|
fn write_subdir_tree_to_worktree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  dir : String,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let obj = db.get(rfs, tree_id)
  guard obj is Some(tree_obj) else { return }
  let entries = @git.parse_tree(tree_obj.data) catch { _ => return }
  for entry in entries {
    let path = dir + "/" + entry.name
    if entry.mode == "40000" || entry.mode == "040000" {
      fs.mkdir_p(path) catch {
        _ => ()
      }
      write_subdir_tree_to_worktree(db, fs, entry.id, path) catch {
        _ => ()
      }
    } else {
      let blob_obj = db.get(rfs, entry.id)
      guard blob_obj is Some(blob) else { continue }
      fs.write_file(path, blob.data) catch {
        _ => ()
      }
    }
  }
}
