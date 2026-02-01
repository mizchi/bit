///| Remote operation handlers: remote, upload-pack, receive-pack, fetch, pull, push, clone

///|
/// GitHub shorthand result
pub(all) enum GitHubShorthand {
  /// Full repo clone: @user/repo → https://github.com/user/repo
  Repo(String) // github_url
  /// Subdir clone: @user/repo/path → https://github.com/user/repo, path
  Subdir(String, String) // github_url, subdir_path
  /// Single file fetch: raw URL, filename
  File(String, String) // raw_url, filename
} derive(Eq, Show)

///|
/// Parse GitHub shorthand or GitHub browser URL
///
/// Supports:
/// 1. @user/repo → Repo clone
/// 2. @user/repo/path → Subdir clone
/// 3. https://github.com/user/repo/tree/branch/path → Subdir clone
/// 4. https://github.com/user/repo/blob/branch/path → Single file fetch
///
/// Examples:
/// - "@user/repo" → Repo("https://github.com/user/repo")
/// - "@user/repo/src" → Subdir("https://github.com/user/repo", "src")
/// - "https://github.com/user/repo/tree/main/src" → Subdir(url, "src")
/// - "https://github.com/user/repo/blob/main/README.md" → File(raw_url, "README.md")
pub fn parse_github_shorthand(url : String) -> GitHubShorthand? {
  // Check for GitHub browser URL first
  if url.has_prefix("https://github.com/") {
    return parse_github_browser_url(url)
  }
  // Must start with @ for shorthand
  if not(url.has_prefix("@")) {
    return None
  }
  // Remove @ prefix
  let path = String::unsafe_substring(url, start=1, end=url.length())
  // Split into parts
  let parts : Array[String] = path
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  // Need at least 2 components: user/repo
  if parts.length() < 2 {
    return None
  }
  let owner = parts[0]
  let repo = parts[1]
  let github_url = "https://github.com/\{owner}/\{repo}"
  if parts.length() == 2 {
    // Just @user/repo → full repo clone
    Some(Repo(github_url))
  } else {
    // @user/repo/path → subdir clone
    let subdir_parts : Array[String] = []
    for j = 2; j < parts.length(); j = j + 1 {
      subdir_parts.push(parts[j])
    }
    let subdir = subdir_parts.join("/")
    Some(Subdir(github_url, subdir))
  }
}

///|
/// Parse GitHub browser URL (tree/blob)
/// https://github.com/user/repo/tree/branch/path → Subdir
/// https://github.com/user/repo/blob/branch/path → File
fn parse_github_browser_url(url : String) -> GitHubShorthand? {
  // Remove https://github.com/
  let path = String::unsafe_substring(url, start=19, end=url.length())
  let parts : Array[String] = path
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  // Need at least: user/repo/tree|blob/branch/path
  // parts[0] = user, parts[1] = repo, parts[2] = tree|blob, parts[3] = branch, parts[4+] = path
  if parts.length() < 5 {
    return None
  }
  let owner = parts[0]
  let repo = parts[1]
  let kind = parts[2] // "tree" or "blob"
  let branch = parts[3]
  // Build path from remaining parts
  let path_parts : Array[String] = []
  for i = 4; i < parts.length(); i = i + 1 {
    path_parts.push(parts[i])
  }
  let subpath = path_parts.join("/")
  let github_url = "https://github.com/\{owner}/\{repo}"
  if kind == "tree" {
    // Directory → subdir clone
    Some(Subdir(github_url, subpath))
  } else if kind == "blob" {
    // File → raw fetch
    let raw_url = "https://raw.githubusercontent.com/\{owner}/\{repo}/\{branch}/\{subpath}"
    let filename = parts[parts.length() - 1]
    Some(File(raw_url, filename))
  } else {
    None
  }
}

