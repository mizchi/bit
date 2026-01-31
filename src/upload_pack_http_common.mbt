///| Upload-pack over HTTP - common logic (all targets)

///| Uses HTTP client functions passed as arguments

// Type aliases for HTTP client functions (for documentation)
// HttpGetFn = async (String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError
// HttpPostFn = async (String, Bytes, Map[String, String]) -> (HttpResponse, Bytes) raise GitError

///|
/// Fetch info/refs using provided HTTP client
pub async fn upload_pack_info_refs_with_http(
  remote : String,
  prefer_v2 : Bool,
  http_get : async (String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError,
) -> Bytes raise GitError {
  let spec = parse_remote(remote)
  if spec.kind != RemoteKind::Http {
    raise GitError::ProtocolError("HTTP transport required")
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
    raise GitError::ProtocolError(
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
    HttpResponse,
    Bytes,
  ) raise GitError,
) -> Bytes raise GitError {
  let spec = parse_remote(remote)
  if spec.kind != RemoteKind::Http {
    raise GitError::ProtocolError("HTTP transport required")
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
    raise GitError::ProtocolError(
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
  http_get : async (String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    HttpResponse,
    Bytes,
  ) raise GitError,
) -> (
  Array[(ObjectId, String)],
  Array[String],
  ProtocolVersion,
  Map[String, String],
) raise GitError {
  let adv = upload_pack_info_refs_with_http(remote, prefer_v2, http_get)
  let version = detect_protocol_version(adv)
  if version == ProtocolVersion::V2 {
    let caps = parse_v2_advertised_caps(adv)
    let req = build_ls_refs_request("git/moonbit", [
      "refs/heads/", "refs/tags/", "HEAD",
    ])
    let resp = upload_pack_request_with_http(remote, req, true, http_post)
    let parsed = parse_ls_refs_response(resp)
    return (parsed.refs, caps, version, parsed.symrefs)
  }
  let refs = parse_refs(adv)
  let caps = extract_capabilities(adv)
  (refs, caps, ProtocolVersion::V0, {})
}

///|
/// Fetch pack using provided HTTP client
pub async fn fetch_pack_with_http(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
  http_get : async (String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    HttpResponse,
    Bytes,
  ) raise GitError,
) -> Bytes raise GitError {
  let (refs, caps, version, _symrefs) = discover_upload_refs_with_http(
    remote, prefer_v2, http_get, http_post,
  )
  let wants = if wants.length() == 0 {
    let ids : Array[ObjectId] = []
    for item in refs {
      let (id, _) = item
      ids.push(id)
    }
    ids
  } else {
    wants
  }
  if version == ProtocolVersion::V2 {
    let req = build_fetch_request_v2("git/moonbit", wants)
    let resp = upload_pack_request_with_http(remote, req, true, http_post)
    return extract_pack_from_v2_response(resp)
  }
  let req = build_fetch_request_v0("git/moonbit", wants, caps)
  let resp = upload_pack_request_with_http(remote, req, false, http_post)
  extract_pack_from_v0_response(resp)
}

///|
/// Fetch objects using provided HTTP client
pub async fn fetch_objects_with_http(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
  http_get : async (String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    HttpResponse,
    Bytes,
  ) raise GitError,
) -> Array[PackObject] raise GitError {
  let pack = fetch_pack_with_http(remote, wants, prefer_v2, http_get, http_post)
  parse_packfile(pack)
}

///|
/// Clone using provided HTTP client
pub async fn clone_with_http(
  remote : String,
  prefer_v2 : Bool,
  http_get : async (String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    HttpResponse,
    Bytes,
  ) raise GitError,
) -> (Array[(ObjectId, String)], Array[PackObject]) raise GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_with_http(
    remote, prefer_v2, http_get, http_post,
  )
  let wants = select_default_wants(refs, symrefs)
  let pack = fetch_pack_with_http(remote, wants, prefer_v2, http_get, http_post)
  let objects = parse_packfile(pack)
  (refs, objects)
}

///|
/// Clone and checkout into filesystem using provided HTTP client
pub async fn clone_to_fs_with_http(
  remote : String,
  prefer_v2 : Bool,
  fs : &FileSystem,
  root : String,
  http_get : async (String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    HttpResponse,
    Bytes,
  ) raise GitError,
) -> Array[(ObjectId, String)] raise GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_with_http(
    remote, prefer_v2, http_get, http_post,
  )
  let wants = select_default_wants(refs, symrefs)
  let default_ref = select_default_ref(refs, symrefs)
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
      remote, wants, prefer_v2, http_get, http_post,
    )
    let objects = parse_packfile(pack)
    // Write pack and index to disk immediately
    match default_ref {
      Some(_) => {
        let git_dir = join_path(root, ".git")
        fs.mkdir_p(join_path(git_dir, "objects/pack"))
        write_packfile_with_index(fs, git_dir, pack, objects)
      }
      None => ()
    }
    objects
    // pack goes out of scope here and can be GC'd
  }
  // Phase 2: Checkout (pack bytes no longer needed)
  let store = ObjectStore::from_pack(objects)
  match default_ref {
    None => ()
    Some((refname, commit_id)) => {
      materialize_clone_to_fs(store, commit_id, refname, remote, fs, root)
    }
  }
  refs
}
