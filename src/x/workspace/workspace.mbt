///|
/// workspace command handler

///|
async fn warn_unimplemented_arg(cmd : String, arg : String) -> Unit {
  if arg == "--" {
    return
  }
  let msg = "warning: " + cmd + ": unsupported option '" + arg + "'\n"
  @stdio.stderr.write(msg)
}

///|
async fn eprint_line(msg : String) -> Unit {
  @stdio.stderr.write(msg + "\n")
}

///|
fn decode_bytes(data : Bytes) -> String {
  @encoding.decoder(@encoding.Encoding::UTF8).decode_lossy(data[:])
}

///|
fn trim_string(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn collect_args(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
fn parent_dir(path : String) -> String {
  if path.length() == 0 || path == "/" {
    return "/"
  }
  let sep = @path.sep.to_string()
  match path.rev_find(sep) {
    None => ""
    Some(idx) => if idx == 0 { sep } else { (try! path[:idx]).to_string() }
  }
}

///|
fn normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()
      } else if not(path.has_prefix("/")) {
        parts.push(part)
      }
    } else {
      parts.push(part)
    }
  }
  let result = parts.join("/")
  if path.has_prefix("/") {
    if result.length() == 0 {
      "/"
    } else {
      "/" + result
    }
  } else if result.length() == 0 {
    "."
  } else {
    result
  }
}

///|
fn join_repo_marker(root : String, marker : String) -> String {
  if root == "/" {
    "/" + marker
  } else if root == "." {
    marker
  } else {
    root + "/" + marker
  }
}

///|
fn detect_repo_marker_path(fs : &@git.RepoFileSystem, root : String) -> String? {
  let bit_marker = join_repo_marker(root, ".bit")
  if fs.is_dir(bit_marker) || fs.is_file(bit_marker) {
    return Some(bit_marker)
  }
  let git_marker = join_repo_marker(root, ".git")
  if fs.is_dir(git_marker) || fs.is_file(git_marker) {
    return Some(git_marker)
  }
  None
}

///|
fn default_repo_marker_path(fs : &@git.RepoFileSystem, root : String) -> String {
  match detect_repo_marker_path(fs, root) {
    Some(path) => path
    None => join_repo_marker(root, ".git")
  }
}

///|
fn is_bare_repo_dir(path : String) -> Bool {
  let head_ok = @fs.is_file(path + "/HEAD") catch { _ => false }
  let objs_ok = @fs.is_dir(path + "/objects") catch { _ => false }
  head_ok && objs_ok
}

///|
fn resolve_git_dir(fs : &@git.RepoFileSystem, root : String) -> String {
  let default_git_dir = default_repo_marker_path(fs, root)
  match @sys.get_env_var("GIT_DIR") {
    Some(dir) => {
      let resolved = if dir.has_prefix("/") {
        dir
      } else {
        match @sys.get_env_var("GIT_SHIM_CWD") {
          Some(base) => normalize_path(base + "/" + dir)
          None =>
            @sys.get_env_var("GIT_SHIM_PWD")
            .map(base => normalize_path(base + "/" + dir))
            .unwrap_or(dir)
        }
      }
      if fs.is_file(resolved) {
        @gitlib.resolve_gitdir(fs, resolved)
      } else if fs.is_dir(resolved) {
        resolved
      } else if is_bare_repo_dir(root) {
        root
      } else {
        resolved
      }
    }
    None =>
      if fs.is_file(default_git_dir) {
        @gitlib.resolve_gitdir(fs, default_git_dir)
      } else if fs.is_dir(default_git_dir) {
        default_git_dir
      } else if is_bare_repo_dir(root) {
        root
      } else {
        default_git_dir
      }
  }
}

///|
fn get_current_timestamp() -> Int64 {
  @env.now().to_int().to_int64() / 1000
}

///|
priv struct WorkspaceNode {
  mut id : String
  mut path : String
  mut required : Bool
  mut remote : String?
  mut branch : String?
  mut depends_on : Array[String]
  tasks : Map[String, String]
}

///|
priv struct WorkspaceManifest {
  version : Int
  nodes : Array[WorkspaceNode]
}

///|
priv struct WorkspaceTxnStep {
  node_id : String
  path : String
  command : String
  status : String
  required : Bool
  message : String
}

///|
fn workspace_new_node() -> WorkspaceNode {
  {
    id: "root",
    path: ".",
    required: true,
    remote: None,
    branch: None,
    depends_on: [],
    tasks: {},
  }
}

///|
fn workspace_default_manifest() -> WorkspaceManifest {
  { version: 1, nodes: [workspace_new_node()] }
}

///|
fn workspace_flow_template_manifest() -> WorkspaceManifest {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  root.tasks["test"] = "echo root >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/root.log\""

  let dep = workspace_new_node()
  dep.id = "dep"
  dep.path = "dep"
  dep.depends_on = ["root"]
  dep.tasks["test"] = "echo dep >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/dep.log\""

  let leaf = workspace_new_node()
  leaf.id = "leaf"
  leaf.path = "leaf"
  leaf.depends_on = ["dep"]
  leaf.tasks["test"] = "echo leaf >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/leaf.log\""

  let extra = workspace_new_node()
  extra.id = "extra"
  extra.path = "extra"
  extra.depends_on = []
  extra.tasks["test"] = "echo extra >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/extra.log\""

  { version: 1, nodes: [root, dep, leaf, extra] }
}

///|
fn workspace_manifest_for_template(
  template : String?,
) -> WorkspaceManifest raise @git.GitError {
  match template {
    None => workspace_default_manifest()
    Some(raw) => {
      let name = trim_string(raw).to_lower()
      match name {
        "" | "default" | "basic" | "minimal" => workspace_default_manifest()
        "flow" => workspace_flow_template_manifest()
        _ =>
          raise @git.GitError::InvalidObject(
            "unknown workspace template: '" + raw + "'",
          )
      }
    }
  }
}

///|
fn workspace_subcommand_names() -> Array[String] {
  ["init", "status", "commit", "push", "run", "flow", "export", "doctor"]
}

///|
fn is_workspace_subcommand_name(cmd : String) -> Bool {
  for name in workspace_subcommand_names() {
    if cmd == name {
      return true
    }
  }
  false
}

///|
fn resolve_workspace_probe_dir(cwd : String?) -> String {
  let raw = match cwd {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("GIT_SHIM_CWD") {
        Some(dir) => dir
        None =>
          match @sys.get_env_var("GIT_SHIM_PWD") {
            Some(dir) => dir
            None =>
              match @env.current_dir() {
                Some(dir) => dir
                None => @sys.get_env_var("PWD").unwrap_or(".")
              }
          }
      }
  }
  normalize_path(raw)
}

///|
fn workspace_bit_marker(root : String) -> String {
  join_repo_marker(root, ".bit")
}

///|
fn workspace_resolve_gitdir_from_bit_file(
  fs : &@git.RepoFileSystem,
  bit_file : String,
) -> String? {
  Some(@gitlib.resolve_gitdir(fs, bit_file))
}