///|
/// Fetch a raw file from URL and save to local path
async fn fetch_raw_file(url : String, target : String) -> Unit raise Error {
  let root = get_work_root()
  let target_path = if target.has_prefix("/") {
    target
  } else {
    root + "/" + target
  }
  // Use HTTP fetch
  let headers : Map[String, String] = {}
  let (response, content) = @git.native_http_get(url, headers)
  if response.code != 200 {
    raise @git.GitError::InvalidObject(
      "HTTP \{response.code}: failed to fetch \{url}",
    )
  }
  // Write to file
  let fs = OsFs::new()
  fs.write_file(target_path, content)
  print_line("Saved to '\{target}'")
}

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
  // Check for GitHub shorthand (@user/repo, @user/repo/path, or browser URL)
  match parse_github_shorthand(remote_url) {
    Some(Repo(github_url)) => {
      // @user/repo → normal clone from GitHub
      print_line("GitHub shorthand: \{github_url}")
      url = Some(github_url)
    }
    Some(Subdir(github_url, subdir)) => {
      // @user/repo/path or /tree/ URL → subdir clone
      let subdir_args : Array[String] = [github_url, subdir]
      match dest {
        Some(d) => subdir_args.push(d)
        None => ()
      }
      print_line("GitHub subdir: \{github_url} → \{subdir}")
      return handle_subdir_clone(subdir_args)
    }
    Some(File(raw_url, filename)) => {
      // /blob/ URL → single file fetch
      let target_file = match dest {
        Some(d) => d
        None => filename
      }
      print_line("Fetching file: \{raw_url}")
      return fetch_raw_file(raw_url, target_file)
    }
    None => ()
  }
  // Re-extract remote_url after potential shorthand expansion
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
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
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
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
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
  // Check if this is a subdir-clone
  let subdir_remote = match get_subdir_info(fs, git_dir) {
    Some((remote, _, _)) => Some(remote)
    None => None
  }
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
  // Get remote URL - prefer subdir-clone remote
  let remote_url = match subdir_remote {
    Some(url) => Some(url)
    None => get_remote_url(fs, git_dir, remote_name)
  }
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
  // Check if this is a subdir-clone - if so, transform commits before push
  match get_subdir_info(fs, git_dir) {
    Some((remote_url, subdir_path, base_hex)) => {
      print_line("Pushing subdir-clone to \{remote_url}...")
      print_line("  Subdirectory: \{subdir_path}")
      handle_subdir_push(
        fs, root, git_dir, remote_url, subdir_path, base_hex, refname, force,
      ) catch { err => raise err }
    }
    None => {
      print_line("Pushing to \{url}...")
      ignore(force) // TODO: implement force push
      let result = @gitlib.push_http(fs, root, url, refname)
      print_line(result)
    }
  }
  if set_upstream {
    // TODO: set tracking branch
    print_line("Branch '\{refname}' set up to track remote branch.")
  }
}

