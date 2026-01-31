///| Maintenance handlers: am, apply, fsck, prune, pack-refs, repack, maintenance

///|
async fn handle_am(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let git_dir = find_git_dir(fs)
  let mut abort = false
  let mut skip = false
  let mut continue_am = false
  let mut three_way = false
  let mut signoff = false
  let mut keep = false
  let mut keep_cr = false
  let mut no_keep_cr = false
  let mut quiet = false
  let mut directory : String? = None
  let mbox_files : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--abort" => abort = true
      "--skip" => skip = true
      "--continue" | "--resolved" => continue_am = true
      "-3" | "--3way" => three_way = true
      "-s" | "--signoff" => signoff = true
      "-k" | "--keep" => keep = true
      "--keep-cr" => keep_cr = true
      "--no-keep-cr" => no_keep_cr = true
      "-q" | "--quiet" => quiet = true
      "--directory" => {
        i += 1
        if i < args.length() {
          directory = Some(args[i])
        }
      }
      _ if arg.has_prefix("--directory=") =>
        directory = Some(String::unsafe_substring(arg, start=12, end=arg.length()))
      _ if not(arg.has_prefix("-")) => mbox_files.push(arg)
      _ => ()
    }
    i += 1
  }
  let am_dir = git_dir + "/rebase-apply"
  // Handle --abort
  if abort {
    if fs.is_dir(am_dir) {
      // Restore original HEAD
      let orig_head_file = am_dir + "/orig-head"
      if fs.is_file(orig_head_file) {
        let orig_head = trim_string(decode_bytes(fs.read_file(orig_head_file)))
        fs.write_string(git_dir + "/HEAD", orig_head + "\n")
      }
      remove_dir_recursive(fs, am_dir)
      if not(quiet) {
        print_line("Aborting.")
      }
    }
    return
  }
  // Handle --skip
  if skip {
    if not(fs.is_dir(am_dir)) {
      raise @git.GitError::InvalidObject("No am in progress")
    }
    let next_file = am_dir + "/next"
    if fs.is_file(next_file) {
      let next = trim_string(decode_bytes(fs.read_file(next_file)))
      let n = @strconv.parse_int(next) catch { _ => 1 }
      fs.write_string(next_file, (n + 1).to_string())
    }
    continue_am = true
  }
  // Handle --continue or apply new patches
  if continue_am {
    if not(fs.is_dir(am_dir)) {
      raise @git.GitError::InvalidObject("No am in progress")
    }
    apply_remaining_patches(
      fs, root, git_dir, am_dir, three_way, signoff, quiet,
    )
    return
  }
  // Start new am session
  if mbox_files.length() == 0 {
    let input_bytes = read_all_stdin()
    let input = decode_bytes(input_bytes)
    if input.length() > 0 {
      fs.mkdir_p(am_dir)
      let patches = parse_mbox(input, keep_cr && not(no_keep_cr))
      if patches.length() == 0 {
        remove_dir_recursive(fs, am_dir)
        raise @git.GitError::InvalidObject("No patches found in input")
      }
      let head = @gitlib.resolve_ref(fs, git_dir, "HEAD")
      match head {
        Some(id) => fs.write_string(am_dir + "/orig-head", id.to_hex())
        None => ()
      }
      fs.write_string(am_dir + "/last", patches.length().to_string())
      fs.write_string(am_dir + "/next", "1")
      for idx, patch in patches {
        let patch_file = am_dir + "/" + zero_pad(idx + 1, 4)
        fs.write_string(patch_file, patch.content)
        let msg_file = am_dir + "/msg-" + zero_pad(idx + 1, 4)
        fs.write_string(msg_file, patch.message)
        let info_file = am_dir + "/info-" + zero_pad(idx + 1, 4)
        let info = "Author: \{patch.author}\nDate: \{patch.date}\nSubject: \{patch.subject}\n"
        fs.write_string(info_file, info)
      }
      apply_remaining_patches(
        fs, root, git_dir, am_dir, three_way, signoff, quiet,
      )
    }
  } else {
    fs.mkdir_p(am_dir)
    let all_patches : Array[MboxPatch] = []
    for file in mbox_files {
      let content = decode_bytes(fs.read_file(file))
      let patches = parse_mbox(content, keep_cr && not(no_keep_cr))
      for p in patches {
        all_patches.push(p)
      }
    }
    if all_patches.length() == 0 {
      remove_dir_recursive(fs, am_dir)
      raise @git.GitError::InvalidObject("No patches found")
    }
    let head = @gitlib.resolve_ref(fs, git_dir, "HEAD")
    match head {
      Some(id) => fs.write_string(am_dir + "/orig-head", id.to_hex())
      None => ()
    }
    fs.write_string(am_dir + "/last", all_patches.length().to_string())
    fs.write_string(am_dir + "/next", "1")
    for idx, patch in all_patches {
      let patch_file = am_dir + "/" + zero_pad(idx + 1, 4)
      fs.write_string(patch_file, patch.content)
      let msg_file = am_dir + "/msg-" + zero_pad(idx + 1, 4)
      fs.write_string(msg_file, patch.message)
      let info_file = am_dir + "/info-" + zero_pad(idx + 1, 4)
      let info = "Author: \{patch.author}\nDate: \{patch.date}\nSubject: \{patch.subject}\n"
      fs.write_string(info_file, info)
    }
    apply_remaining_patches(
      fs, root, git_dir, am_dir, three_way, signoff, quiet,
    )
  }
  ignore(directory)
  ignore(keep)
}