///|
fn workspace_manifest_path_at(
  fs : &@git.RepoFileSystem,
  root : String,
) -> String? {
  let bit_marker = workspace_bit_marker(root)
  if fs.is_dir(bit_marker) {
    let path = bit_marker + "/workspace.toml"
    if fs.is_file(path) {
      return Some(path)
    }
  }
  if fs.is_file(bit_marker) {
    match workspace_resolve_gitdir_from_bit_file(fs, bit_marker) {
      Some(git_dir) => {
        let path = git_dir + "/workspace.toml"
        if fs.is_file(path) {
          return Some(path)
        }
      }
      None => ()
    }
  }
  let git_marker = join_repo_marker(root, ".git")
  if fs.is_dir(git_marker) {
    let path = git_marker + "/workspace.toml"
    if fs.is_file(path) {
      return Some(path)
    }
  }
  if fs.is_file(git_marker) {
    match workspace_resolve_gitdir_from_bit_file(fs, git_marker) {
      Some(git_dir) => {
        let path = git_dir + "/workspace.toml"
        if fs.is_file(path) {
          return Some(path)
        }
      }
      None => ()
    }
  }
  None
}

///|
fn workspace_meta_dir_for_root(
  fs : &@git.RepoFileSystem,
  root : String,
) -> String {
  let bit_marker = workspace_bit_marker(root)
  if fs.is_dir(bit_marker) {
    return bit_marker
  }
  if fs.is_file(bit_marker) {
    match workspace_resolve_gitdir_from_bit_file(fs, bit_marker) {
      Some(git_dir) => return git_dir
      None => ()
    }
  }
  let git_marker = join_repo_marker(root, ".git")
  if fs.is_dir(git_marker) {
    return git_marker
  }
  if fs.is_file(git_marker) {
    match workspace_resolve_gitdir_from_bit_file(fs, git_marker) {
      Some(git_dir) => return git_dir
      None => ()
    }
  }
  bit_marker
}

///|
fn workspace_manifest_write_path(
  fs : &@git.RepoFileSystem,
  root : String,
) -> String {
  workspace_meta_dir_for_root(fs, root) + "/workspace.toml"
}

///|
fn workspace_lock_path(fs : &@git.RepoFileSystem, root : String) -> String {
  workspace_meta_dir_for_root(fs, root) + "/workspace.lock.json"
}

///|
fn workspace_flow_cache_path(
  fs : &@git.RepoFileSystem,
  root : String,
) -> String {
  workspace_meta_dir_for_root(fs, root) + "/workspace.flow-cache.json"
}

///|
fn workspace_txn_dir(fs : &@git.RepoFileSystem, root : String) -> String {
  workspace_meta_dir_for_root(fs, root) + "/txns"
}

///|
fn workspace_txn_path(
  fs : &@git.RepoFileSystem,
  root : String,
  txn_id : String,
) -> String {
  workspace_txn_dir(fs, root) + "/" + txn_id + ".json"
}

///|
fn find_workspace_root_from(start : String) -> String? {
  let fs = @osfs.OsFs::new()
  let mut current = normalize_path(start)
  if current.length() == 0 {
    current = "."
  }
  let mut last = ""
  while true {
    if workspace_manifest_path_at(fs, current) is Some(_) {
      return Some(current)
    }
    let parent = parent_dir(current)
    let next = if parent.length() == 0 { "." } else { parent }
    if next == current || next == last {
      break
    }
    last = current
    current = next
  }
  None
}

///|
fn require_workspace_root(cwd : String?) -> String raise @git.GitError {
  let start = resolve_workspace_probe_dir(cwd)
  match find_workspace_root_from(start) {
    Some(root) => root
    None =>
      raise @git.GitError::InvalidObject(
        "Not inside a workspace (missing .bit/workspace.toml)",
      )
  }
}

///|
fn strip_workspace_comment(raw : String) -> String {
  let mut in_string = false
  let mut escaped = false
  for i in 0..<raw.length() {
    let ch = raw.unsafe_get(i)
    if escaped {
      escaped = false
      continue
    }
    if ch == '\\' {
      escaped = true
      continue
    }
    if ch == '"' {
      in_string = not(in_string)
      continue
    }
    if ch == '#' && not(in_string) {
      return String::unsafe_substring(raw, start=0, end=i)
    }
  }
  raw
}

///|
fn parse_toml_string(raw : String) -> String? {
  let text = trim_string(raw)
  if text.length() < 2 {
    return None
  }
  if not(text.has_prefix("\"")) || not(text.has_suffix("\"")) {
    return None
  }
  let inner = String::unsafe_substring(text, start=1, end=text.length() - 1)
  let unescaped = inner
    .replace_all(old="\\\"", new="\"")
    .replace_all(old="\\\\", new="\\")
  Some(unescaped)
}

///|
fn parse_toml_bool(raw : String, default : Bool) -> Bool {
  let text = trim_string(raw).to_lower()
  if text == "true" {
    true
  } else if text == "false" {
    false
  } else {
    default
  }
}

///|
fn parse_toml_string_array(raw : String) -> Array[String] {
  let text = trim_string(raw)
  if text.length() < 2 || not(text.has_prefix("[")) || not(text.has_suffix("]")) {
    return []
  }
  let inner = String::unsafe_substring(text, start=1, end=text.length() - 1)
  let result : Array[String] = []
  for part_view in inner.split(",") {
    let part = trim_string(part_view.to_string())
    if part.length() == 0 {
      continue
    }
    match parse_toml_string(part) {
      Some(value) => result.push(value)
      None => ()
    }
  }
  result
}

///|
fn parse_workspace_manifest(text : String) -> WorkspaceManifest {
  let mut version = 1
  let nodes : Array[WorkspaceNode] = []
  let mut current : WorkspaceNode? = None
  for raw_line_view in text.split("\n") {
    let raw_line = raw_line_view.to_string()
    let line = trim_string(strip_workspace_comment(raw_line))
    if line.length() == 0 {
      continue
    }
    if line == "[[nodes]]" {
      match current {
        Some(node) => nodes.push(node)
        None => ()
      }
      current = Some(workspace_new_node())
      continue
    }
    match line.find("=") {
      Some(eq_idx) => {
        let key = trim_string(
          String::unsafe_substring(line, start=0, end=eq_idx),
        )
        let value = trim_string(
          String::unsafe_substring(line, start=eq_idx + 1, end=line.length()),
        )
        match current {
          Some(node) => {
            let next = node
            match key {
              "id" => if parse_toml_string(value) is Some(v) { next.id = v }
              "path" => if parse_toml_string(value) is Some(v) { next.path = v }
              "required" =>
                next.required = parse_toml_bool(value, next.required)
              "remote" => next.remote = parse_toml_string(value)
              "branch" => next.branch = parse_toml_string(value)
              "depends_on" => next.depends_on = parse_toml_string_array(value)
              _ =>
                if key.has_prefix("task.") {
                  let task_name = String::unsafe_substring(
                    key,
                    start=5,
                    end=key.length(),
                  )
                  if parse_toml_string(value) is Some(cmd) {
                    next.tasks[task_name] = cmd
                  }
                }
            }
            current = Some(next)
          }
          None =>
            if key == "version" {
              version = @strconv.parse_int(value[:]) catch { _ => version }
            }
        }
      }
      None => ()
    }
  }
  match current {
    Some(node) => nodes.push(node)
    None => ()
  }
  if nodes.length() == 0 {
    workspace_default_manifest()
  } else {
    { version, nodes }
  }
}