///|
/// Handle push for subdir-clone repositories
/// Transforms local commits to fit the original repository structure
async fn handle_subdir_push(
  fs : OsFs,
  root : String,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  base_hex : String,
  refname : String,
  _force : Bool,
) -> Unit raise Error {
  // Step 1: Get local HEAD commit
  let local_head_opt = @gitlib.rev_parse(fs, git_dir, "HEAD") catch {
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard local_head_opt is Some(local_head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  print_line("  Local HEAD: \{local_head.to_hex()}")
  // Step 2: Get the initial commit (first commit in the subdir-clone)
  let initial_commit = find_initial_subdir_commit(fs, git_dir) catch {
    _ => raise @git.GitError::InvalidObject("Cannot find initial commit")
  }
  print_line("  Initial commit: \{initial_commit.to_hex()}")
  // Step 3: Collect local commits since initial
  let local_commits = collect_commits_since(
    fs, git_dir, initial_commit, local_head,
  ) catch { err => raise err }
  if local_commits.length() == 0 {
    print_line("Nothing to push.")
    return
  }
  print_line("  Found \{local_commits.length()} local commits to transform")
  // Step 4: Get upstream base commit
  let upstream_base = @git.ObjectId::from_hex(base_hex) catch {
    _ => raise @git.GitError::InvalidObject("Cannot parse base commit")
  }
  print_line("  Upstream base: \{upstream_base.to_hex()}")
  // Step 5: Fetch upstream base commit and its tree from remote
  print_line("  Fetching upstream objects...")
  let pack = @git.fetch_pack_http(remote_url, [upstream_base], true)
  let objects = @git.parse_packfile(pack)
  @git.write_packfile_with_index(fs, git_dir, pack, objects)
  print_line("  Fetched \{objects.length()} objects")
  // Step 6: Reload ObjectDb to pick up new packfile, then transform commits
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let mut parent : @git.ObjectId = upstream_base
  for commit_id in local_commits {
    let new_commit = transform_subdir_commit(
      fs, db, git_dir, commit_id, parent, subdir_path,
    ) catch { err => raise err }
    print_line("  Transformed: \{commit_id.to_hex()} -> \{new_commit.to_hex()}")
    parent = new_commit
  }
  // Step 7: Push the transformed commits (tree only, not parent history)
  let transformed_head : @git.ObjectId = parent
  print_line("  Pushing transformed commits...")
  let result = @gitlib.push_http_tree_only(
    fs, root, remote_url, transformed_head, upstream_base, refname,
  )
  print_line("  \{result}")
  // Step 8: Update base commit
  update_subdir_base(fs, git_dir, transformed_head.to_hex())
  print_line("done.")
}

///|
/// Find the initial commit of a subdir-clone (the "cloned from" commit)
fn find_initial_subdir_commit(
  fs : OsFs,
  git_dir : String,
) -> @git.ObjectId raise @git.GitError {
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Start from HEAD and walk back to find root commit
  let head_opt = @gitlib.rev_parse(fs, git_dir, "HEAD") catch {
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard head_opt is Some(head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  let mut current : @git.ObjectId = head
  let mut prev : @git.ObjectId = current
  while true {
    let obj = db.get(fs, current)
    guard obj is Some(o) else {
      break
    }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      // Found root commit
      return current
    }
    prev = current
    current = info.parents[0]
  }
  prev
}

///|
/// Collect commits from start (exclusive) to end (inclusive)
fn collect_commits_since(
  fs : OsFs,
  git_dir : String,
  start : @git.ObjectId,
  end : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let result : Array[@git.ObjectId] = []
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  let mut current : @git.ObjectId = end
  let start_hex = start.to_hex()
  while true {
    let hex = current.to_hex()
    if hex == start_hex {
      break
    }
    result.push(current)
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get oldest first
  result.rev_in_place()
  result
}

///|
/// Transform a subdir-clone commit to fit the original repository structure
fn transform_subdir_commit(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  local_commit : @git.ObjectId,
  upstream_parent : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId raise @git.GitError {
  // Get local commit info
  let local_obj = db.get(fs, local_commit)
  guard local_obj is Some(lo) else {
    raise @git.GitError::InvalidObject("Cannot find local commit")
  }
  let local_info = @git.parse_commit(lo.data) catch { err => raise err }
  let (author, message) = parse_commit_author_message(lo.data)
  // Get upstream parent's tree
  let upstream_obj = db.get(fs, upstream_parent)
  guard upstream_obj is Some(uo) else {
    raise @git.GitError::InvalidObject("Cannot find upstream commit")
  }
  let upstream_info = @git.parse_commit(uo.data) catch { err => raise err }
  // The local commit's tree IS the subdirectory content
  let new_subdir_tree = local_info.tree
  // Replace the subdirectory in the upstream tree
  let new_root_tree = replace_tree_at_path(
    fs, db, git_dir, upstream_info.tree, subdir_path, new_subdir_tree,
  ) catch { err => raise err }
  // Create new commit with the transformed tree
  let timestamp = get_current_timestamp()
  let new_commit = @subdir.create_commit_in_repo(
    fs, git_dir, new_root_tree, upstream_parent, message, author, timestamp,
  ) catch {
    _ => raise @git.GitError::InvalidObject("Cannot create commit")
  }
  new_commit
}

///|
/// Replace a subtree at a given path within a root tree
fn replace_tree_at_path(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  root_tree : @git.ObjectId,
  path : String,
  new_subtree : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  let path_parts : Array[String] = path
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  if path_parts.length() == 0 {
    return new_subtree
  }
  replace_tree_recursive_push(
    fs, db, git_dir, root_tree, path_parts, 0, new_subtree,
  )
}

///|
fn replace_tree_recursive_push(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  current_tree : @git.ObjectId,
  path_parts : Array[String],
  depth : Int,
  new_leaf : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  // Read current tree
  let tree_obj = db.get(fs, current_tree)
  guard tree_obj is Some(to) else {
    raise @git.GitError::InvalidObject("Cannot find tree")
  }
  let entries = @git.parse_tree(to.data) catch { err => raise err }
  // Build new entries
  let new_entries : Array[@git.TreeEntry] = []
  let target_name = path_parts[depth]
  let is_last = depth == path_parts.length() - 1
  for entry in entries {
    if entry.name == target_name {
      if is_last {
        // Replace with new subtree
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_leaf))
      } else {
        // Recurse
        let new_child = replace_tree_recursive_push(
          fs, db, git_dir, entry.id, path_parts, depth + 1, new_leaf,
        ) catch { err => raise err }
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_child))
      }
    } else {
      new_entries.push(entry)
    }
  }
  // Create new tree and write it
  let (tree_id, tree_data) = @git.create_tree(new_entries)
  write_object_to_repo(fs, git_dir, tree_id, tree_data) catch {
    _ => raise @git.GitError::InvalidObject("Cannot write tree")
  }
  tree_id
}

///|
/// Write an object (already compressed) to the repository
fn write_object_to_repo(
  fs : OsFs,
  git_dir : String,
  id : @git.ObjectId,
  compressed_data : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let dir_name = String::unsafe_substring(hex, start=0, end=2)
  let file_name = String::unsafe_substring(hex, start=2, end=40)
  let dir_path = git_dir + "/objects/" + dir_name
  let file_path = dir_path + "/" + file_name
  // Create directory if needed
  fs.mkdir_p(dir_path) catch { _ => () }
  // Write already-compressed data
  fs.write_file(file_path, compressed_data) catch {
    _ => raise @git.GitError::IoError("Cannot write object")
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
