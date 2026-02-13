///| Upload-pack over HTTP - common logic (all targets)

///| Uses HTTP client functions passed as arguments

// Type aliases for HTTP client functions (for documentation)
// HttpGetFn = async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError
// HttpPostFn = async (String, Bytes, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError

///|
/// Fetch info/refs using provided HTTP client
pub async fn upload_pack_info_refs_with_http(
  remote : String,
  prefer_v2 : Bool,
  http_get : async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError,
) -> Bytes raise @git.GitError {
  let spec = @protocol.parse_remote(remote)
  if spec.kind != @protocol.RemoteKind::Http {
    raise @git.GitError::ProtocolError("HTTP transport required")
  }
  let base = spec.base_url.unwrap_or(remote)
  let url = "\{base}/info/refs?service=git-upload-pack"
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Accept": "application/x-git-upload-pack-advertisement",
  }
  if prefer_v2 {
    headers.set("Git-Protocol", "version=2")
  }
  let (response, data) = http_get(url, headers)
  if response.code != 200 {
    raise @git.GitError::ProtocolError(
      "Failed to fetch info/refs: HTTP \{response.code}",
    )
  }
  data
}

///|
/// Send upload-pack request using provided HTTP client
pub async fn upload_pack_request_with_http(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @git.HttpResponse,
    Bytes,
  ) raise @git.GitError,
) -> Bytes raise @git.GitError {
  let spec = @protocol.parse_remote(remote)
  if spec.kind != @protocol.RemoteKind::Http {
    raise @git.GitError::ProtocolError("HTTP transport required")
  }
  let base = spec.base_url.unwrap_or(remote)
  let url = "\{base}/git-upload-pack"
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Content-Type": "application/x-git-upload-pack-request",
    "Accept": "application/x-git-upload-pack-result",
  }
  if prefer_v2 {
    headers.set("Git-Protocol", "version=2")
  }
  let (response, data) = http_post(url, body, headers)
  if response.code != 200 {
    raise @git.GitError::ProtocolError(
      "Failed to upload-pack: HTTP \{response.code}",
    )
  }
  data
}

///|
/// Discover upload refs using provided HTTP client
pub async fn discover_upload_refs_with_http(
  remote : String,
  prefer_v2 : Bool,
  http_get : async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @git.HttpResponse,
    Bytes,
  ) raise @git.GitError,
) -> (
  Array[(@git.ObjectId, String)],
  Array[String],
  @protocol.ProtocolVersion,
  Map[String, String],
) raise @git.GitError {
  let adv = upload_pack_info_refs_with_http(remote, prefer_v2, http_get)
  let version = @protocol.detect_protocol_version(adv)
  if version == @protocol.ProtocolVersion::V2 {
    let caps = @protocol.parse_v2_advertised_caps(adv)
    let req = @protocol.build_ls_refs_request("git/moonbit", [
      "refs/heads/", "refs/tags/", "HEAD",
    ])
    let resp = upload_pack_request_with_http(remote, req, true, http_post)
    let parsed = @protocol.parse_ls_refs_response(resp)
    return (parsed.refs, caps, version, parsed.symrefs)
  }
  let refs = @protocol.parse_refs(adv)
  let caps = @protocol.extract_capabilities(adv)
  (refs, caps, @protocol.ProtocolVersion::V0, {})
}

///|
/// Fetch pack using provided HTTP client.
/// - depth > 0: shallow clone with that depth (v2 only)
/// - filter: partial clone filter (v2 only)
pub async fn fetch_pack_with_http(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth : Int,
  filter : @protocol.FilterSpec,
  http_get : async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @git.HttpResponse,
    Bytes,
  ) raise @git.GitError,
) -> Bytes raise @git.GitError {
  let (refs, caps, version, _symrefs) = discover_upload_refs_with_http(
    remote, prefer_v2, http_get, http_post,
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
    let resp = upload_pack_request_with_http(remote, req, true, http_post)
    return @protocol.extract_pack_from_v2_response(resp)
  }
  // v0 protocol doesn't support shallow/filter, ignore them
  let req = @protocol.build_fetch_request_v0("git/moonbit", wants, caps)
  let resp = upload_pack_request_with_http(remote, req, false, http_post)
  @protocol.extract_pack_from_v0_response(resp)
}

///|
/// Fetch objects using provided HTTP client.
/// - depth > 0: shallow clone with that depth
/// - filter: partial clone filter
pub async fn fetch_objects_with_http(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth : Int,
  filter : @protocol.FilterSpec,
  http_get : async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @git.HttpResponse,
    Bytes,
  ) raise @git.GitError,
) -> Array[@git.PackObject] raise @git.GitError {
  let pack = fetch_pack_with_http(
    remote, wants, prefer_v2, depth, filter, http_get, http_post,
  )
  @pack.parse_packfile(pack)
}

///|
/// Clone using provided HTTP client.
/// - depth > 0: shallow clone with that depth
/// - filter: partial clone filter
pub async fn clone_with_http(
  remote : String,
  prefer_v2 : Bool,
  depth : Int,
  filter : @protocol.FilterSpec,
  http_get : async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @git.HttpResponse,
    Bytes,
  ) raise @git.GitError,
) -> (Array[(@git.ObjectId, String)], Array[@git.PackObject]) raise @git.GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_with_http(
    remote, prefer_v2, http_get, http_post,
  )
  let wants = @protocol.select_default_wants(refs, symrefs)
  let pack = fetch_pack_with_http(
    remote, wants, prefer_v2, depth, filter, http_get, http_post,
  )
  let objects = @pack.parse_packfile(pack)
  (refs, objects)
}