///|
fn toml_quote(s : String) -> String {
  "\"" +
  s.replace_all(old="\\", new="\\\\").replace_all(old="\"", new="\\\"") +
  "\""
}

///|
fn format_toml_string_array(items : Array[String]) -> String {
  let out : Array[String] = []
  for item in items {
    out.push(toml_quote(item))
  }
  "[" + out.join(", ") + "]"
}

///|
fn format_workspace_manifest(manifest : WorkspaceManifest) -> String {
  let buf = StringBuilder::new()
  buf.write_string("version = ")
  buf.write_string(manifest.version.to_string())
  buf.write_string("\n")
  for node in manifest.nodes {
    buf.write_string("\n[[nodes]]\n")
    buf.write_string("id = ")
    buf.write_string(toml_quote(node.id))
    buf.write_string("\n")
    buf.write_string("path = ")
    buf.write_string(toml_quote(node.path))
    buf.write_string("\n")
    buf.write_string("required = ")
    buf.write_string(if node.required { "true" } else { "false" })
    buf.write_string("\n")
    buf.write_string("depends_on = ")
    buf.write_string(format_toml_string_array(node.depends_on))
    buf.write_string("\n")
    match node.remote {
      Some(remote) => {
        buf.write_string("remote = ")
        buf.write_string(toml_quote(remote))
        buf.write_string("\n")
      }
      None => ()
    }
    match node.branch {
      Some(branch) => {
        buf.write_string("branch = ")
        buf.write_string(toml_quote(branch))
        buf.write_string("\n")
      }
      None => ()
    }
    for task_name, task_cmd in node.tasks {
      buf.write_string("task.")
      buf.write_string(task_name)
      buf.write_string(" = ")
      buf.write_string(toml_quote(task_cmd))
      buf.write_string("\n")
    }
  }
  buf.to_string()
}

///|
fn load_workspace_manifest(
  fs : @osfs.OsFs,
  workspace_root : String,
) -> WorkspaceManifest raise @git.GitError {
  let manifest_path = match workspace_manifest_path_at(fs, workspace_root) {
    Some(path) => path
    None =>
      raise @git.GitError::InvalidObject(
        "workspace manifest not found under " + workspace_root,
      )
  }
  let text = decode_bytes(fs.read_file(manifest_path))
  parse_workspace_manifest(text)
}

///|
fn ensure_workspace_meta_dir(
  fs : @osfs.OsFs,
  workspace_root : String,
) -> String raise Error {
  let meta_dir = workspace_meta_dir_for_root(fs, workspace_root)
  fs.mkdir_p(meta_dir)
  fs.mkdir_p(meta_dir + "/txns")
  meta_dir
}

///|
fn workspace_node_abs_path(
  workspace_root : String,
  node_path : String,
) -> String {
  if node_path == "." {
    workspace_root
  } else if node_path.has_prefix("/") {
    normalize_path(node_path)
  } else {
    normalize_path(workspace_root + "/" + node_path)
  }
}

///|
fn path_is_within_workspace_root(
  workspace_root : String,
  candidate_path : String,
) -> Bool {
  let normalized_root = normalize_path(workspace_root)
  let normalized_candidate = normalize_path(candidate_path)
  if normalized_root == "/" {
    normalized_candidate.has_prefix("/")
  } else if normalized_candidate == normalized_root {
    true
  } else {
    normalized_candidate.has_prefix(normalized_root + "/")
  }
}

///|
fn workspace_manifest_issues(
  fs : @osfs.OsFs,
  workspace_root : String,
  manifest : WorkspaceManifest,
  include_repo_checks : Bool,
) -> Array[String] {
  let issues : Array[String] = []
  for node in manifest.nodes {
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    if not(path_is_within_workspace_root(workspace_root, node_root)) {
      issues.push("node '\{node.id}' path escapes workspace root: \{node.path}")
      continue
    }
    if include_repo_checks {
      if not(fs.is_dir(node_root)) {
        issues.push("node '\{node.id}' path does not exist: \{node.path}")
      }
      if workspace_node_git_dir(fs, node_root) is None {
        issues.push("node '\{node.id}' is not a bit repository: \{node.path}")
      }
    }
  }
  let flow_nodes = workspace_flow_nodes(manifest)
  for issue in @bitflow.graph_issues(flow_nodes) {
    issues.push(issue)
  }
  issues
}

///|
fn require_workspace_manifest_valid(
  fs : @osfs.OsFs,
  workspace_root : String,
  manifest : WorkspaceManifest,
  command : String,
) -> Unit raise @git.GitError {
  let issues = workspace_manifest_issues(fs, workspace_root, manifest, false)
  if issues.length() == 0 {
    return
  }
  raise @git.GitError::InvalidObject(
    "workspace \{command} manifest invalid: " + issues[0],
  )
}

///|
fn workspace_node_git_dir(fs : @osfs.OsFs, node_root : String) -> String? {
  let marker = default_repo_marker_path(fs, node_root)
  let marker_exists = fs.is_dir(marker) ||
    fs.is_file(marker) ||
    is_bare_repo_dir(node_root)
  if not(marker_exists) {
    return None
  }
  let git_dir = resolve_git_dir(fs, node_root)
  let head_ok = try @gitlib.read_head_ref(fs, git_dir) catch {
    _ => None
  } noraise {
    _ => Some(true)
  }
  match head_ok {
    Some(_) => Some(git_dir)
    None => None
  }
}

///|
fn workspace_node_head_hex(fs : @osfs.OsFs, node_root : String) -> String? {
  guard workspace_node_git_dir(fs, node_root) is Some(git_dir) else {
    return None
  }
  let head = @gitlib.read_head_ref(fs, git_dir) catch { _ => return None }
  match head {
    @gitlib.HeadRef::Detached(id) => Some(id.to_hex())
    @gitlib.HeadRef::Branch(name) =>
      try @gitlib.resolve_ref(fs, git_dir, "refs/heads/" + name) catch {
        _ => None
      } noraise {
        maybe_id =>
          match maybe_id {
            Some(id) => Some(id.to_hex())
            None => None
          }
      }
  }
}

///|
fn workspace_json_string(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match obj.get(key) {
    Some(Json::String(value)) => value
    Some(Json::Number(value, ..)) => value.to_string()
    Some(Json::True) => "true"
    Some(Json::False) => "false"
    _ => fallback
  }
}

///|
fn workspace_fingerprint_mode() -> @fingerprint.FingerprintMode {
  match @sys.get_env_var("BIT_WORKSPACE_FINGERPRINT_MODE") {
    Some(raw) =>
      match @fingerprint.parse_fingerprint_mode(raw) {
        Some(mode) => mode
        None => @fingerprint.FingerprintMode::GitCompat
      }
    None => @fingerprint.FingerprintMode::GitCompat
  }
}

///|
fn workspace_directory_hash_with_mode(
  fs : @osfs.OsFs,
  root : String,
  mode : @fingerprint.FingerprintMode,
) -> String {
  @fingerprint.directory_fingerprint(fs, root, mode)
}

