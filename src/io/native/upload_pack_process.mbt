///| Upload-pack over git-upload-pack (native targets)

///|
priv struct ProcessSpec {
  cmd : String
  args : Array[String]
  extra_env : Map[String, String]?
}

///|
priv enum SshVariant {
  Ssh
  Plink
  TortoisePlink
  Simple
} derive(Eq)

///|
priv struct SshCommandSpec {
  cmd : String
  args : Array[String]
}

///|
priv struct SshEndpoint {
  host : String
  path : String
  port : String?
}

///|
fn is_space_char(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn split_shell_words(cmdline : String) -> Array[String] raise @git.GitError {
  let out : Array[String] = []
  let current = StringBuilder::new()
  let mut in_single = false
  let mut in_double = false
  let mut escaped = false
  let mut token_active = false
  for c in cmdline {
    if escaped {
      current.write_char(c)
      token_active = true
      escaped = false
      continue
    }
    if in_single {
      if c == '\'' {
        in_single = false
      } else {
        current.write_char(c)
        token_active = true
      }
      continue
    }
    if in_double {
      if c == '"' {
        in_double = false
      } else if c == '\\' {
        escaped = true
      } else {
        current.write_char(c)
        token_active = true
      }
      continue
    }
    if c == '\\' {
      escaped = true
      continue
    }
    if c == '\'' {
      in_single = true
      continue
    }
    if c == '"' {
      in_double = true
      continue
    }
    if is_space_char(c) {
      if token_active {
        out.push(current.to_string())
        current.reset()
        token_active = false
      }
      continue
    }
    current.write_char(c)
    token_active = true
  }
  if escaped || in_single || in_double {
    raise @git.GitError::ProtocolError("Malformed GIT_SSH_COMMAND")
  }
  if token_active {
    out.push(current.to_string())
  }
  if out.length() == 0 {
    raise @git.GitError::ProtocolError("Malformed GIT_SSH_COMMAND")
  }
  out
}

///|
fn command_basename(path : String) -> String {
  match path.rev_find("/") {
    Some(idx) =>
      String::unsafe_substring(path, start=idx + 1, end=path.length())
    None => path
  }
}

///|
fn is_digits(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if c < '0' || c > '9' {
      return false
    }
  }
  true
}

///|
fn normalize_ssh_path(path : String) -> String {
  if path.has_prefix("/~") {
    String::unsafe_substring(path, start=1, end=path.length())
  } else {
    path
  }
}

///|
fn split_bracket_host_port(value : String) -> (String, String?) {
  match (value.find(":"), value.rev_find(":")) {
    (Some(first), Some(last)) if first == last => {
      let host = String::unsafe_substring(value, start=0, end=first)
      let port = String::unsafe_substring(
        value,
        start=first + 1,
        end=value.length(),
      )
      if host.length() > 0 && is_digits(port) {
        (host, Some(port))
      } else {
        (value, None)
      }
    }
    _ => (value, None)
  }
}

///|
fn parse_scp_endpoint(raw : String) -> SshEndpoint? {
  if raw.has_prefix("[") {
    match raw.find("]:") {
      Some(idx) => {
        let inside = String::unsafe_substring(raw, start=1, end=idx)
        let path = String::unsafe_substring(
          raw,
          start=idx + 2,
          end=raw.length(),
        )
        if inside.length() == 0 || path.length() == 0 || inside.contains("/") {
          None
        } else {
          let (host, port) = split_bracket_host_port(inside)
          Some({ host, path: normalize_ssh_path(path), port })
        }
      }
      None => None
    }
  } else {
    match raw.find(":") {
      Some(idx) => {
        let host = String::unsafe_substring(raw, start=0, end=idx)
        let path = String::unsafe_substring(
          raw,
          start=idx + 1,
          end=raw.length(),
        )
        if host.length() == 0 || path.length() == 0 || host.contains("/") {
          None
        } else {
          Some({ host, path: normalize_ssh_path(path), port: None })
        }
      }
      None => None
    }
  }
}

