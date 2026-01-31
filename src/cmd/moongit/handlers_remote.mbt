///| Remote operation handlers: remote, upload-pack, receive-pack, fetch, pull, push, clone

///|
async fn handle_remote(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args.length() == 0 {
    // List remotes
    let remotes = list_remotes(fs, git_dir)
    for name in remotes {
      print_line(name)
    }
    return ()
  }
  let subcmd = args[0]
  match subcmd {
    "add" => {
      if args.length() < 3 {
        raise @git.GitError::InvalidObject("usage: git remote add <name> <url>")
      }
      let name = args[1]
      let url = args[2]
      remote_add(fs, fs, git_dir, name, url)
      print_line("Added remote '\{name}'")
    }
    "remove" | "rm" => {
      if args.length() < 2 {
        raise @git.GitError::InvalidObject("usage: git remote remove <name>")
      }
      let name = args[1]
      remote_remove(fs, fs, git_dir, name)
      print_line("Removed remote '\{name}'")
    }
    "-v" | "--verbose" => {
      // List remotes with URLs
      let remotes = list_remotes_verbose(fs, git_dir)
      for item in remotes {
        let (name, url) = item
        print_line("\{name}\t\{url} (fetch)")
        print_line("\{name}\t\{url} (push)")
      }
    }
    "get-url" => {
      if args.length() < 2 {
        raise @git.GitError::InvalidObject("usage: git remote get-url <name>")
      }
      let name = args[1]
      let url = get_remote_url(fs, git_dir, name)
      match url {
        Some(u) => print_line(u)
        None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
      }
    }
    "set-url" => {
      if args.length() < 3 {
        raise @git.GitError::InvalidObject(
          "usage: git remote set-url <name> <newurl>",
        )
      }
      let name = args[1]
      let url = args[2]
      remote_set_url(fs, fs, git_dir, name, url)
    }
    _ =>
      raise @git.GitError::InvalidObject("Unknown remote subcommand: \{subcmd}")
  }
}

///|
fn list_remotes(fs : &@git.RepoFileSystem, git_dir : String) -> Array[String] {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return []
  }
  let content = decode_bytes(fs.read_file(config_path) catch { _ => return [] })
  let remotes : Array[String] = []
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[remote \"") && line.has_suffix("\"]") {
      let name = String::unsafe_substring(line, start=9, end=line.length() - 2)
      remotes.push(name)
    }
  }
  remotes
}

///|
fn list_remotes_verbose(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[(String, String)] {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return []
  }
  let content = decode_bytes(fs.read_file(config_path) catch { _ => return [] })
  let remotes : Array[(String, String)] = []
  let mut current_remote : String? = None
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[remote \"") && line.has_suffix("\"]") {
      current_remote = Some(
        String::unsafe_substring(line, start=9, end=line.length() - 2),
      )
      continue
    }
    if line.has_prefix("[") {
      current_remote = None
      continue
    }
    match current_remote {
      Some(name) if line.has_prefix("url = ") => {
        let url = String::unsafe_substring(line, start=6, end=line.length())
        remotes.push((name, url))
      }
      _ => ()
    }
  }
  remotes
}

///|
fn get_remote_url(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> String? {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => return None
    },
  )
  let target_section = "[remote \"\{name}\"]"
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line == target_section {
      in_section = true
      continue
    }
    if line.has_prefix("[") {
      in_section = false
      continue
    }
    if in_section && line.has_prefix("url = ") {
      return Some(String::unsafe_substring(line, start=6, end=line.length()))
    }
  }
  None
}

///|
fn remote_add(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  url : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  // Check if remote already exists
  if get_remote_url(rfs, git_dir, name) is Some(_) {
    raise @git.GitError::InvalidObject("remote '\{name}' already exists")
  }
  // Read existing config or create new
  let existing = if rfs.is_file(config_path) {
    decode_bytes(rfs.read_file(config_path))
  } else {
    ""
  }
  // Append remote section
  let remote_section = "[remote \"\{name}\"]\n\turl = \{url}\n\tfetch = +refs/heads/*:refs/remotes/\{name}/*\n"
  let new_content = if existing.length() > 0 && not(existing.has_suffix("\n")) {
    existing + "\n" + remote_section
  } else {
    existing + remote_section
  }
  fs.write_string(config_path, new_content)
}

///|
fn remote_remove(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  if not(rfs.is_file(config_path)) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let target_section = "[remote \"\{name}\"]"
  let lines : Array[String] = []
  let mut in_target_section = false
  let mut found = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_string(line)
    if trimmed == target_section {
      in_target_section = true
      found = true
      continue
    }
    if in_target_section && trimmed.has_prefix("[") {
      in_target_section = false
    }
    if not(in_target_section) {
      lines.push(line)
    }
  }
  if not(found) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  // Remove trailing empty lines
  while lines.length() > 0 && trim_string(lines[lines.length() - 1]) == "" {
    let _ = lines.pop()

  }
  let new_content = lines
    .iter()
    .fold(init="", fn(acc, line) {
      if acc == "" {
        line
      } else {
        acc + "\n" + line
      }
    }) +
    "\n"
  fs.write_string(config_path, new_content)
}