///|
fn workspace_node_directory_signature_with_mode(
  fs : @osfs.OsFs,
  node_root : String,
  mode : @fingerprint.FingerprintMode,
) -> String? {
  guard workspace_node_git_dir(fs, node_root) is Some(_) else { return None }
  let head = workspace_node_head_hex(fs, node_root).unwrap_or("unknown")
  let mode_name = @fingerprint.fingerprint_mode_name(mode)
  let dir_hash = workspace_directory_hash_with_mode(fs, node_root, mode)
  Some(
    @git.hash_blob_string(
      "mode=" + mode_name + "\nhead=" + head + "\ndir=" + dir_hash,
    ).to_hex(),
  )
}

///|
fn workspace_node_directory_signature(
  fs : @osfs.OsFs,
  node_root : String,
) -> String? {
  workspace_node_directory_signature_with_mode(
    fs,
    node_root,
    workspace_fingerprint_mode(),
  )
}

///|
fn write_workspace_lock_snapshot(
  fs : @osfs.OsFs,
  workspace_root : String,
  manifest : WorkspaceManifest,
) -> Unit raise Error {
  let nodes_json : Array[Json] = []
  for node in manifest.nodes {
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    let commit_hex = workspace_node_head_hex(fs, node_root).unwrap_or("")
    let dir_hash = workspace_node_directory_signature(fs, node_root).unwrap_or(
      "",
    )
    let node_obj : Map[String, Json] = {}
    node_obj["id"] = Json::string(node.id)
    node_obj["path"] = Json::string(node.path)
    node_obj["required"] = Json::boolean(node.required)
    node_obj["commit"] = Json::string(commit_hex)
    node_obj["dir_hash"] = Json::string(dir_hash)
    match node.remote {
      Some(remote) => node_obj["remote"] = Json::string(remote)
      None => ()
    }
    match node.branch {
      Some(branch) => node_obj["branch"] = Json::string(branch)
      None => ()
    }
    nodes_json.push(Json::object(node_obj))
  }
  let root_obj : Map[String, Json] = {}
  root_obj["snapshot_id"] = Json::string(get_current_timestamp().to_string())
  root_obj["generated_at"] = Json::number(
    get_current_timestamp().to_double(),
    repr=get_current_timestamp().to_string(),
  )
  root_obj["nodes"] = Json::array(nodes_json)
  let text = Json::object(root_obj).stringify(indent=2)
  fs.write_string(workspace_lock_path(fs, workspace_root), text)
}

///|
fn read_workspace_lock_commits(
  fs : @osfs.OsFs,
  workspace_root : String,
) -> Map[String, String] {
  let path = workspace_lock_path(fs, workspace_root)
  if not(fs.is_file(path)) {
    return {}
  }
  let text = decode_bytes(fs.read_file(path)) catch { _ => return {} }
  let parsed = @json.parse(text) catch { _ => return {} }
  let result : Map[String, String] = {}
  guard parsed is Json::Object(root_obj) else { return result }
  guard root_obj.get("nodes") is Some(Json::Array(nodes)) else { return result }
  for node in nodes {
    guard node is Json::Object(node_obj) else { continue }
    let id = workspace_json_string(node_obj, "id", "")
    let commit = workspace_json_string(node_obj, "commit", "")
    if id.length() > 0 {
      result[id] = commit
    }
  }
  result
}

///|
fn read_workspace_lock_signatures(
  fs : @osfs.OsFs,
  workspace_root : String,
) -> Map[String, String] {
  let path = workspace_lock_path(fs, workspace_root)
  if not(fs.is_file(path)) {
    return {}
  }
  let text = decode_bytes(fs.read_file(path)) catch { _ => return {} }
  let parsed = @json.parse(text) catch { _ => return {} }
  let result : Map[String, String] = {}
  guard parsed is Json::Object(root_obj) else { return result }
  guard root_obj.get("nodes") is Some(Json::Array(nodes)) else { return result }
  for node in nodes {
    guard node is Json::Object(node_obj) else { continue }
    let id = workspace_json_string(node_obj, "id", "")
    if id.length() == 0 {
      continue
    }
    let dir_hash = workspace_json_string(node_obj, "dir_hash", "")
    if dir_hash.length() > 0 {
      result[id] = dir_hash
    } else {
      result[id] = workspace_json_string(node_obj, "commit", "")
    }
  }
  result
}

///|
fn read_workspace_flow_cache(
  fs : @osfs.OsFs,
  workspace_root : String,
) -> Map[String, String] {
  let path = workspace_flow_cache_path(fs, workspace_root)
  if not(fs.is_file(path)) {
    return {}
  }
  let text = decode_bytes(fs.read_file(path)) catch { _ => return {} }
  let parsed = @json.parse(text) catch { _ => return {} }
  let result : Map[String, String] = {}
  guard parsed is Json::Object(root_obj) else { return result }
  guard root_obj.get("entries") is Some(Json::Object(entries)) else {
    return result
  }
  for key, value in entries {
    if value is Json::String(fingerprint) {
      result[key] = fingerprint
    }
  }
  result
}

///|
fn write_workspace_flow_cache(
  fs : @osfs.OsFs,
  workspace_root : String,
  cache : Map[String, String],
) -> Unit raise Error {
  let entries : Map[String, Json] = {}
  for key, fingerprint in cache {
    entries[key] = Json::string(fingerprint)
  }
  let obj : Map[String, Json] = {}
  obj["schema"] = Json::string("bit.workspace.flow-cache.v1")
  obj["generated_at"] = Json::number(
    get_current_timestamp().to_double(),
    repr=get_current_timestamp().to_string(),
  )
  obj["entries"] = Json::object(entries)
  fs.write_string(
    workspace_flow_cache_path(fs, workspace_root),
    Json::object(obj).stringify(indent=2),
  )
}

///|
fn workspace_step_to_json(step : WorkspaceTxnStep) -> Json {
  let obj : Map[String, Json] = {}
  obj["node_id"] = Json::string(step.node_id)
  obj["path"] = Json::string(step.path)
  obj["command"] = Json::string(step.command)
  obj["status"] = Json::string(step.status)
  obj["required"] = Json::boolean(step.required)
  obj["message"] = Json::string(step.message)
  Json::object(obj)
}

///|
fn write_workspace_txn(
  fs : @osfs.OsFs,
  workspace_root : String,
  txn_id : String,
  txn_type : String,
  state : String,
  steps : Array[WorkspaceTxnStep],
) -> Unit raise Error {
  let step_json : Array[Json] = []
  for step in steps {
    step_json.push(workspace_step_to_json(step))
  }
  let obj : Map[String, Json] = {}
  obj["txn_id"] = Json::string(txn_id)
  obj["type"] = Json::string(txn_type)
  obj["state"] = Json::string(state)
  obj["workspace_root"] = Json::string(workspace_root)
  obj["created_at"] = Json::number(
    get_current_timestamp().to_double(),
    repr=get_current_timestamp().to_string(),
  )
  obj["steps"] = Json::array(step_json)
  fs.write_string(
    workspace_txn_path(fs, workspace_root, txn_id),
    Json::object(obj).stringify(indent=2),
  )
}