///|
fn parse_ssh_authority(authority : String) -> (String, String?) {
  if authority.has_prefix("[") {
    match authority.find("]") {
      Some(end_idx) => {
        let host = String::unsafe_substring(authority, start=1, end=end_idx)
        let rest = String::unsafe_substring(
          authority,
          start=end_idx + 1,
          end=authority.length(),
        )
        if rest.has_prefix(":") && rest.length() > 1 {
          let port = String::unsafe_substring(rest, start=1, end=rest.length())
          if is_digits(port) {
            return (host, Some(port))
          }
        }
        (host, None)
      }
      None => (authority, None)
    }
  } else {
    let mut user_prefix = ""
    let mut host_part = authority
    match authority.find("@") {
      Some(at_idx) => {
        user_prefix = String::unsafe_substring(
          authority,
          start=0,
          end=at_idx + 1,
        )
        host_part = String::unsafe_substring(
          authority,
          start=at_idx + 1,
          end=authority.length(),
        )
      }
      None => ()
    }
    if host_part.has_prefix("[") {
      match host_part.find("]") {
        Some(end_idx) => {
          let host = String::unsafe_substring(host_part, start=1, end=end_idx)
          let rest = String::unsafe_substring(
            host_part,
            start=end_idx + 1,
            end=host_part.length(),
          )
          if rest.has_prefix(":") && rest.length() > 1 {
            let port = String::unsafe_substring(
              rest,
              start=1,
              end=rest.length(),
            )
            if is_digits(port) {
              return (user_prefix + host, Some(port))
            }
          }
          return (user_prefix + host, None)
        }
        None => ()
      }
    }
    let host_clean = if host_part.has_suffix(":") {
      String::unsafe_substring(host_part, start=0, end=host_part.length() - 1)
    } else {
      host_part
    }
    match (host_clean.find(":"), host_clean.rev_find(":")) {
      (Some(first), Some(last)) if first == last => {
        let host = String::unsafe_substring(host_clean, start=0, end=first)
        let port = String::unsafe_substring(
          host_clean,
          start=first + 1,
          end=host_clean.length(),
        )
        if host.length() > 0 && is_digits(port) {
          (user_prefix + host, Some(port))
        } else {
          (user_prefix + host_clean, None)
        }
      }
      _ => (user_prefix + host_clean, None)
    }
  }
}

///|
fn parse_ssh_url_endpoint(raw : String) -> SshEndpoint? {
  if not(raw.has_prefix("ssh://")) {
    return None
  }
  let rest = String::unsafe_substring(raw, start=6, end=raw.length())
  let (authority, path) = match rest.find("/") {
    Some(idx) => {
      let auth = String::unsafe_substring(rest, start=0, end=idx)
      let tail = String::unsafe_substring(
        rest,
        start=idx + 1,
        end=rest.length(),
      )
      (auth, "/" + tail)
    }
    None => (rest, "")
  }
  let (host, port) = parse_ssh_authority(authority)
  if host.length() == 0 || path.length() == 0 {
    return None
  }
  Some({ host, path: normalize_ssh_path(path), port })
}

///|
fn resolve_ssh_endpoint(spec : @protocol.RemoteSpec) -> SshEndpoint? {
  if spec.raw.has_prefix("ssh://") {
    return parse_ssh_url_endpoint(spec.raw)
  }
  match parse_scp_endpoint(spec.raw) {
    Some(endpoint) => Some(endpoint)
    None =>
      match spec.host {
        Some(host) =>
          if spec.path.length() > 0 {
            Some({ host, path: normalize_ssh_path(spec.path), port: None })
          } else {
            None
          }
        None => None
      }
  }
}

///|
fn detect_named_ssh_variant(base_name : String) -> SshVariant? {
  let name = base_name.to_lower()
  if name == "ssh" || name == "ssh.exe" {
    Some(Ssh)
  } else if name == "plink" ||
    name == "plink.exe" ||
    name == "putty" ||
    name == "putty.exe" {
    Some(Plink)
  } else if name == "tortoiseplink" || name == "tortoiseplink.exe" {
    Some(TortoisePlink)
  } else if name == "simple" {
    Some(Simple)
  } else {
    None
  }
}