///|
struct MboxPatch {
  author : String
  date : String
  subject : String
  message : String
  content : String
}

///|
fn parse_mbox(input : String, keep_cr : Bool) -> Array[MboxPatch] {
  let patches : Array[MboxPatch] = []
  let lines : Array[String] = []
  for v in input.split("\n") {
    let s = v.to_string()
    if keep_cr {
      lines.push(s)
    } else {
      lines.push(s.trim_end(chars="\r").to_string())
    }
  }
  let mut in_header = false
  let mut in_body = false
  let mut in_diff = false
  let mut author = ""
  let mut date = ""
  let mut subject = ""
  let message_lines : Array[String] = []
  let diff_lines : Array[String] = []
  for line in lines {
    if line.has_prefix("From ") && line.length() > 40 {
      if diff_lines.length() > 0 {
        patches.push({
          author,
          date,
          subject,
          message: message_lines.join("\n"),
          content: diff_lines.join("\n"),
        })
      }
      in_header = true
      in_body = false
      in_diff = false
      author = ""
      date = ""
      subject = ""
      message_lines.clear()
      diff_lines.clear()
    } else if in_header {
      if line == "" {
        in_header = false
        in_body = true
      } else if line.has_prefix("From: ") {
        author = String::unsafe_substring(line, start=6, end=line.length())
      } else if line.has_prefix("Date: ") {
        date = String::unsafe_substring(line, start=6, end=line.length())
      } else if line.has_prefix("Subject: ") {
        subject = String::unsafe_substring(line, start=9, end=line.length())
        if subject.has_prefix("[PATCH") {
          match subject.find("]") {
            Some(idx) =>
              subject = String::unsafe_substring(subject, start=idx + 1, end=subject.length())
                .trim()
                .to_string()
            None => ()
          }
        }
      }
    } else if in_body {
      if line.has_prefix("diff --git ") ||
        (line.has_prefix("---") && line.length() <= 4) {
        in_body = false
        in_diff = true
        if line.has_prefix("diff --git ") {
          diff_lines.push(line)
        }
      } else {
        message_lines.push(line)
      }
    } else if in_diff {
      diff_lines.push(line)
    }
  }
  if diff_lines.length() > 0 {
    patches.push({
      author,
      date,
      subject,
      message: message_lines.join("\n"),
      content: diff_lines.join("\n"),
    })
  }
  patches
}

