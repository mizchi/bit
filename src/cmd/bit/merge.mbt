///|
async fn handle_merge(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let root = get_work_root()
  let git_dir = root + "/.git"
  let wfs : &@git.FileSystem = fs
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
      "--message" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" => raise @git.GitError::InvalidObject("option '-m' requires a value")
      "--message" =>
        raise @git.GitError::InvalidObject(
          "option '--message' requires a value",
        )
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
      _ if not(arg.has_prefix("-")) =>
        match target_ref {
          Some(_) =>
            raise @git.GitError::InvalidObject(
              "multiple merge heads are not supported",
            )
          None => target_ref = Some(arg)
        }
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
  let target_id = @gitrepo.rev_parse(fs, git_dir, refspec)
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
        let head = @gitrepo.rev_parse(rfs, git_dir, "HEAD")
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
  let head = @gitrepo.rev_parse(rfs, git_dir, "HEAD")
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
    let head_id = @gitrepo.rev_parse(rfs, git_dir, "HEAD")
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