///|
fn command_looks_like_script(cmd : String) -> Bool {
  if cmd.find("/") is None {
    return false
  }
  let data = @fs.read_file_to_bytes(cmd) catch { _ => return false }
  data.length() >= 2 && data[0] == b'#' && data[1] == b'!'
}

///|
fn read_ssh_variant_override() -> String? {
  match @sys.get_env_var("GIT_SSH_VARIANT") {
    Some(value) => Some(value.to_lower())
    None =>
      match @sys.get_env_var("GIT_CONFIG_OVERRIDES") {
        None => None
        Some(overrides) => {
          for line_view in overrides.split("\n") {
            let line = line_view.to_string()
            if line.length() == 0 {
              continue
            }
            match line.find("=") {
              Some(eq_idx) => {
                let key = String::unsafe_substring(line, start=0, end=eq_idx).to_lower()
                if key == "ssh.variant" {
                  return Some(
                    String::unsafe_substring(
                      line,
                      start=eq_idx + 1,
                      end=line.length(),
                    ).to_lower(),
                  )
                }
              }
              None => ()
            }
          }
          None
        }
      }
  }
}

///|
fn resolve_ssh_variant(
  cmd : String,
  needs_special_options : Bool,
) -> SshVariant {
  let base_name = command_basename(cmd)
  let auto_variant = match detect_named_ssh_variant(base_name) {
    Some(v) => v
    None =>
      if needs_special_options && command_looks_like_script(cmd) {
        Ssh
      } else {
        Simple
      }
  }
  match read_ssh_variant_override() {
    Some("ssh") => Ssh
    Some("plink") | Some("putty") => Plink
    Some("tortoiseplink") => TortoisePlink
    Some("simple") => Simple
    Some("auto") => auto_variant
    Some(_) => auto_variant
    None => auto_variant
  }
}

///|
fn resolve_ssh_command_spec() -> SshCommandSpec raise @git.GitError {
  match @sys.get_env_var("GIT_SSH_COMMAND") {
    Some(cmdline) => {
      let words = split_shell_words(cmdline)
      let cmd = words[0]
      let args : Array[String] = []
      for i in 1..<words.length() {
        args.push(words[i])
      }
      { cmd, args }
    }
    None =>
      match @sys.get_env_var("GIT_SSH") {
        Some(cmd) => { cmd, args: [] }
        None => { cmd: "ssh", args: [] }
      }
  }
}

///|
fn read_ssh_ip_option() -> String? {
  match @sys.get_env_var("BIT_SSH_IP_VERSION") {
    Some("-4") => Some("-4")
    Some("-6") => Some("-6")
    _ => None
  }
}

///|
fn build_upload_pack_remote_command(
  path : String,
  advertise_refs : Bool,
) -> String {
  let quoted_path = quote_shell_arg_single(path)
  if advertise_refs {
    "git-upload-pack --stateless-rpc --advertise-refs " + quoted_path
  } else {
    "git-upload-pack --stateless-rpc " + quoted_path
  }
}

///|
fn quote_shell_arg_single(value : String) -> String {
  let b = StringBuilder::new()
  b.write_char('\'')
  for c in value {
    if c == '\'' {
      b.write_string("'\\''")
    } else {
      b.write_char(c)
    }
  }
  b.write_char('\'')
  b.to_string()
}

///|
fn build_upload_pack_file_spec(
  path : String,
  advertise_refs : Bool,
  prefer_v2 : Bool,
) -> ProcessSpec raise @git.GitError {
  if path.length() == 0 {
    raise @git.GitError::ProtocolError("Remote path is empty")
  }
  let args : Array[String] = []
  args.push("--stateless-rpc")
  if advertise_refs {
    args.push("--advertise-refs")
  }
  args.push(path)
  let extra_env = if prefer_v2 {
    Some({ "GIT_PROTOCOL": "version=2" })
  } else {
    None
  }
  { cmd: "git-upload-pack", args, extra_env }
}