///|
fn read_successful_push_nodes(
  fs : @osfs.OsFs,
  workspace_root : String,
  txn_id : String,
) -> Map[String, Bool] {
  let path = workspace_txn_path(fs, workspace_root, txn_id)
  if not(fs.is_file(path)) {
    return {}
  }
  let text = decode_bytes(fs.read_file(path)) catch { _ => return {} }
  let parsed = @json.parse(text) catch { _ => return {} }
  guard parsed is Json::Object(root_obj) else { return {} }
  guard root_obj.get("steps") is Some(Json::Array(steps)) else { return {} }
  let completed : Map[String, Bool] = {}
  for step in steps {
    guard step is Json::Object(step_obj) else { continue }
    let command = workspace_json_string(step_obj, "command", "")
    let status = workspace_json_string(step_obj, "status", "")
    if command != "push" || status != "success" {
      continue
    }
    let node_id = workspace_json_string(step_obj, "node_id", "")
    if node_id.length() > 0 {
      completed[node_id] = true
    }
  }
  completed
}

///|
fn workspace_node_map(
  manifest : WorkspaceManifest,
) -> Map[String, WorkspaceNode] {
  let node_map : Map[String, WorkspaceNode] = {}
  for node in manifest.nodes {
    node_map[node.id] = node
  }
  node_map
}

///|
fn workspace_flow_nodes(
  manifest : WorkspaceManifest,
) -> Array[@bitflow.FlowNode] {
  manifest.nodes.map(node => {
    @bitflow.new_node(node.id, node.depends_on, required=node.required)
  })
}

///|
fn workspace_flow_ir(
  manifest : WorkspaceManifest,
  selected : Map[String, Bool],
  task : String,
) -> @bitflow.FlowIr {
  let nodes : Array[@bitflow.FlowNode] = []
  let tasks : Array[@bitflow.FlowTask] = []
  for node in manifest.nodes {
    if selected.get(node.id) is None {
      continue
    }
    let depends_on : Array[String] = []
    for dep in node.depends_on {
      if selected.get(dep) is Some(_) {
        depends_on.push(dep)
      }
    }
    nodes.push(@bitflow.new_node(node.id, depends_on, required=node.required))
    let cmd = node.tasks.get(task).unwrap_or("")
    tasks.push(
      @bitflow.new_task(
        node.id,
        node.id,
        cmd,
        depends_on,
        required=node.required,
      ),
    )
  }
  @bitflow.new_ir("workspace-flow-" + task, nodes, tasks, max_parallel=1)
}

///|
fn workspace_topological_nodes(
  manifest : WorkspaceManifest,
) -> Array[WorkspaceNode] {
  let flow_nodes = workspace_flow_nodes(manifest)
  let ordered_flow_nodes = @bitflow.topological_nodes(flow_nodes)
  let node_map = workspace_node_map(manifest)
  let ordered : Array[WorkspaceNode] = []
  let visited : Map[String, Bool] = {}
  for flow_node in ordered_flow_nodes {
    if node_map.get(flow_node.id) is Some(node) {
      ordered.push(node)
      visited[node.id] = true
    }
  }
  for node in manifest.nodes {
    if visited.get(node.id) is None {
      ordered.push(node)
    }
  }
  ordered
}

///|
async fn workspace_is_node_dirty(fs : @osfs.OsFs, node_root : String) -> Bool {
  if workspace_node_git_dir(fs, node_root) is None {
    return false
  }
  let lines = @gitlib.status_porcelain(fs, node_root) catch { _ => [] }
  lines.length() > 0
}

///|
fn collect_changed_node_ids(
  fs : @osfs.OsFs,
  workspace_root : String,
  manifest : WorkspaceManifest,
  lock_signatures : Map[String, String],
  fingerprint_mode : @fingerprint.FingerprintMode,
) -> Map[String, Bool] {
  let changed : Map[String, Bool] = {}
  for node in manifest.nodes {
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    let current_signature = workspace_node_directory_signature_with_mode(
      fs, node_root, fingerprint_mode,
    )
    let lock_signature = lock_signatures.get(node.id)
    let drift = match (lock_signature, current_signature) {
      (Some(lock), Some(current)) => lock != current
      (Some(_), None) => true
      (None, Some(current)) => current.length() > 0
      _ => false
    }
    if drift {
      changed[node.id] = true
    }
  }
  changed
}

///|
fn expand_affected_node_ids(
  manifest : WorkspaceManifest,
  initial : Map[String, Bool],
) -> Map[String, Bool] {
  @bitflow.expand_affected_nodes(workspace_flow_nodes(manifest), initial)
}

///|
fn workspace_flow_cache_key(task : String, node_id : String) -> String {
  @bitflow.flow_cache_key(task, node_id)
}

///|
fn workspace_flow_fingerprint(
  task : String,
  task_cmd : String,
  node : WorkspaceNode,
  signatures : Map[String, String],
) -> String {
  @bitflow.flow_fingerprint(
    task,
    task_cmd,
    @bitflow.new_node(node.id, node.depends_on, required=node.required),
    signatures,
  )
}

///|
pub fn print_workspace_usage() -> Unit {
  let usage =
    #|Usage: bit workspace <command> [options]
    #|       bit ws <command> [options]
    #|
    #|Commands:
    #|  init [--force] [--template default|flow]
    #|                      Initialize workspace metadata (optional scaffold)
    #|  status              Show workspace node statuses
    #|  commit -m <msg>     Commit changed nodes as one workspace transaction
    #|  push [--resume ID]  Push nodes in dependency order
    #|  run <task>          Run configured task in nodes
    #|  flow <task>         Run topological workflow with success cache
    #|  export --format git-interop
    #|                      Export workspace interoperability metadata
    #|  doctor              Validate workspace consistency
    #|
    #|Inside a workspace, `bit <workspace-command>` is automatically translated
    #|to `bit workspace <workspace-command>`.
  println(usage)
}

///|
pub fn print_repo_usage() -> Unit {
  let usage =
    #|Usage: bit repo <command> [args...]
    #|
    #|Bypass workspace implicit command translation and run regular bit commands.
    #|
    #|Examples:
    #|  bit repo status
    #|  bit repo commit -m "local commit"
    #|  bit repo push origin main
  println(usage)
}

///|
pub fn workspace_translate_implicit_command(
  cwd : String?,
  cmd : String,
  rest : Array[String],
) -> (String, Array[String]) {
  if cmd == "workspace" || cmd == "ws" || cmd == "repo" {
    return (cmd, rest)
  }
  if not(is_workspace_subcommand_name(cmd)) {
    return (cmd, rest)
  }
  let probe = resolve_workspace_probe_dir(cwd)
  if find_workspace_root_from(probe) is None {
    return (cmd, rest)
  }
  let next_rest : Array[String] = [cmd]
  for arg in rest {
    next_rest.push(arg)
  }
  ("workspace", next_rest)
}

///|
fn workspace_record_step(
  steps : Array[WorkspaceTxnStep],
  node : WorkspaceNode,
  command : String,
  status : String,
  message : String,
) -> Unit {
  steps.push({
    node_id: node.id,
    path: node.path,
    command,
    status,
    required: node.required,
    message,
  })
}