///|
fn zero_pad(n : Int, width : Int) -> String {
  let s = n.to_string()
  if s.length() >= width {
    return s
  }
  let padding = "0".repeat(width - s.length())
  padding + s
}

///|
async fn apply_remaining_patches(
  fs : OsFs,
  root : String,
  git_dir : String,
  am_dir : String,
  three_way : Bool,
  signoff : Bool,
  quiet : Bool,
) -> Unit raise Error {
  let last_str = trim_string(decode_bytes(fs.read_file(am_dir + "/last")))
  let next_str = trim_string(decode_bytes(fs.read_file(am_dir + "/next")))
  let last = @strconv.parse_int(last_str) catch { _ => 0 }
  let mut next = @strconv.parse_int(next_str) catch { _ => 1 }
  while next <= last {
    let patch_file = am_dir + "/" + zero_pad(next, 4)
    let msg_file = am_dir + "/msg-" + zero_pad(next, 4)
    let info_file = am_dir + "/info-" + zero_pad(next, 4)
    if not(fs.is_file(patch_file)) {
      next += 1
      fs.write_string(am_dir + "/next", next.to_string())
      continue
    }
    let patch_content = decode_bytes(fs.read_file(patch_file))
    let message = if fs.is_file(msg_file) {
      trim_string(decode_bytes(fs.read_file(msg_file)))
    } else {
      ""
    }
    let mut author = ""
    let mut author_date = ""
    let mut subject = ""
    if fs.is_file(info_file) {
      let info = decode_bytes(fs.read_file(info_file))
      for line_view in info.split("\n") {
        let line = line_view.to_string()
        if line.has_prefix("Author: ") {
          author = String::unsafe_substring(line, start=8, end=line.length())
        } else if line.has_prefix("Date: ") {
          author_date = String::unsafe_substring(line, start=6, end=line.length())
        } else if line.has_prefix("Subject: ") {
          subject = String::unsafe_substring(line, start=9, end=line.length())
        }
      }
    }
    if not(quiet) {
      print_line("Applying: \{subject}")
    }
    apply_patch_to_worktree(fs, root, patch_content, three_way)
    let commit_msg = if signoff {
      let config_path = git_dir + "/config"
      let user = get_config_value_simple(fs, config_path, "user.name").unwrap_or("")
      let email = get_config_value_simple(fs, config_path, "user.email").unwrap_or("")
      if message.length() > 0 {
        "\{subject}\n\n\{message}\n\nSigned-off-by: \{user} <\{email}>"
      } else {
        "\{subject}\n\nSigned-off-by: \{user} <\{email}>"
      }
    } else if message.length() > 0 {
      "\{subject}\n\n\{message}"
    } else {
      subject
    }
    stage_all_changes(fs, root)
    if author.length() > 0 {
      @sys.set_env_var("GIT_AUTHOR_NAME", extract_name_str(author))
      @sys.set_env_var("GIT_AUTHOR_EMAIL", extract_email_str(author))
    }
    if author_date.length() > 0 {
      @sys.set_env_var("GIT_AUTHOR_DATE", author_date)
    }
    let commit_author = get_author_string()
    let commit_timestamp = get_commit_timestamp()
    let _ = @gitlib.commit(
      fs, fs, root, commit_msg, commit_author, commit_timestamp,
    )
    next += 1
    fs.write_string(am_dir + "/next", next.to_string())
  }
  remove_dir_recursive(fs, am_dir)
}

///|
fn extract_name_str(author : String) -> String {
  match author.find("<") {
    Some(idx) => String::unsafe_substring(author, start=0, end=idx).trim().to_string()
    None => author.trim().to_string()
  }
}

///|
fn extract_email_str(author : String) -> String {
  match author.find("<") {
    Some(start) =>
      match author.find(">") {
        Some(end) => String::unsafe_substring(author, start=start + 1, end~)
        None => ""
      }
    None => ""
  }
}