///|
fn build_upload_pack_process_spec(
  spec : @protocol.RemoteSpec,
  advertise_refs~ : Bool,
  prefer_v2~ : Bool,
) -> ProcessSpec raise @git.GitError {
  match spec.kind {
    @protocol.RemoteKind::Http =>
      raise @git.GitError::ProtocolError(
        "HTTP transport is not supported by process client",
      )
    @protocol.RemoteKind::File =>
      build_upload_pack_file_spec(spec.path, advertise_refs, prefer_v2)
    @protocol.RemoteKind::Ssh => {
      let endpoint = match resolve_ssh_endpoint(spec) {
        Some(v) => v
        None => raise @git.GitError::ProtocolError("SSH remote missing host")
      }
      let ip_option = read_ssh_ip_option()
      let needs_special_options = endpoint.port is Some(_) ||
        ip_option is Some(_)
      let ssh = resolve_ssh_command_spec()
      let variant = resolve_ssh_variant(ssh.cmd, needs_special_options)
      let args : Array[String] = []
      for arg in ssh.args {
        args.push(arg)
      }
      if variant == TortoisePlink {
        args.push("-batch")
      }
      match ip_option {
        Some(flag) =>
          if variant == Simple {
            raise @git.GitError::ProtocolError(
              "ssh variant 'simple' does not support setting address family",
            )
          } else {
            args.push(flag)
          }
        None => ()
      }
      match endpoint.port {
        Some(port) =>
          match variant {
            Ssh => {
              args.push("-p")
              args.push(port)
            }
            Plink | TortoisePlink => {
              args.push("-P")
              args.push(port)
            }
            Simple =>
              raise @git.GitError::ProtocolError(
                "ssh variant 'simple' does not support setting port",
              )
          }
        None => ()
      }
      args.push(endpoint.host)
      args.push(build_upload_pack_remote_command(endpoint.path, advertise_refs))
      let extra_env = if prefer_v2 {
        Some({ "GIT_PROTOCOL": "version=2" })
      } else {
        None
      }
      { cmd: ssh.cmd, args, extra_env }
    }
  }
}

