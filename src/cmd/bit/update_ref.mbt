///|
async fn handle_update_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  if real_git_delegate_is_available(rfs) && is_reftable_repo(rfs, git_dir) {
    delegate_to_real_git("update-ref", args)
    return ()
  }
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
  let is_bare = is_bare_repo_dir(root)
  let actual_git_dir = git_dir
  let head_target = resolve_symbolic_ref_target(fs, actual_git_dir, "HEAD")
  // Get current timestamp for reflog
  let timestamp = get_current_timestamp()
  let timezone = "+0000"
  let (author, email) = get_author_info(fs, actual_git_dir)
  if delete_mode {
    if positional.length() < 1 {
      raise @git.GitError::InvalidObject("usage: git update-ref -d <refname>")
    }
    let input_refname = positional[0]
    let refname = resolve_update_target_ref(
      fs, actual_git_dir, input_refname, no_deref,
    )
    if not(no_deref) &&
      has_symbolic_ref_cycle(fs, actual_git_dir, input_refname) {
      @stdio.stderr.write(
        "error: cannot lock ref '\{input_refname}': unable to resolve reference '\{input_refname}'",
      )
      @sys.exit(1)
    }
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
    delete_packed_ref_entry(fs, actual_git_dir, refname)
    // Write reflog entry for deletion
    let rfs : &@git.RepoFileSystem = fs
    let wfs : &@git.FileSystem = fs
    let (should_log, _) = @gitrepo.should_log_ref(
      rfs, actual_git_dir, refname, is_bare,
    )
    let should_head_log = should_update_head_reflog(
      input_refname, refname, no_deref, head_target,
    )
    let msg = message.unwrap_or("update-ref: delete")
    if should_log || @gitrepo.reflog_exists(rfs, actual_git_dir, refname) {
      @gitrepo.append_reflog(
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
    if should_head_log {
      @gitrepo.append_reflog(
        wfs,
        rfs,
        actual_git_dir,
        "HEAD",
        old_id,
        @git.ObjectId::zero(),
        author,
        email,
        timestamp,
        timezone,
        msg,
      )
    }
    if refname != "HEAD" {
      @gitrepo.delete_reflog(wfs, rfs, actual_git_dir, refname)
    }
    return ()
  }
  if positional.length() < 2 {
    raise @git.GitError::InvalidObject(
      "usage: git update-ref <refname> <newvalue> [<oldvalue>]",
    )
  }
  let input_refname = positional[0]
  let refname = resolve_update_target_ref(
    fs, actual_git_dir, input_refname, no_deref,
  )
  if not(no_deref) && has_symbolic_ref_cycle(fs, actual_git_dir, input_refname) {
    @stdio.stderr.write(
      "error: cannot lock ref '\{input_refname}': unable to resolve reference '\{input_refname}'",
    )
    @sys.exit(1)
  }
  let new_value = if positional[1] == "@" { "HEAD" } else { positional[1] }
  let old_value : String? = if positional.length() >= 3 {
    Some(positional[2])
  } else {
    None
  }
  let new_id = @git.ObjectId::from_hex(new_value) catch {
    _ =>
      match @gitrepo.rev_parse(fs, actual_git_dir, new_value) {
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
  let (should_log, always) = @gitrepo.should_log_ref(
    rfs, actual_git_dir, refname, is_bare,
  )
  if create_reflog {
    // Create reflog if requested
    @gitrepo.create_reflog(wfs, rfs, actual_git_dir, refname)
  }
  let should_head_log = should_update_head_reflog(
    input_refname, refname, no_deref, head_target,
  )
  if should_log ||
    always ||
    create_reflog ||
    should_head_log ||
    @gitrepo.reflog_exists(rfs, actual_git_dir, refname) {
    let old_id = current_id.unwrap_or(@git.ObjectId::zero())
    let msg = message.unwrap_or("update-ref: updating")
    if should_log ||
      always ||
      create_reflog ||
      @gitrepo.reflog_exists(rfs, actual_git_dir, refname) {
      @gitrepo.append_reflog(
        wfs, rfs, actual_git_dir, refname, old_id, new_id, author, email, timestamp,
        timezone, msg,
      )
    }
    if should_head_log {
      @gitrepo.append_reflog(
        wfs, rfs, actual_git_dir, "HEAD", old_id, new_id, author, email, timestamp,
        timezone, msg,
      )
    }
  }
}

///|
fn resolve_update_target_ref(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
  no_deref : Bool,
) -> String {
  if no_deref {
    return refname
  }
  resolve_symbolic_ref_target(fs, git_dir, refname).unwrap_or(refname)
}

///|
fn resolve_symbolic_ref_target(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> String? {
  let mut current = refname
  let mut depth = 0
  while depth < 8 {
    let ref_path = git_dir + "/" + current
    if not(fs.is_file(ref_path)) {
      return if current == refname { None } else { Some(current) }
    }
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return if current == refname { None } else { Some(current) }
    }
    let line = trim_chars(content, " \t\r\n")
    if not(line.has_prefix("ref: ")) {
      return if current == refname { None } else { Some(current) }
    }
    current = String::unsafe_substring(line, start=5, end=line.length())
    depth += 1
  }
  if current == refname {
    None
  } else {
    Some(current)
  }
}

///|
fn should_update_head_reflog(
  input_refname : String,
  refname : String,
  no_deref : Bool,
  head_target : String?,
) -> Bool {
  if no_deref {
    return false
  }
  if refname == "HEAD" {
    return false
  }
  if input_refname == "HEAD" {
    return true
  }
  match head_target {
    Some(head_ref) => head_ref == refname
    None => false
  }
}

///|
fn delete_packed_ref_entry(
  fs : OsFs,
  git_dir : String,
  refname : String,
) -> Unit raise Error {
  let packed_refs_path = git_dir + "/packed-refs"
  if not(fs.is_file(packed_refs_path)) {
    return ()
  }
  let content = decode_bytes(fs.read_file(packed_refs_path)) catch {
    _ => return ()
  }
  let lines : Array[String] = []
  let mut removed = false
  let mut skip_peeled = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if skip_peeled && line.has_prefix("^") {
      skip_peeled = false
      removed = true
      continue
    }
    skip_peeled = false
    if line.length() > 0 &&
      not(line.has_prefix("#")) &&
      not(line.has_prefix("^")) {
      let space_idx = line.find(" ")
      match space_idx {
        Some(i) => {
          let packed_ref = String::unsafe_substring(
            line,
            start=i + 1,
            end=line.length(),
          )
          if packed_ref == refname {
            removed = true
            skip_peeled = true
            continue
          }
        }
        None => ()
      }
    }
    lines.push(line)
  }
  if removed {
    fs.write_string(packed_refs_path, lines.join("\n"))
  }
}

///|
fn has_symbolic_ref_cycle(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Bool {
  let visited : Array[String] = []
  let mut current = refname
  let mut depth = 0
  while depth < 16 {
    for prev in visited {
      if prev == current {
        return true
      }
    }
    visited.push(current)
    let ref_path = git_dir + "/" + current
    if not(fs.is_file(ref_path)) {
      return false
    }
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return false
    }
    let line = trim_chars(content, " \t\r\n")
    if not(line.has_prefix("ref: ")) {
      return false
    }
    current = String::unsafe_substring(line, start=5, end=line.length())
    depth += 1
  }
  true
}

///|
fn read_ref_value(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @git.ObjectId? {
  read_ref_value_inner(fs, git_dir, refname, 0)
}

///|
fn read_ref_value_inner(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
  depth : Int,
) -> @git.ObjectId? {
  if depth > 8 {
    return None
  }
  let ref_path = git_dir + "/" + refname
  if fs.is_file(ref_path) {
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return None
    }
    let hex = trim_chars(content, " \t\r\n")
    if hex.has_prefix("ref: ") {
      // Symbolic ref - resolve it
      let target = String::unsafe_substring(hex, start=5, end=hex.length())
      return read_ref_value_inner(fs, git_dir, target, depth + 1)
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