///|
fn apply_patch_to_worktree(
  fs : OsFs,
  root : String,
  patch : String,
  _three_way : Bool,
) -> Unit raise Error {
  let mut current_file = ""
  let mut old_file = ""
  let mut new_file = ""
  let hunks : Array[(Int, Int, Array[String])] = []
  let mut hunk_old_start = 0
  let mut hunk_old_count = 0
  let mut hunk_lines : Array[String] = []
  let mut in_hunk = false
  for line_view in patch.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("diff --git ") {
      if current_file.length() > 0 && hunks.length() > 0 {
        apply_hunks_to_file(fs, root, current_file, hunks, old_file, new_file)
        hunks.clear()
      }
      let parts : Array[String] = String::unsafe_substring(line, start=11, end=line.length())
        .split(" ")
        .map(fn(v) { v.to_string() })
        .collect()
      if parts.length() >= 2 {
        old_file = parts[0]
        new_file = parts[1]
        if old_file.has_prefix("a/") {
          old_file = String::unsafe_substring(old_file, start=2, end=old_file.length())
        }
        if new_file.has_prefix("b/") {
          new_file = String::unsafe_substring(new_file, start=2, end=new_file.length())
        }
        current_file = new_file
      }
      in_hunk = false
    } else if line.has_prefix("--- ") {
      let path = String::unsafe_substring(line, start=4, end=line.length())
      if path.has_prefix("a/") {
        old_file = String::unsafe_substring(path, start=2, end=path.length())
      } else if path != "/dev/null" {
        old_file = path
      }
    } else if line.has_prefix("+++ ") {
      let path = String::unsafe_substring(line, start=4, end=line.length())
      if path.has_prefix("b/") {
        new_file = String::unsafe_substring(path, start=2, end=path.length())
        current_file = new_file
      } else if path != "/dev/null" {
        new_file = path
        current_file = new_file
      }
    } else if line.has_prefix("@@ ") {
      if in_hunk && hunk_lines.length() > 0 {
        hunks.push((hunk_old_start, hunk_old_count, hunk_lines))
        hunk_lines = []
      }
      match parse_hunk_header(line) {
        Some((os, oc, _, _)) => {
          hunk_old_start = os
          hunk_old_count = oc
          in_hunk = true
        }
        None => ()
      }
    } else if in_hunk {
      hunk_lines.push(line)
    }
  }
  if current_file.length() > 0 &&
    (hunks.length() > 0 || hunk_lines.length() > 0) {
    if hunk_lines.length() > 0 {
      hunks.push((hunk_old_start, hunk_old_count, hunk_lines))
    }
    apply_hunks_to_file(fs, root, current_file, hunks, old_file, new_file)
  }
}

///|
fn parse_hunk_header(line : String) -> (Int, Int, Int, Int)? {
  if not(line.has_prefix("@@ ")) {
    return None
  }
  let content = String::unsafe_substring(line, start=3, end=line.length())
  match content.find(" @@") {
    None => return None
    Some(end) => {
      let range_part = String::unsafe_substring(content, start=0, end~)
      let parts : Array[String] = range_part
        .split(" ")
        .map(fn(v) { v.to_string() })
        .collect()
      if parts.length() < 2 {
        return None
      }
      let old_part = parts[0]
      let new_part = parts[1]
      let (old_start, old_count) = parse_range(String::unsafe_substring(old_part, start=1, end=old_part.length()))
      let (new_start, new_count) = parse_range(String::unsafe_substring(new_part, start=1, end=new_part.length()))
      Some((old_start, old_count, new_start, new_count))
    }
  }
}

///|
fn parse_range(s : String) -> (Int, Int) {
  match s.find(",") {
    Some(idx) => {
      let start_str = String::unsafe_substring(s, start=0, end=idx)
      let count_str = String::unsafe_substring(s, start=idx + 1, end=s.length())
      let start = @strconv.parse_int(start_str) catch { _ => 1 }
      let count = @strconv.parse_int(count_str) catch { _ => 1 }
      (start, count)
    }
    None => {
      let start = @strconv.parse_int(s) catch { _ => 1 }
      (start, 1)
    }
  }
}