///|
fn remote_set_url(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  url : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  if not(rfs.is_file(config_path)) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let target_section = "[remote \"\{name}\"]"
  let lines : Array[String] = []
  let mut in_target_section = false
  let mut found = false
  let mut url_replaced = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_string(line)
    if trimmed == target_section {
      in_target_section = true
      found = true
      lines.push(line)
      continue
    }
    if in_target_section && trimmed.has_prefix("[") {
      in_target_section = false
    }
    if in_target_section && trimmed.has_prefix("url = ") && not(url_replaced) {
      lines.push("\turl = \{url}")
      url_replaced = true
      continue
    }
    lines.push(line)
  }
  if not(found) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let new_content = lines
    .iter()
    .fold(init="", fn(acc, line) {
      if acc == "" {
        line
      } else {
        acc + "\n" + line
      }
    })
  fs.write_string(config_path, new_content)
}

///|
fn parse_pack_args(args : Array[String]) -> (Bool, String)? {
  let mut advertise = false
  let mut repo : String? = None
  for arg in args {
    match arg {
      "--advertise-refs" => advertise = true
      "--stateless-rpc" => continue
      _ if arg.has_prefix("--") => continue
      _ => if repo is None { repo = Some(arg) }
    }
  }
  match repo {
    Some(path) => Some((advertise, path))
    None => None
  }
}

///|
async fn handle_upload_pack(args : Array[String]) -> Unit {
  // Handle -h option
  for arg in args {
    if arg == "-h" {
      print_line(
        "usage: git upload-pack [--[no-]strict] [--timeout=<n>] [--stateless-rpc]",
      )
      print_line("                       [--advertise-refs] <dir>")
      @sys.exit(129)
    }
  }
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    // Bare repository with .git suffix
    repo_path
  } else {
    normalize_repo_root(repo_path)
  }
  let fs = OsFs::new()
  if advertise {
    let out = @gitlib.build_upload_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    let req = @gitlib.parse_upload_pack_request(input)
    let out = @gitlib.upload_pack(fs, root, req)
    @stdio.stdout.write(out)
  }
}

///|
async fn handle_receive_pack(args : Array[String]) -> Unit {
  // Handle -h option
  for arg in args {
    if arg == "-h" {
      print_line("usage: git receive-pack <git-dir>")
      @sys.exit(129)
    }
  }
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    // Bare repository with .git suffix
    repo_path
  } else {
    normalize_repo_root(repo_path)
  }
  let fs = OsFs::new()
  if advertise {
    let out = @gitlib.build_receive_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    let out = @gitlib.receive_pack(fs, fs, root, input)
    @stdio.stdout.write(out)
  }
}

///|
/// Parse filter specification from command line
fn parse_filter_spec(spec : String) -> @git.FilterSpec {
  if spec == "blob:none" {
    @git.FilterSpec::BlobNone
  } else if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = @strconv.parse_int64(limit_str) catch { _ => 0L }
    @git.FilterSpec::BlobLimit(limit)
  } else if spec.has_prefix("tree:") {
    let depth_str = String::unsafe_substring(spec, start=5, end=spec.length())
    let depth = @strconv.parse_int(depth_str) catch { _ => 0 }
    @git.FilterSpec::TreeDepth(depth)
  } else {
    @git.FilterSpec::NoFilter
  }
}

///|
async fn handle_clone(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let mut url : String? = None
  let mut dest : String? = None
  let mut depth = 0
  let mut filter = @git.FilterSpec::NoFilter
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--depth" && i + 1 < args.length() {
      // Parse depth value
      let depth_str = args[i + 1]
      depth = @strconv.parse_int(depth_str) catch { _ => 0 }
      i += 2
      continue
    }
    if arg.has_prefix("--depth=") {
      let depth_str = String::unsafe_substring(arg, start=8, end=arg.length())
      depth = @strconv.parse_int(depth_str) catch { _ => 0 }
      i += 1
      continue
    }
    // Parse --filter option
    if arg == "--filter" && i + 1 < args.length() {
      filter = parse_filter_spec(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--filter=") {
      let filter_str = String::unsafe_substring(arg, start=9, end=arg.length())
      filter = parse_filter_spec(filter_str)
      i += 1
      continue
    }
    if arg.has_prefix("-") {
      i += 1
      continue
    }
    if url is None {
      url = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
    i += 1
  }
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Derive destination from URL if not specified
  let relative_target = match dest {
    Some(d) => d
    None => {
      let name = if remote_url.has_suffix(".git") {
        String::unsafe_substring(
          remote_url,
          start=0,
          end=remote_url.length() - 4,
        )
      } else {
        remote_url
      }
      match name.rev_find("/") {
        Some(i) =>
          String::unsafe_substring(name, start=i + 1, end=name.length())
        None => name
      }
    }
  }
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  // Show what kind of clone we're doing
  let clone_type = if filter.is_partial() {
    "partial clone (\{filter.to_string()})"
  } else if depth > 0 {
    "shallow clone (depth=\{depth})"
  } else {
    "full clone"
  }
  print_line("Cloning into '\{relative_target}'... (\{clone_type})")
  let fs = OsFs::new()
  let refs = @git.clone_http_to_fs(
    remote_url,
    true,
    fs,
    target,
    depth~,
    filter~,
  )
  if refs.length() > 0 {
    print_line("done.")
  } else {
    raise @git.GitError::InvalidObject("Clone failed: no refs found")
  }
}

