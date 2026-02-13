///| Upload-pack over git-upload-pack (native targets)

///|
priv struct ProcessSpec {
  cmd : String
  args : Array[String]
  extra_env : Map[String, String]?
}

///|
fn ensure_remote_path(
  spec : @protocol.RemoteSpec,
) -> String raise @git.GitError {
  if spec.path.length() == 0 {
    raise @git.GitError::ProtocolError("Remote path is empty")
  }
  spec.path
}

///|
fn ssh_remote_path(spec : @protocol.RemoteSpec, path : String) -> String {
  if spec.raw.has_prefix("ssh://") && not(path.has_prefix("/")) {
    "/\{path}"
  } else {
    path
  }
}

///|
fn build_upload_pack_process_spec(
  spec : @protocol.RemoteSpec,
  advertise_refs~ : Bool,
  prefer_v2~ : Bool,
) -> ProcessSpec raise @git.GitError {
  let path = ensure_remote_path(spec)
  match spec.kind {
    @protocol.RemoteKind::Http =>
      raise @git.GitError::ProtocolError(
        "HTTP transport is not supported by process client",
      )
    @protocol.RemoteKind::File => {
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
    @protocol.RemoteKind::Ssh => {
      let host = match spec.host {
        None => raise @git.GitError::ProtocolError("SSH remote missing host")
        Some(v) => v
      }
      let args : Array[String] = [host]
      if prefer_v2 {
        args.push("env")
        args.push("GIT_PROTOCOL=version=2")
      }
      args.push("git-upload-pack")
      args.push("--stateless-rpc")
      if advertise_refs {
        args.push("--advertise-refs")
      }
      args.push(ssh_remote_path(spec, path))
      { cmd: "ssh", args, extra_env: None }
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
  let stdin = match stdin_data {
    None => None
    Some(data) => {
      @fs.write_bytes_to_file(stdin_path, data) catch {
        e =>
          raise @git.GitError::IoError("failed to write stdin temp file: \{e}")
      }
      let input = @process.redirect_from_file(stdin_path) catch {
        e => raise @git.GitError::IoError("process stdin failed: \{e}")
      }
      Some(input)
    }
  }
  let code = match spec.extra_env {
    None =>
      match stdin {
        None =>
          @process.run(spec.cmd, spec.args, inherit_env=true, stdout~, stderr~) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise @git.GitError::IoError("process failed: \{e}")
            }
          }
        Some(input) =>
          @process.run(
            spec.cmd,
            spec.args,
            inherit_env=true,
            stdin=input,
            stdout~,
            stderr~,
          ) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise @git.GitError::IoError("process failed: \{e}")
            }
          }
      }
    Some(env) =>
      match stdin {
        None =>
          @process.run(
            spec.cmd,
            spec.args,
            extra_env=env,
            inherit_env=true,
            stdout~,
            stderr~,
          ) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise @git.GitError::IoError("process failed: \{e}")
            }
          }
        Some(input) =>
          @process.run(
            spec.cmd,
            spec.args,
            extra_env=env,
            inherit_env=true,
            stdin=input,
            stdout~,
            stderr~,
          ) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise @git.GitError::IoError("process failed: \{e}")
            }
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
pub async fn upload_pack_info_refs_process(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  let spec = @protocol.parse_remote(remote)
  let proc = build_upload_pack_process_spec(
    spec,
    advertise_refs=true,
    prefer_v2~,
  )
  run_upload_pack_process(proc, None)
}

///|
pub async fn upload_pack_request_process(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  let spec = @protocol.parse_remote(remote)
  let proc = build_upload_pack_process_spec(
    spec,
    advertise_refs=false,
    prefer_v2~,
  )
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
    return @protocol.extract_pack_from_v2_response(resp)
  }
  let req = @protocol.build_fetch_request_v0("git/moonbit", wants, caps)
  let resp = upload_pack_request_process(remote, req, false)
  @protocol.extract_pack_from_v0_response(resp)
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
    Some((refname, commit_id)) => {
      if filter.is_partial() {
        write_partial_clone_metadata(
          fs,
          root,
          refname,
          commit_id,
          remote,
          filter,
        )
      } else if effective_no_checkout {
        @git.write_git_metadata(store, commit_id, refname, remote, fs, root)
      } else {
        @git.materialize_clone_to_fs(
          store,
          commit_id,
          refname,
          remote,
          fs,
          root,
        )
      }
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