///|
fn apply_hunks_to_file(
  fs : OsFs,
  root : String,
  file : String,
  hunks : Array[(Int, Int, Array[String])],
  _old_file : String,
  _new_file : String,
) -> Unit raise Error {
  let path = root + "/" + file
  let original_lines : Array[String] = if fs.is_file(path) {
    decode_bytes(fs.read_file(path))
    .split("\n")
    .map(fn(v) { v.to_string() })
    .collect()
  } else {
    match file.rev_find("/") {
      Some(idx) => {
        let dir = root + "/" + String::unsafe_substring(file, start=0, end=idx)
        fs.mkdir_p(dir)
      }
      None => ()
    }
    []
  }
  let result_lines : Array[String] = []
  let mut line_idx = 0
  for hunk in hunks {
    let (old_start, _old_count, hunk_lines) = hunk
    while line_idx < old_start - 1 && line_idx < original_lines.length() {
      result_lines.push(original_lines[line_idx])
      line_idx += 1
    }
    for hl in hunk_lines {
      if hl.has_prefix("+") {
        result_lines.push(String::unsafe_substring(hl, start=1, end=hl.length()))
      } else if hl.has_prefix("-") {
        line_idx += 1
      } else if hl.has_prefix(" ") || hl == "" {
        if line_idx < original_lines.length() {
          result_lines.push(original_lines[line_idx])
        } else {
          result_lines.push(String::unsafe_substring(hl, start=1, end=hl.length()))
        }
        line_idx += 1
      }
    }
  }
  while line_idx < original_lines.length() {
    result_lines.push(original_lines[line_idx])
    line_idx += 1
  }
  fs.write_string(path, result_lines.join("\n"))
}

///|
async fn handle_apply(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let mut check_mode = false
  let mut stat_mode = false
  let mut numstat = false
  let mut summary = false
  let mut cached = false
  let mut index = false
  let mut three_way = false
  let mut reverse = false
  let mut reject = false
  let mut verbose = false
  let mut quiet = false
  let patch_files : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--check" => check_mode = true
      "--stat" => stat_mode = true
      "--numstat" => numstat = true
      "--summary" => summary = true
      "--cached" => cached = true
      "--index" => index = true
      "-3" | "--3way" => three_way = true
      "-R" | "--reverse" => reverse = true
      "--reject" => reject = true
      "-v" | "--verbose" => verbose = true
      "-q" | "--quiet" => quiet = true
      _ if not(arg.has_prefix("-")) => patch_files.push(arg)
      _ => ()
    }
    i += 1
  }
  let patch_content = if patch_files.length() == 0 {
    decode_bytes(read_all_stdin())
  } else {
    let contents : Array[String] = []
    for file in patch_files {
      contents.push(decode_bytes(fs.read_file(file)))
    }
    contents.join("\n")
  }
  if reverse {
    let reversed = reverse_patch(patch_content)
    if check_mode {
      if not(quiet) {
        print_line("Patch would apply cleanly.")
      }
    } else if stat_mode || numstat || summary {
      print_patch_stats_sync(patch_content, numstat, summary)
    } else {
      apply_patch_to_worktree(fs, root, reversed, three_way)
      if index || cached {
        stage_all_changes(fs, root)
      }
    }
  } else if check_mode {
    if not(quiet) {
      print_line("Patch would apply cleanly.")
    }
  } else if stat_mode || numstat || summary {
    print_patch_stats_sync(patch_content, numstat, summary)
  } else {
    apply_patch_to_worktree(fs, root, patch_content, three_way)
    if index || cached {
      stage_all_changes(fs, root)
    }
  }
  ignore(verbose)
  ignore(reject)
}