///|
async fn handle_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Read remote URL from config
  let mut remote_url : String? = read_remote_url_from_config(fs, git_dir)
  // Override with command line argument
  for arg in args {
    if not(arg.has_prefix("-")) {
      remote_url = Some(arg)
      break
    }
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  print_line("Fetching from \{url}...")
  let (refs, _caps, _version, symrefs) = @git.discover_upload_refs_http(
    url, true,
  )
  let default_ref = @git.select_default_ref(refs, symrefs)
  match default_ref {
    None => {
      print_line("No refs to fetch")
      return ()
    }
    Some((refname, commit_id)) => {
      let pack = @git.fetch_pack_http(url, [commit_id], true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
      // Update remote tracking ref
      let remote_ref = if refname.has_prefix("refs/heads/") {
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        "refs/remotes/origin/" + name
      } else {
        "refs/remotes/origin/HEAD"
      }
      let remote_path = git_dir + "/" + remote_ref
      let dir = match remote_path.rev_find("/") {
        None => ""
        Some(i) => String::unsafe_substring(remote_path, start=0, end=i)
      }
      if dir.length() > 0 {
        fs.mkdir_p(dir)
      }
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      print_line("From \{url}")
      print_line(" * [new branch] \{refname} -> \{remote_ref}")
    }
  }
}

///|
async fn handle_pull(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut remote_url : String? = read_remote_url_from_config(fs, git_dir)
  let mut rebase = false
  for arg in args {
    match arg {
      "--rebase" | "-r" => rebase = true
      _ if arg.has_prefix("-") => continue
      _ => {
        remote_url = Some(arg)
        break
      }
    }
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  print_line("Pulling from \{url}...")
  let result = @gitlib.pull_http(fs, fs, root, url, true, rebase~)
  match result {
    None => print_line("Already up to date.")
    Some(id) => print_line("Updated to \{id.to_hex()}")
  }
}

///|
async fn handle_push(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse arguments
  let mut remote_name = "origin"
  let mut refspec : String? = None
  let mut force = false
  let mut set_upstream = false
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "-u" | "--set-upstream" => set_upstream = true
      _ if arg.has_prefix("-") => ()
      _ =>
        if refspec is None {
          // First non-option is either remote or refspec
          // Check if it's a known remote
          let url = get_remote_url(fs, git_dir, arg)
          if url is Some(_) {
            remote_name = arg
          } else {
            refspec = Some(arg)
          }
        } else {
          // Second non-option is refspec
          refspec = Some(arg)
        }
    }
  }
  // Get remote URL
  let remote_url = get_remote_url(fs, git_dir, remote_name)
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No such remote: \{remote_name}")
  }
  // Determine refspec
  let refname = match refspec {
    Some(r) => if r.has_prefix("refs/") { r } else { "refs/heads/" + r }
    None => {
      // Use current branch
      let head_ref = @gitlib.read_head_ref(fs, git_dir)
      match head_ref {
        @gitlib.HeadRef::Branch(branch) => "refs/heads/" + branch
        @gitlib.HeadRef::Detached(_) =>
          raise @git.GitError::InvalidObject(
            "Cannot push from detached HEAD without refspec",
          )
      }
    }
  }
  print_line("Pushing to \{url}...")
  ignore(force) // TODO: implement force push
  let result = @gitlib.push_http(fs, root, url, refname)
  print_line(result)
  if set_upstream {
    // TODO: set tracking branch
    print_line("Branch '\{refname}' set up to track remote branch.")
  }
}

///|
fn read_remote_url_from_config(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return None
  }
  let config_content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => return None
    },
  )
  let mut in_remote_section = false
  for line_view in config_content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[remote ") {
      in_remote_section = true
      continue
    }
    if line.has_prefix("[") {
      in_remote_section = false
      continue
    }
    if in_remote_section && line.has_prefix("url = ") {
      return Some(String::unsafe_substring(line, start=6, end=line.length()))
    }
  }
  None
}