///|
/// Clone and checkout into filesystem using provided HTTP client.
/// - depth > 0: shallow clone with that depth
/// - filter: partial clone filter (if BlobNone, skip checkout)
pub async fn clone_to_fs_with_http(
  remote : String,
  prefer_v2 : Bool,
  depth : Int,
  filter : @protocol.FilterSpec,
  fs : &@git.FileSystem,
  root : String,
  http_get : async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @git.HttpResponse,
    Bytes,
  ) raise @git.GitError,
  no_checkout? : Bool = false,
) -> Array[(@git.ObjectId, String)] raise @git.GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_with_http(
    remote, prefer_v2, http_get, http_post,
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
  // Phase 1: Fetch pack, parse, and write pack to disk
  // This allows pack bytes to be released after writing
  let objects = {
    let pack = fetch_pack_with_http(
      remote, wants, prefer_v2, depth, filter, http_get, http_post,
    )
    let pack_id = read_pack_trailer_id_http(pack)
    let objects = @pack.parse_packfile(pack)
    // Write pack and index to disk immediately
    match default_ref {
      Some(_) => {
        let git_dir = @git.join_path(root, ".git")
        fs.mkdir_p(@git.join_path(git_dir, "objects/pack"))
        @pack.write_packfile_with_index(fs, git_dir, pack, objects)
        // Write promisor file if partial clone
        if filter.is_partial() {
          write_promisor_file(fs, git_dir, remote)
          write_pack_promisor_marker_http(
            fs, git_dir, pack_id, refs, default_ref,
          )
        }
      }
      None => ()
    }
    objects
    // pack goes out of scope here and can be GC'd
  }
  // Phase 2: Checkout (pack bytes no longer needed)
  // Skip checkout for partial clone with blob:none (no blobs to checkout)
  if filter.is_partial() {
    // For partial clone, write refs/config and let caller perform lazy checkout.
    match default_ref {
      Some((refname, commit_id)) => {
        let git_dir = @git.join_path(root, ".git")
        write_partial_clone_refs(
          fs, git_dir, refname, commit_id, remote, filter,
        )
      }
      None => ()
    }
  } else {
    let store = @git.ObjectStore::from_pack(objects)
    match default_ref {
      None => ()
      Some((refname, commit_id)) =>
        if no_checkout {
          @git.write_git_metadata(store, commit_id, refname, remote, fs, root)
        } else {
          @git.materialize_clone_to_fs(
            store, commit_id, refname, remote, fs, root,
          )
        }
    }
  }
  refs
}

///|
/// Write promisor file to mark this as a partial clone repository
fn write_promisor_file(
  fs : &@git.FileSystem,
  git_dir : String,
  remote : String,
) -> Unit raise @git.GitError {
  let promisor_dir = @git.join_path(git_dir, "objects/info")
  fs.mkdir_p(promisor_dir)
  let promisor_path = @git.join_path(promisor_dir, "promisor")
  // Format: remote URL that can fulfill missing objects
  fs.write_string(promisor_path, remote + "\n")
}

///|
fn read_pack_trailer_id_http(pack : Bytes) -> @git.ObjectId raise @git.GitError {
  if pack.length() < 20 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  let trailer_start = pack.length() - 20
  let bytes = FixedArray::makei(20, i => pack[trailer_start + i])
  @git.ObjectId::new(bytes)
}

///|
fn write_pack_promisor_marker_http(
  fs : &@git.FileSystem,
  git_dir : String,
  pack_id : @git.ObjectId,
  refs : Array[(@git.ObjectId, String)],
  default_ref : (String, @git.ObjectId)?,
) -> Unit raise @git.GitError {
  let pack_dir = @git.join_path(git_dir, "objects/pack")
  fs.mkdir_p(pack_dir)
  let marker_lines : Array[String] = []
  let seen : Map[String, Bool] = {}
  for item in refs {
    let (id, name) = item
    if name.length() == 0 {
      continue
    }
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
/// Write refs for partial clone (without checkout)
fn write_partial_clone_refs(
  fs : &@git.FileSystem,
  git_dir : String,
  refname : String,
  commit_id : @git.ObjectId,
  remote : String,
  filter : @protocol.FilterSpec,
) -> Unit raise @git.GitError {
  // Write HEAD
  let head_path = @git.join_path(git_dir, "HEAD")
  fs.write_string(head_path, "ref: \{refname}\n")
  // Write the ref - compute parent directory
  let ref_path = @git.join_path(git_dir, refname)
  // Get parent directory by finding last /
  let ref_dir = {
    let mut last_slash = -1
    for i, c in ref_path {
      if c == '/' {
        last_slash = i
      }
    }
    if last_slash > 0 {
      String::unsafe_substring(ref_path, start=0, end=last_slash)
    } else {
      git_dir
    }
  }
  fs.mkdir_p(ref_dir)
  fs.write_string(ref_path, commit_id.to_hex() + "\n")
  // Write config with remote
  let config_path = @git.join_path(git_dir, "config")
  let config = "[core]\n\trepositoryformatversion = 1\n\tfilemode = true\n\tbare = false\n\tlogallaliases = false\n[extensions]\n\tpartialclone = origin\n[remote \"origin\"]\n\turl = \{remote}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n\tpromisor = true\n\tpartialclonefilter = \{filter.to_string()}\n"
  fs.write_string(config_path, config)
}