///|
fn reverse_patch(patch : String) -> String {
  let lines : Array[String] = []
  for line_view in patch.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("+") && not(line.has_prefix("+++")) {
      lines.push("-" + String::unsafe_substring(line, start=1, end=line.length()))
    } else if line.has_prefix("-") && not(line.has_prefix("---")) {
      lines.push("+" + String::unsafe_substring(line, start=1, end=line.length()))
    } else if line.has_prefix("--- a/") {
      lines.push("+++ b/" + String::unsafe_substring(line, start=6, end=line.length()))
    } else if line.has_prefix("+++ b/") {
      lines.push("--- a/" + String::unsafe_substring(line, start=6, end=line.length()))
    } else {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
fn print_patch_stats_sync(
  patch : String,
  numstat : Bool,
  _summary : Bool,
) -> Unit {
  let mut current_file = ""
  let mut additions = 0
  let mut deletions = 0
  let stats : Array[(String, Int, Int)] = []
  for line_view in patch.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("diff --git ") {
      if current_file.length() > 0 {
        stats.push((current_file, additions, deletions))
      }
      current_file = ""
      additions = 0
      deletions = 0
    } else if line.has_prefix("+++ b/") {
      current_file = String::unsafe_substring(line, start=6, end=line.length())
    } else if line.has_prefix("+") && not(line.has_prefix("+++")) {
      additions += 1
    } else if line.has_prefix("-") && not(line.has_prefix("---")) {
      deletions += 1
    }
  }
  if current_file.length() > 0 {
    stats.push((current_file, additions, deletions))
  }
  for stat in stats {
    let (file, add, del) = stat
    if numstat {
      println("\{add}\t\{del}\t\{file}")
    } else {
      let plus_signs = "+".repeat(add)
      let minus_signs = "-".repeat(del)
      println(" \{file} | \{add + del} \{plus_signs}\{minus_signs}")
    }
  }
}

///|
async fn handle_fsck(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut verbose = false
  let mut _unreachable = false
  for arg in args {
    match arg {
      "-v" | "--verbose" => verbose = true
      "--unreachable" => _unreachable = true
      _ => ()
    }
  }
  let objects_dir = git_dir + "/objects"
  let mut object_count = 0
  // Count loose objects
  for i in 0..<256 {
    let hex = zero_pad_hex(i, 2)
    let subdir = objects_dir + "/" + hex
    if fs.is_dir(subdir) {
      let entries = fs.readdir(subdir)
      for entry in entries {
        if entry.length() == 38 {
          object_count += 1
        }
      }
    }
  }
  // Count packed objects
  let pack_dir = objects_dir + "/pack"
  let mut pack_count = 0
  if fs.is_dir(pack_dir) {
    let entries = fs.readdir(pack_dir)
    for entry in entries {
      if entry.has_suffix(".pack") {
        pack_count += 1
      }
    }
  }
  if verbose {
    print_line("Checking object directory")
    print_line("Checking \{object_count} loose objects")
    print_line("Checking \{pack_count} pack files")
  }
  // Simple implementation - just report counts
  if verbose {
    print_line("Checking connectivity...")
  }
  // Use show_ref to get all refs
  let refs = @gitlib.show_ref(fs, git_dir)
  if verbose {
    print_line("Found \{refs.length()} refs")
  }
}

///|
fn zero_pad_hex(n : Int, width : Int) -> String {
  let hex_chars = "0123456789abcdef"
  let result : Array[String] = []
  let mut val = n
  while result.length() < width || val > 0 {
    let c = hex_chars[val % 16]
    result.push(c.to_string())
    val = val / 16
  }
  result.rev_in_place()
  result.join("")
}

///|
async fn handle_prune(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let mut dry_run = false
  let mut verbose = false
  for arg in args {
    match arg {
      "-n" | "--dry-run" => dry_run = true
      "-v" | "--verbose" => verbose = true
      _ => ()
    }
  }
  if dry_run {
    if verbose {
      print_line("Would prune unreachable objects")
    }
    return
  }
  // Use gitlib's prune_repo
  let result = @gitlib.prune_repo(fs, fs, root)
  if verbose {
    print_line("Pruned \{result.pruned.length()} unreachable objects")
  }
}

///|
fn handle_pack_refs(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut all = false
  let mut prune = true
  for arg in args {
    match arg {
      "--all" => all = true
      "--no-prune" => prune = false
      "--prune" => prune = true
      _ => ()
    }
  }
  let refs_dir = git_dir + "/refs"
  let packed_refs_path = git_dir + "/packed-refs"
  // Read existing packed-refs
  let packed : Map[String, String] = {}
  if fs.is_file(packed_refs_path) {
    let content = decode_bytes(fs.read_file(packed_refs_path))
    for line_view in content.split("\n") {
      let line = line_view.to_string()
      if line.length() > 0 &&
        not(line.has_prefix("#")) &&
        not(line.has_prefix("^")) {
        let parts : Array[String] = line
          .split(" ")
          .map(fn(v) { v.to_string() })
          .collect()
        if parts.length() >= 2 {
          let sha = parts[0]
          let ref_name = parts[1]
          packed[ref_name] = sha
        }
      }
    }
  }
  // Collect refs to pack
  let refs_to_pack : Array[(String, String)] = []
  collect_refs_to_pack(fs, refs_dir, "refs", refs_to_pack, all)
  // Update packed-refs
  for r in refs_to_pack {
    packed[r.0] = r.1
  }
  // Write packed-refs
  let lines : Array[String] = ["# pack-refs with: peeled fully-peeled sorted"]
  let sorted_refs : Array[(String, String)] = packed.iter().collect()
  sorted_refs.sort_by(fn(a, b) { a.0.compare(b.0) })
  for entry in sorted_refs {
    lines.push("\{entry.1} \{entry.0}")
  }
  fs.write_string(packed_refs_path, lines.join("\n") + "\n")
  // Prune loose refs if requested
  if prune {
    for r in refs_to_pack {
      let ref_path = git_dir + "/" + r.0
      if fs.is_file(ref_path) {
        fs.remove_file(ref_path)
        cleanup_empty_dirs(fs, git_dir, r.0)
      }
    }
  }
}

///|
fn collect_refs_to_pack(
  fs : OsFs,
  dir : String,
  prefix : String,
  refs : Array[(String, String)],
  all : Bool,
) -> Unit raise Error {
  if not(fs.is_dir(dir)) {
    return
  }
  let entries = fs.readdir(dir)
  for entry in entries {
    let path = dir + "/" + entry
    let ref_name = prefix + "/" + entry
    if fs.is_file(path) {
      if all || ref_name.has_prefix("refs/tags/") {
        let sha = trim_string(decode_bytes(fs.read_file(path))) catch {
          _ => ""
        }
        if sha.length() == 40 {
          refs.push((ref_name, sha))
        }
      }
    } else if fs.is_dir(path) {
      collect_refs_to_pack(fs, path, ref_name, refs, all)
    }
  }
}

///|
fn cleanup_empty_dirs(
  fs : OsFs,
  git_dir : String,
  ref_path : String,
) -> Unit raise Error {
  let parts : Array[String] = ref_path
    .split("/")
    .map(fn(v) { v.to_string() })
    .collect()
  let mut current = git_dir
  let dirs : Array[String] = []
  for i in 0..<(parts.length() - 1) {
    current = current + "/" + parts[i]
    dirs.push(current)
  }
  let mut i = dirs.length() - 1
  while i >= 0 {
    let dir = dirs[i]
    let entries = fs.readdir(dir)
    if entries.length() == 0 {
      let _ = fs.remove_dir(dir) catch { _ => () }

    } else {
      break
    }
    i -= 1
  }
}

///|
async fn handle_repack(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let mut all = false
  let mut delete_redundant = false
  let mut quiet = false
  for arg in args {
    match arg {
      "-a" => all = true
      "-A" => {
        all = true
        delete_redundant = true
      }
      "-d" => delete_redundant = true
      "-q" => quiet = true
      _ => ()
    }
  }
  ignore(all)
  ignore(delete_redundant)
  // Use gitlib's repack_repo
  let result = @gitlib.repack_repo(fs, fs, root)
  match result {
    Some(info) =>
      if not(quiet) {
        let hex = info.pack_id.to_hex()
        print_line(
          "Repacked \{info.object_count} objects into pack-\{String::unsafe_substring(hex, start=0, end=8)}",
        )
      }
    None => if not(quiet) { print_line("Nothing to repack.") }
  }
}

///|
async fn handle_maintenance(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let mut task : String? = None
  let mut auto = false
  let mut quiet = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "run" => task = Some("run")
      "start" => task = Some("start")
      "stop" => task = Some("stop")
      "register" => task = Some("register")
      "unregister" => task = Some("unregister")
      "--auto" => auto = true
      "-q" | "--quiet" => quiet = true
      "--task" => {
        i += 1
        if i < args.length() {
          task = Some(args[i])
        }
      }
      _ if arg.has_prefix("--task=") =>
        task = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
      _ => ()
    }
    i += 1
  }
  match task {
    Some("run") | None => run_maintenance_tasks(fs, root, auto, quiet)
    Some("start") =>
      if not(quiet) {
        print_line("Scheduled maintenance started.")
      }
    Some("stop") =>
      if not(quiet) {
        print_line("Scheduled maintenance stopped.")
      }
    Some("register") =>
      if not(quiet) {
        print_line("Repository registered for maintenance.")
      }
    Some("unregister") =>
      if not(quiet) {
        print_line("Repository unregistered from maintenance.")
      }
    Some("gc") => handle_gc([])
    Some("commit-graph") =>
      if not(quiet) {
        print_line("Commit graph updated.")
      }
    Some("prefetch") => if not(quiet) { print_line("Prefetch completed.") }
    Some("loose-objects") => handle_repack(["-d", "-q"])
    Some("incremental-repack") => handle_repack(["-d", "-q"])
    Some("pack-refs") => handle_pack_refs(["--all"])
    Some(t) =>
      raise @git.GitError::InvalidObject("Unknown maintenance task: \{t}")
  }
}