///|
fn bytes_to_string_lossy(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn cleanup_temp_files(paths : Array[String]) -> Unit {
  for path in paths {
    @fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
fn resolve_process_cwd() -> String? {
  match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => Some(dir)
    None => @sys.get_env_var("GIT_SHIM_PWD")
  }
}

///|
fn maybe_trace_packfile(pack : Bytes) -> Unit {
  match @sys.get_env_var("GIT_TRACE_PACKFILE") {
    Some(path) => ignore(@fs.write_bytes_to_file(path, pack) catch { _ => () })
    None => ()
  }
}

///|
async fn run_process_with_files(
  spec : ProcessSpec,
  stdin_data : Bytes?,
) -> (Int, Bytes, Bytes) raise @git.GitError {
  let nonce = @async.now()
  let base = ".moonbit-git-upload-pack-\{nonce}"
  let stdout_path = "\{base}.out"
  let stderr_path = "\{base}.err"
  let stdin_path = "\{base}.in"
  let cleanup_paths = [stdout_path, stderr_path, stdin_path]
  let stdout = @process.redirect_to_file(stdout_path, truncate=true, create=420) catch {
    e => raise @git.GitError::IoError("failed to open stdout file: \{e}")
  }
  let stderr = @process.redirect_to_file(stderr_path, truncate=true, create=420) catch {
    e => raise @git.GitError::IoError("failed to open stderr file: \{e}")
  }
  let stdin_bytes = match stdin_data {
    Some(data) => data
    None => Bytes::default()
  }
  @fs.write_bytes_to_file(stdin_path, stdin_bytes) catch {
    e => raise @git.GitError::IoError("failed to write stdin temp file: \{e}")
  }
  let stdin = @process.redirect_from_file(stdin_path) catch {
    e => raise @git.GitError::IoError("process stdin failed: \{e}")
  }
  let run_cwd = resolve_process_cwd()
  let code = match (spec.extra_env, run_cwd) {
    (None, None) =>
      @process.run(
        spec.cmd,
        spec.args,
        inherit_env=true,
        stdin~,
        stdout~,
        stderr~,
      ) catch {
        e => {
          cleanup_temp_files(cleanup_paths)
          raise @git.GitError::IoError("process failed: \{e}")
        }
      }
    (Some(env), None) =>
      @process.run(
        spec.cmd,
        spec.args,
        extra_env=env,
        inherit_env=true,
        stdin~,
        stdout~,
        stderr~,
      ) catch {
        e => {
          cleanup_temp_files(cleanup_paths)
          raise @git.GitError::IoError("process failed: \{e}")
        }
      }
    (None, Some(cwd)) =>
      @process.run(
        spec.cmd,
        spec.args,
        inherit_env=true,
        stdin~,
        stdout~,
        stderr~,
        cwd~,
      ) catch {
        e => {
          cleanup_temp_files(cleanup_paths)
          raise @git.GitError::IoError("process failed: \{e}")
        }
      }
    (Some(env), Some(cwd)) =>
      @process.run(
        spec.cmd,
        spec.args,
        extra_env=env,
        inherit_env=true,
        stdin~,
        stdout~,
        stderr~,
        cwd~,
      ) catch {
        e => {
          cleanup_temp_files(cleanup_paths)
          raise @git.GitError::IoError("process failed: \{e}")
        }
      }
  }
  let out = @fs.read_file_to_bytes(stdout_path) catch {
    e => {
      cleanup_temp_files(cleanup_paths)
      raise @git.GitError::IoError("failed to read stdout: \{e}")
    }
  }
  let err = @fs.read_file_to_bytes(stderr_path) catch {
    e => {
      cleanup_temp_files(cleanup_paths)
      raise @git.GitError::IoError("failed to read stderr: \{e}")
    }
  }
  cleanup_temp_files(cleanup_paths)
  (code, out, err)
}

///|
async fn run_upload_pack_process(
  spec : ProcessSpec,
  stdin_data : Bytes?,
) -> Bytes raise @git.GitError {
  let (code, stdout, stderr) = run_process_with_files(spec, stdin_data)
  if code != 0 {
    let args_joined = spec.args.join(" ")
    let cmdline = "\{spec.cmd} \{args_joined}"
    let err = bytes_to_string_lossy(stderr)
    let detail = if err.length() > 0 { ": \{err}" } else { "" }
    raise @git.GitError::IoError(
      "git-upload-pack failed (exit=\{code}): \{cmdline}\{detail}",
    )
  }
  stdout
}

///|
fn build_upload_pack_info_refs_process_spec(
  remote : String,
  prefer_v2 : Bool,
) -> ProcessSpec raise @git.GitError {
  let remote_spec = @protocol.parse_remote(remote)
  build_upload_pack_process_spec(remote_spec, advertise_refs=true, prefer_v2~)
}

///|
fn build_upload_pack_request_process_spec(
  remote : String,
  prefer_v2 : Bool,
) -> ProcessSpec raise @git.GitError {
  let remote_spec = @protocol.parse_remote(remote)
  build_upload_pack_process_spec(remote_spec, advertise_refs=false, prefer_v2~)
}

///|
pub async fn upload_pack_info_refs_process(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  let proc = build_upload_pack_info_refs_process_spec(remote, prefer_v2)
  run_upload_pack_process(proc, None)
}

///|
pub async fn upload_pack_request_process(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  let proc = build_upload_pack_request_process_spec(remote, prefer_v2)
  run_upload_pack_process(proc, Some(body))
}

///|
pub async fn discover_upload_refs_process(
  remote : String,
  prefer_v2 : Bool,
) -> (
  Array[(@git.ObjectId, String)],
  Array[String],
  @protocol.ProtocolVersion,
  Map[String, String],
) raise @git.GitError {
  let adv = upload_pack_info_refs_process(remote, prefer_v2)
  let version = @protocol.detect_protocol_version(adv)
  if version == @protocol.ProtocolVersion::V2 {
    let caps = @protocol.parse_v2_advertised_caps(adv)
    let req = @protocol.build_ls_refs_request("git/moonbit", [
      "refs/heads/", "refs/tags/", "HEAD",
    ])
    let resp = upload_pack_request_process(remote, req, true)
    let parsed = @protocol.parse_ls_refs_response(resp)
    return (parsed.refs, caps, version, parsed.symrefs)
  }
  let refs = @protocol.parse_refs(adv)
  let caps = @protocol.parse_v0_advertised_caps(adv)
  (refs, caps, @protocol.ProtocolVersion::V0, {})
}

///|
pub async fn fetch_pack_process(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
) -> Bytes raise @git.GitError {
  let (refs, caps, version, _symrefs) = discover_upload_refs_process(
    remote, prefer_v2,
  )
  let wants = if wants.length() == 0 {
    let ids : Array[@git.ObjectId] = []
    for item in refs {
      let (id, _) = item
      ids.push(id)
    }
    ids
  } else {
    wants
  }
  if version == @protocol.ProtocolVersion::V2 {
    let req = @protocol.build_fetch_request_v2(
      "git/moonbit",
      wants,
      depth,
      filter~,
    )
    let resp = upload_pack_request_process(remote, req, true)
    let pack = @protocol.extract_pack_from_v2_response(resp)
    maybe_trace_packfile(pack)
    return pack
  }
  let req = @protocol.build_fetch_request_v0("git/moonbit", wants, caps)
  let resp = upload_pack_request_process(remote, req, false)
  let pack = @protocol.extract_pack_from_v0_response(resp)
  maybe_trace_packfile(pack)
  pack
}

///|
pub async fn fetch_objects_process(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
) -> Array[@git.PackObject] raise @git.GitError {
  let pack = fetch_pack_process(remote, wants, prefer_v2, depth~, filter~)
  @pack.parse_packfile(pack)
}

///|
pub async fn clone_process(
  remote : String,
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
) -> (Array[(@git.ObjectId, String)], Array[@git.PackObject]) raise @git.GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_process(
    remote, prefer_v2,
  )
  let wants = @protocol.select_default_wants(refs, symrefs)
  let pack = fetch_pack_process(remote, wants, prefer_v2, depth~, filter~)
  let objects = @pack.parse_packfile(pack)
  (refs, objects)
}

///|
/// Clone and checkout into filesystem under `root`.
pub async fn clone_process_to_fs(
  remote : String,
  prefer_v2 : Bool,
  fs : &@git.FileSystem,
  root : String,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
  no_checkout? : Bool = false,
) -> Array[(@git.ObjectId, String)] raise @git.GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_process(
    remote, prefer_v2,
  )
  let wants = @protocol.select_default_wants(refs, symrefs)
  let default_ref = @protocol.select_default_ref(refs, symrefs)
  match default_ref {
    None => return refs
    Some(_) => ()
  }
  if wants.length() == 0 {
    return refs
  }
  let pack = fetch_pack_process(remote, wants, prefer_v2, depth~, filter~)
  let objects = @pack.parse_packfile(pack)
  let git_dir = @git.join_path(root, ".git")
  let pack_id = read_pack_trailer_id(pack)
  fs.mkdir_p(@git.join_path(git_dir, "objects/pack"))
  @pack.write_packfile_with_index(fs, git_dir, pack, objects)
  let effective_no_checkout = no_checkout || filter.is_partial()
  if filter.is_partial() {
    write_promisor_remote_file(fs, git_dir, remote)
    write_pack_promisor_marker(fs, git_dir, pack_id, refs, default_ref)
  }
  let store = @git.ObjectStore::from_pack(objects)
  match default_ref {
    None => ()
    Some((refname, commit_id)) =>
      if filter.is_partial() {
        write_partial_clone_metadata(
          fs, root, refname, commit_id, remote, filter,
        )
      } else if effective_no_checkout {
        @git.write_git_metadata(store, commit_id, refname, remote, fs, root)
      } else {
        @git.materialize_clone_to_fs(
          store, commit_id, refname, remote, fs, root,
        )
      }
  }
  if depth > 0 {
    let shallow_ids : Array[String] = []
    let seen : Map[String, Bool] = {}
    for id in wants {
      let hex = id.to_hex()
      if seen.contains(hex) {
        continue
      }
      seen[hex] = true
      shallow_ids.push(hex)
    }
    if shallow_ids.length() > 0 {
      fs.write_string(
        @git.join_path(git_dir, "shallow"),
        shallow_ids.join("\n") + "\n",
      )
    }
  }
  refs
}