///|
fn workspace_txn_id(prefix : String) -> String {
  prefix +
  "-" +
  get_current_timestamp().to_string() +
  "-" +
  @async.now().to_string()
}

///|
async fn handle_workspace_init(args : Array[String]) -> Unit raise Error {
  let fs = @osfs.OsFs::new()
  let mut force = false
  let mut template : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-f" | "--force" => force = true
      "--template" if i + 1 < args.length() => {
        template = Some(args[i + 1])
        i += 2
        continue
      }
      "-h" | "--help" => {
        print_workspace_usage()
        return
      }
      _ if arg.has_prefix("--template=") =>
        template = Some(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
      _ if arg.has_prefix("-") => warn_unimplemented_arg("workspace init", arg)
      _ => ()
    }
    i += 1
  }
  let start = resolve_workspace_probe_dir(None)
  match find_workspace_root_from(start) {
    Some(existing_root) if not(force) => {
      println("workspace already initialized at " + existing_root)
      return
    }
    _ => ()
  }
  let target_root = start
  let _ = ensure_workspace_meta_dir(fs, target_root)
  let manifest = workspace_manifest_for_template(template)
  fs.write_string(
    workspace_manifest_write_path(fs, target_root),
    format_workspace_manifest(manifest),
  )
  write_workspace_lock_snapshot(fs, target_root, manifest)
  println("Initialized workspace at " + target_root)
}

///|
async fn handle_workspace_status(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg == "-h" || arg == "--help" {
      print_workspace_usage()
      return
    }
    if arg.has_prefix("-") {
      warn_unimplemented_arg("workspace status", arg)
    }
  }
  let fs = @osfs.OsFs::new()
  let workspace_root = require_workspace_root(None)
  let manifest = load_workspace_manifest(fs, workspace_root)
  require_workspace_manifest_valid(fs, workspace_root, manifest, "status")
  let lock_commits = read_workspace_lock_commits(fs, workspace_root)
  let ordered = workspace_topological_nodes(manifest)
  println("workspace root: " + workspace_root)
  for node in ordered {
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    let repo_exists = workspace_node_git_dir(fs, node_root) is Some(_)
    let dirty = workspace_is_node_dirty(fs, node_root)
    let head = workspace_node_head_hex(fs, node_root).unwrap_or("-")
    let lock_head = lock_commits.get(node.id).unwrap_or("-")
    let drift = head != "-" && lock_head != "-" && head != lock_head
    let summary = StringBuilder::new()
    summary.write_string("- ")
    summary.write_string(node.id)
    summary.write_string(" (")
    summary.write_string(node.path)
    summary.write_string(")")
    summary.write_string(" required=")
    summary.write_string(if node.required { "true" } else { "false" })
    summary.write_string(" repo=")
    summary.write_string(if repo_exists { "ok" } else { "missing" })
    summary.write_string(" dirty=")
    summary.write_string(if dirty { "yes" } else { "no" })
    summary.write_string(" drift=")
    summary.write_string(if drift { "yes" } else { "no" })
    summary.write_string(" head=")
    summary.write_string(head)
    summary.write_string(" lock=")
    summary.write_string(lock_head)
    println(summary.to_string())
  }
}

///|
async fn handle_workspace_commit(
  args : Array[String],
  run_repo_builtin_in_dir : async (String, String, Array[String]) -> (
    Int,
    String,
  ),
) -> Unit raise Error {
  let mut message : String? = None
  let mut allow_empty = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "--message" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "--allow-empty" => allow_empty = true
      "-h" | "--help" => {
        print_workspace_usage()
        return
      }
      _ if arg.has_prefix("--message=") =>
        message = Some(
          String::unsafe_substring(arg, start=10, end=arg.length()),
        )
      _ if arg.has_prefix("-") =>
        warn_unimplemented_arg("workspace commit", arg)
      _ => ()
    }
    i += 1
  }
  guard message is Some(raw_message) else {
    raise @git.GitError::InvalidObject("workspace commit requires -m <message>")
  }
  let fs = @osfs.OsFs::new()
  let workspace_root = require_workspace_root(None)
  let manifest = load_workspace_manifest(fs, workspace_root)
  require_workspace_manifest_valid(fs, workspace_root, manifest, "commit")
  let ordered = workspace_topological_nodes(manifest)
  let txn_id = workspace_txn_id("commit")
  let txn_message = raw_message + "\n\nBit-Workspace-Txn: " + txn_id
  let steps : Array[WorkspaceTxnStep] = []
  let mut required_failed = false
  for node in ordered {
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    let repo_exists = workspace_node_git_dir(fs, node_root) is Some(_)
    if not(repo_exists) {
      workspace_record_step(
        steps, node, "commit", "failed", "repository marker not found",
      )
      if node.required {
        required_failed = true
      }
      continue
    }
    let dirty = workspace_is_node_dirty(fs, node_root)
    if not(dirty) && not(allow_empty) {
      workspace_record_step(steps, node, "commit", "skipped", "clean")
      continue
    }
    let commit_args : Array[String] = ["-m", txn_message]
    if allow_empty {
      commit_args.push("--allow-empty")
    }
    let (code, err) = run_repo_builtin_in_dir(node_root, "commit", commit_args)
    if code == 0 {
      workspace_record_step(steps, node, "commit", "success", "")
    } else {
      workspace_record_step(
        steps,
        node,
        "commit",
        "failed",
        if err.length() == 0 {
          "commit failed"
        } else {
          err
        },
      )
      if node.required {
        required_failed = true
      }
    }
  }
  let _ = ensure_workspace_meta_dir(fs, workspace_root)
  let state = if required_failed { "partial_failed" } else { "completed" }
  write_workspace_txn(fs, workspace_root, txn_id, "commit", state, steps)
  write_workspace_lock_snapshot(fs, workspace_root, manifest)
  println("workspace commit txn: " + txn_id + " (" + state + ")")
  if required_failed {
    raise @git.GitError::InvalidObject(
      "workspace commit failed on required nodes (txn: " + txn_id + ")",
    )
  }
}

