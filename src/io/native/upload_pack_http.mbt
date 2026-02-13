///| Upload-pack over HTTP - native implementation

///| This file is only compiled for native target

///|
fn remote_uses_http_transport(remote : String) -> Bool {
  let spec = @protocol.parse_remote(remote)
  spec.kind == @protocol.RemoteKind::Http
}

///|
fn ensure_process_transport_options(
  depth : Int,
  filter : @protocol.FilterSpec,
) -> Unit {
  ignore(depth)
  ignore(filter)
}

///|
pub async fn upload_pack_info_refs_http(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  if remote_uses_http_transport(remote) {
    upload_pack_info_refs_with_http(remote, prefer_v2, native_http_get)
  } else {
    upload_pack_info_refs_process(remote, prefer_v2)
  }
}

///|
pub async fn upload_pack_request_http(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  if remote_uses_http_transport(remote) {
    upload_pack_request_with_http(remote, body, prefer_v2, native_http_post)
  } else {
    upload_pack_request_process(remote, body, prefer_v2)
  }
}

///|
pub async fn discover_upload_refs_http(
  remote : String,
  prefer_v2 : Bool,
) -> (
  Array[(@git.ObjectId, String)],
  Array[String],
  @protocol.ProtocolVersion,
  Map[String, String],
) raise @git.GitError {
  if remote_uses_http_transport(remote) {
    discover_upload_refs_with_http(
      remote, prefer_v2, native_http_get, native_http_post,
    )
  } else {
    discover_upload_refs_process(remote, prefer_v2)
  }
}

///|
pub async fn fetch_pack_http(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
) -> Bytes raise @git.GitError {
  if remote_uses_http_transport(remote) {
    fetch_pack_with_http(
      remote, wants, prefer_v2, depth, filter, native_http_get, native_http_post,
    )
  } else {
    ensure_process_transport_options(depth, filter)
    fetch_pack_process(remote, wants, prefer_v2, depth~, filter~)
  }
}

///|
pub async fn fetch_objects_http(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
) -> Array[@git.PackObject] raise @git.GitError {
  if remote_uses_http_transport(remote) {
    fetch_objects_with_http(
      remote, wants, prefer_v2, depth, filter, native_http_get, native_http_post,
    )
  } else {
    ensure_process_transport_options(depth, filter)
    fetch_objects_process(remote, wants, prefer_v2, depth~, filter~)
  }
}

///|
pub async fn clone_http(
  remote : String,
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
) -> (Array[(@git.ObjectId, String)], Array[@git.PackObject]) raise @git.GitError {
  if remote_uses_http_transport(remote) {
    clone_with_http(
      remote, prefer_v2, depth, filter, native_http_get, native_http_post,
    )
  } else {
    ensure_process_transport_options(depth, filter)
    clone_process(remote, prefer_v2, depth~, filter~)
  }
}

///|
/// Clone and checkout into filesystem under `root`.
/// - depth > 0: shallow clone with that depth
/// - filter: partial clone filter (e.g., FilterSpec::BlobNone)
pub async fn clone_http_to_fs(
  remote : String,
  prefer_v2 : Bool,
  fs : &@git.FileSystem,
  root : String,
  depth? : Int = 0,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
  no_checkout? : Bool = false,
) -> Array[(@git.ObjectId, String)] raise @git.GitError {
  if remote_uses_http_transport(remote) {
    clone_to_fs_with_http(
      remote,
      prefer_v2,
      depth,
      filter,
      fs,
      root,
      native_http_get,
      native_http_post,
      no_checkout~,
    )
  } else {
    ensure_process_transport_options(depth, filter)
    clone_process_to_fs(
      remote,
      prefer_v2,
      fs,
      root,
      depth~,
      filter~,
      no_checkout~,
    )
  }
}