///|
fn read_pack_trailer_id(pack : Bytes) -> @git.ObjectId raise @git.GitError {
  if pack.length() < 20 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  let trailer_start = pack.length() - 20
  let bytes = FixedArray::makei(20, i => pack[trailer_start + i])
  @git.ObjectId::new(bytes)
}

///|
fn write_promisor_remote_file(
  fs : &@git.FileSystem,
  git_dir : String,
  remote : String,
) -> Unit raise @git.GitError {
  let info_dir = @git.join_path(git_dir, "objects/info")
  fs.mkdir_p(info_dir)
  fs.write_string(@git.join_path(info_dir, "promisor"), remote + "\n")
}

///|
fn write_pack_promisor_marker(
  fs : &@git.FileSystem,
  git_dir : String,
  pack_id : @git.ObjectId,
  refs : Array[(@git.ObjectId, String)],
  default_ref : (String, @git.ObjectId)?,
) -> Unit raise @git.GitError {
  let pack_dir = @git.join_path(git_dir, "objects/pack")
  let marker_lines : Array[String] = []
  let seen : Map[String, Bool] = {}
  for item in refs {
    let (id, name) = item
    let line = id.to_hex() + " " + name
    if seen.contains(line) {
      continue
    }
    seen[line] = true
    marker_lines.push(line)
  }
  match default_ref {
    Some((_, head_id)) => {
      let head_line = head_id.to_hex() + " HEAD"
      if not(seen.contains(head_line)) {
        seen[head_line] = true
        marker_lines.push(head_line)
      }
    }
    None => ()
  }
  if marker_lines.length() == 0 {
    return ()
  }
  let marker_content = marker_lines.join("\n") + "\n"
  let base = "pack-\{pack_id.to_hex()}"
  let marker_path = @git.join_path(pack_dir, base + ".promisor")
  fs.write_string(marker_path, marker_content)
}