///|
async fn handle_workspace_push(
  args : Array[String],
  run_repo_builtin_in_dir : async (String, String, Array[String]) -> (
    Int,
    String,
  ),
) -> Unit raise Error {
  let mut resume_txn : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--resume" if i + 1 < args.length() => {
        resume_txn = Some(args[i + 1])
        i += 2
        continue
      }
      "-h" | "--help" => {
        print_workspace_usage()
        return
      }
      _ if arg.has_prefix("--resume=") =>
        resume_txn = Some(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
      _ if arg.has_prefix("-") => warn_unimplemented_arg("workspace push", arg)
      _ => ()
    }
    i += 1
  }
  let fs = @osfs.OsFs::new()
  let workspace_root = require_workspace_root(None)
  let manifest = load_workspace_manifest(fs, workspace_root)
  require_workspace_manifest_valid(fs, workspace_root, manifest, "push")
  let ordered = workspace_topological_nodes(manifest)
  let txn_id = match resume_txn {
    Some(id) => id
    None => workspace_txn_id("push")
  }
  let completed = read_successful_push_nodes(fs, workspace_root, txn_id)
  let steps : Array[WorkspaceTxnStep] = []
  let mut required_failed = false
  for node in ordered {
    if completed.get(node.id) is Some(_) {
      workspace_record_step(
        steps, node, "push", "skipped", "already pushed in resume",
      )
      continue
    }
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    let repo_exists = workspace_node_git_dir(fs, node_root) is Some(_)
    if not(repo_exists) {
      workspace_record_step(
        steps, node, "push", "failed", "repository marker not found",
      )
      if node.required {
        required_failed = true
        break
      }
      continue
    }
    let (code, err) = run_repo_builtin_in_dir(node_root, "push", [])
    if code == 0 {
      workspace_record_step(steps, node, "push", "success", "")
    } else {
      workspace_record_step(
        steps,
        node,
        "push",
        "failed",
        if err.length() == 0 {
          "push failed"
        } else {
          err
        },
      )
      if node.required {
        required_failed = true
        break
      }
    }
  }
  let _ = ensure_workspace_meta_dir(fs, workspace_root)
  let state = if required_failed { "partial_failed" } else { "completed" }
  write_workspace_txn(fs, workspace_root, txn_id, "push", state, steps)
  write_workspace_lock_snapshot(fs, workspace_root, manifest)
  println("workspace push txn: " + txn_id + " (" + state + ")")
  if required_failed {
    raise @git.GitError::InvalidObject(
      "workspace push failed on required nodes (txn: " + txn_id + ")",
    )
  }
}

///|
async fn handle_workspace_run(args : Array[String]) -> Unit raise Error {
  let mut affected_only = false
  let mut task_name : String? = None
  for arg in args {
    match arg {
      "--affected" => affected_only = true
      "-h" | "--help" => {
        print_workspace_usage()
        return
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("workspace run", arg)
      _ => if task_name is None { task_name = Some(arg) }
    }
  }
  guard task_name is Some(task) else {
    raise @git.GitError::InvalidObject("workspace run requires <task>")
  }
  let fs = @osfs.OsFs::new()
  let workspace_root = require_workspace_root(None)
  let manifest = load_workspace_manifest(fs, workspace_root)
  require_workspace_manifest_valid(fs, workspace_root, manifest, "run")
  let fingerprint_mode = workspace_fingerprint_mode()
  let lock_signatures = read_workspace_lock_signatures(fs, workspace_root)
  let changed = collect_changed_node_ids(
    fs, workspace_root, manifest, lock_signatures, fingerprint_mode,
  )
  let selected = if affected_only {
    expand_affected_node_ids(manifest, changed)
  } else {
    let all_ids : Map[String, Bool] = {}
    for node in manifest.nodes {
      all_ids[node.id] = true
    }
    all_ids
  }
  let ordered = workspace_topological_nodes(manifest)
  let txn_id = workspace_txn_id("run-" + task)
  let steps : Array[WorkspaceTxnStep] = []
  let mut required_failed = false
  for node in ordered {
    if selected.get(node.id) is None {
      continue
    }
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    match node.tasks.get(task) {
      Some(task_cmd) => {
        println("workspace run[\{node.id}]: \{task_cmd}")
        let code = @process.run(
          "sh",
          ["-lc", task_cmd],
          inherit_env=true,
          cwd=node_root,
        ) catch {
          _ => 1
        }
        if code == 0 {
          workspace_record_step(steps, node, "run", "success", task)
        } else {
          workspace_record_step(
            steps,
            node,
            "run",
            "failed",
            "task '\{task}' failed with exit \{code}",
          )
          if node.required {
            required_failed = true
          }
        }
      }
      None =>
        workspace_record_step(
          steps,
          node,
          "run",
          "skipped",
          "task '\{task}' not configured",
        )
    }
  }
  let _ = ensure_workspace_meta_dir(fs, workspace_root)
  let state = if required_failed { "partial_failed" } else { "completed" }
  write_workspace_txn(fs, workspace_root, txn_id, "run", state, steps)
  println("workspace run txn: " + txn_id + " (" + state + ")")
  if required_failed {
    raise @git.GitError::InvalidObject(
      "workspace run failed on required nodes (txn: " + txn_id + ")",
    )
  }
}

///|
async fn handle_workspace_flow(args : Array[String]) -> Unit raise Error {
  let mut affected_only = false
  let mut no_cache = false
  let mut reset_cache = false
  let mut task_name : String? = None
  for arg in args {
    match arg {
      "--affected" => affected_only = true
      "--no-cache" => no_cache = true
      "--reset-cache" | "--clear-cache" => reset_cache = true
      "-h" | "--help" => {
        print_workspace_usage()
        return
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("workspace flow", arg)
      _ => if task_name is None { task_name = Some(arg) }
    }
  }
  guard task_name is Some(task) else {
    raise @git.GitError::InvalidObject("workspace flow requires <task>")
  }
  let fs = @osfs.OsFs::new()
  let workspace_root = require_workspace_root(None)
  let manifest = load_workspace_manifest(fs, workspace_root)
  require_workspace_manifest_valid(fs, workspace_root, manifest, "flow")
  let fingerprint_mode = workspace_fingerprint_mode()
  let lock_signatures = read_workspace_lock_signatures(fs, workspace_root)
  let changed = collect_changed_node_ids(
    fs, workspace_root, manifest, lock_signatures, fingerprint_mode,
  )
  let selected = if affected_only {
    expand_affected_node_ids(manifest, changed)
  } else {
    let all_ids : Map[String, Bool] = {}
    for node in manifest.nodes {
      all_ids[node.id] = true
    }
    all_ids
  }
  let flow_ir = workspace_flow_ir(manifest, selected, task)
  let flow_issues = @bitflow.ir_issues(flow_ir)
  if flow_issues.length() > 0 {
    raise @git.GitError::InvalidObject(
      "workspace flow invalid: " + flow_issues[0],
    )
  }
  let ordered_ids = @bitflow.topological_nodes(flow_ir.nodes).map(node => {
    node.id
  })
  let node_map = workspace_node_map(manifest)
  let node_signatures : Map[String, String] = {}
  let node_repo_exists : Map[String, Bool] = {}
  for node in manifest.nodes {
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    match
      workspace_node_directory_signature_with_mode(
        fs, node_root, fingerprint_mode,
      ) {
      Some(signature) => {
        node_repo_exists[node.id] = true
        node_signatures[node.id] = signature
      }
      None => {
        node_repo_exists[node.id] = false
        node_signatures[node.id] = "missing"
      }
    }
  }
  let flow_cache = if no_cache {
    {}
  } else {
    read_workspace_flow_cache(fs, workspace_root)
  }
  if reset_cache {
    flow_cache.clear()
  }
  let txn_id = workspace_txn_id("flow-" + task)
  let steps : Array[WorkspaceTxnStep] = []
  let node_success : Map[String, Bool] = {}
  let node_ran : Map[String, Bool] = {}
  let mut required_failed = false
  for node_id in ordered_ids {
    guard node_map.get(node_id) is Some(node) else { continue }
    let blocked_deps : Array[String] = []
    for dep in node.depends_on {
      if selected.get(dep) is None {
        continue
      }
      let dep_ok = node_success.get(dep).unwrap_or(false)
      if not(dep_ok) {
        blocked_deps.push(dep)
      }
    }
    if blocked_deps.length() > 0 {
      workspace_record_step(
        steps,
        node,
        "flow",
        "blocked",
        "blocked by dependency: " + blocked_deps.join(", "),
      )
      node_success[node.id] = false
      if node.required {
        required_failed = true
      }
      continue
    }
    let node_root = workspace_node_abs_path(workspace_root, node.path)
    let repo_exists = node_repo_exists.get(node.id).unwrap_or(false)
    if not(repo_exists) {
      workspace_record_step(
        steps, node, "flow", "failed", "repository marker not found",
      )
      node_success[node.id] = false
      if node.required {
        required_failed = true
      }
      continue
    }
    match node.tasks.get(task) {
      Some(task_cmd) => {
        let cache_key = workspace_flow_cache_key(task, node.id)
        let fingerprint = workspace_flow_fingerprint(
          task, task_cmd, node, node_signatures,
        )
        let mut dep_ran = false
        for dep in node.depends_on {
          if selected.get(dep) is None {
            continue
          }
          if node_ran.get(dep).unwrap_or(false) {
            dep_ran = true
            break
          }
        }
        if not(no_cache) && not(dep_ran) {
          match flow_cache.get(cache_key) {
            Some(prev) if prev == fingerprint => {
              workspace_record_step(steps, node, "flow", "cached", task)
              node_success[node.id] = true
              node_ran[node.id] = false
              continue
            }
            _ => ()
          }
        }
        println("workspace flow[\{node.id}]: \{task_cmd}")
        let code = @process.run(
          "sh",
          ["-lc", task_cmd],
          inherit_env=true,
          cwd=node_root,
        ) catch {
          _ => 1
        }
        if code == 0 {
          workspace_record_step(steps, node, "flow", "success", task)
          node_success[node.id] = true
          node_ran[node.id] = true
          if not(no_cache) {
            flow_cache[cache_key] = fingerprint
          }
        } else {
          workspace_record_step(
            steps,
            node,
            "flow",
            "failed",
            "task '\{task}' failed with exit \{code}",
          )
          node_success[node.id] = false
          node_ran[node.id] = true
          if not(no_cache) {
            flow_cache.remove(cache_key)
          }
          if node.required {
            required_failed = true
          }
        }
      }
      None => {
        workspace_record_step(
          steps,
          node,
          "flow",
          "skipped",
          "task '\{task}' not configured",
        )
        node_success[node.id] = true
        node_ran[node.id] = false
      }
    }
  }
  let _ = ensure_workspace_meta_dir(fs, workspace_root)
  if not(no_cache) {
    write_workspace_flow_cache(fs, workspace_root, flow_cache)
  }
  let state = if required_failed { "partial_failed" } else { "completed" }
  write_workspace_txn(fs, workspace_root, txn_id, "flow:" + task, state, steps)
  println("workspace flow txn: " + txn_id + " (" + state + ")")
  if required_failed {
    raise @git.GitError::InvalidObject(
      "workspace flow failed on required nodes (txn: " + txn_id + ")",
    )
  }
}

///|
async fn handle_workspace_export(args : Array[String]) -> Unit raise Error {
  let mut format : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--format" if i + 1 < args.length() => {
        format = Some(args[i + 1])
        i += 2
        continue
      }
      "-h" | "--help" => {
        print_workspace_usage()
        return
      }
      _ if arg.has_prefix("--format=") =>
        format = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
      _ if arg.has_prefix("-") =>
        warn_unimplemented_arg("workspace export", arg)
      _ => ()
    }
    i += 1
  }
  guard format is Some(fmt) && fmt == "git-interop" else {
    raise @git.GitError::InvalidObject(
      "workspace export requires --format git-interop",
    )
  }
  let fs = @osfs.OsFs::new()
  let workspace_root = require_workspace_root(None)
  let manifest = load_workspace_manifest(fs, workspace_root)
  require_workspace_manifest_valid(fs, workspace_root, manifest, "export")
  let lock_commits = read_workspace_lock_commits(fs, workspace_root)
  let nodes_json : Array[Json] = []
  for node in manifest.nodes {
    let obj : Map[String, Json] = {}
    obj["id"] = Json::string(node.id)
    obj["path"] = Json::string(node.path)
    obj["required"] = Json::boolean(node.required)
    obj["commit"] = Json::string(lock_commits.get(node.id).unwrap_or(""))
    obj["depends_on"] = Json::array(
      node.depends_on.map(dep => Json::string(dep)),
    )
    match node.remote {
      Some(remote) => obj["remote"] = Json::string(remote)
      None => ()
    }
    match node.branch {
      Some(branch) => obj["branch"] = Json::string(branch)
      None => ()
    }
    nodes_json.push(Json::object(obj))
  }
  let out_obj : Map[String, Json] = {}
  out_obj["schema"] = Json::string("bit.workspace.git-interop.v1")
  out_obj["workspace_root"] = Json::string(workspace_root)
  out_obj["generated_at"] = Json::number(
    get_current_timestamp().to_double(),
    repr=get_current_timestamp().to_string(),
  )
  out_obj["nodes"] = Json::array(nodes_json)
  let out_path = workspace_meta_dir_for_root(fs, workspace_root) +
    "/workspace.git-interop.json"
  fs.write_string(out_path, Json::object(out_obj).stringify(indent=2))
  println(out_path)
}