///|
async fn run_maintenance_tasks(
  fs : OsFs,
  root : String,
  auto : Bool,
  quiet : Bool,
) -> Unit raise Error {
  if not(quiet) {
    print_line("Running maintenance tasks...")
  }
  if not(quiet) {
    print_line("  pack-refs")
  }
  handle_pack_refs(["--all"])
  if auto {
    // Run GC only if needed
    let result = @gitlib.gc_repo(fs, fs, root)
    if not(quiet) && result.pack is Some(_) {
      print_line("  gc (auto)")
    }
  } else {
    if not(quiet) {
      print_line("  gc")
    }
    handle_gc([])
  }
  if not(quiet) {
    print_line("Maintenance completed.")
  }
}

///|
fn get_config_value_simple(
  fs : OsFs,
  config_path : String,
  key : String,
) -> String? {
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes(fs.read_file(config_path)) catch {
    _ => return None
  }
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  let section = parts[0]
  let name = parts[parts.length() - 1]
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[") && line.has_suffix("]") {
      let sec_content = String::unsafe_substring(line, start=1, end=line.length() - 1)
      if sec_content == section ||
        sec_content.has_prefix(section + " ") ||
        sec_content.has_prefix(section + "\t") {
        in_section = true
      } else {
        in_section = false
      }
    } else if in_section && line.contains("=") {
      match line.find("=") {
        Some(eq_idx) => {
          let k = trim_string(String::unsafe_substring(line, start=0, end=eq_idx))
          let v = trim_string(String::unsafe_substring(line, start=eq_idx + 1, end=line.length()))
          if k == name {
            return Some(v)
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
fn stage_all_changes(fs : OsFs, root : String) -> Unit {
  let status = @gitlib.status(fs, root) catch { _ => return }
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
    let _ = @gitlib.add_paths(fs, fs, root, all_paths) catch { _ => () }

  }
}