///|
fn write_partial_clone_metadata(
  fs : &@git.FileSystem,
  root : String,
  refname : String,
  commit_id : @git.ObjectId,
  remote : String,
  filter : @protocol.FilterSpec,
) -> Unit raise @git.GitError {
  let git_dir = @git.join_path(root, ".git")
  fs.mkdir_p(@git.join_path(git_dir, "objects/info"))
  fs.mkdir_p(@git.join_path(git_dir, "objects/pack"))
  fs.mkdir_p(@git.join_path(git_dir, "refs/heads"))
  fs.mkdir_p(@git.join_path(git_dir, "refs/tags"))
  fs.write_string(@git.join_path(git_dir, "HEAD"), "ref: \{refname}\n")
  let ref_path = @git.join_path(git_dir, refname)
  let ref_dir = match ref_path.rev_find("/") {
    Some(idx) => String::unsafe_substring(ref_path, start=0, end=idx)
    None => git_dir
  }
  fs.mkdir_p(ref_dir)
  fs.write_string(ref_path, commit_id.to_hex() + "\n")
  let filter_value = filter.to_string()
  let config_path = @git.join_path(git_dir, "config")
  let config =
    #|[core]
    #|	repositoryformatversion = 1
    #|	filemode = true
    #|	bare = false
    #|	logallrefupdates = true
    #|[extensions]
    #|	partialclone = origin
    $|[remote "origin"]
    $|	url = \{remote}
    #|	fetch = +refs/heads/*:refs/remotes/origin/*
    #|	promisor = true
    $|	partialclonefilter = \{filter_value}
    #|
  fs.write_string(config_path, config)
  let packed_refs_path = @git.join_path(git_dir, "packed-refs")
  fs.write_string(packed_refs_path, "# pack-refs with: peeled fully-peeled\n")
}