///|
async fn handle_workspace_doctor(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg == "-h" || arg == "--help" {
      print_workspace_usage()
      return
    }
    if arg.has_prefix("-") {
      warn_unimplemented_arg("workspace doctor", arg)
    }
  }
  let fs = @osfs.OsFs::new()
  let workspace_root = require_workspace_root(None)
  let manifest = load_workspace_manifest(fs, workspace_root)
  let issues = workspace_manifest_issues(fs, workspace_root, manifest, true)
  if issues.length() == 0 {
    println("workspace doctor: ok")
    return
  }
  for issue in issues {
    eprint_line("workspace doctor: " + issue)
  }
  raise @git.GitError::InvalidObject("workspace doctor found issues")
}

///|
pub async fn handle_workspace(
  args : Array[String],
  run_repo_builtin_in_dir : async (String, String, Array[String]) -> (
    Int,
    String,
  ),
) -> Unit raise Error {
  if args.length() == 0 {
    print_workspace_usage()
    return
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "-h" | "--help" | "help" => print_workspace_usage()
    "init" => handle_workspace_init(rest)
    "status" => handle_workspace_status(rest)
    "commit" => handle_workspace_commit(rest, run_repo_builtin_in_dir)
    "push" => handle_workspace_push(rest, run_repo_builtin_in_dir)
    "run" => handle_workspace_run(rest)
    "flow" => handle_workspace_flow(rest)
    "export" => handle_workspace_export(rest)
    "doctor" => handle_workspace_doctor(rest)
    _ => {
      eprint_line("bit workspace: unknown subcommand '\{subcmd}'")
      print_workspace_usage()
    }
  }
}
