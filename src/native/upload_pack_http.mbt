///| Upload-pack over HTTP - native implementation

///| This file is only compiled for native target

///|
pub async fn upload_pack_info_refs_http(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  @git.upload_pack_info_refs_with_http(remote, prefer_v2, native_http_get)
}

///|
pub async fn upload_pack_request_http(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  @git.upload_pack_request_with_http(remote, body, prefer_v2, native_http_post)
}

///|
pub async fn discover_upload_refs_http(
  remote : String,
  prefer_v2 : Bool,
) -> (
  Array[(@git.ObjectId, String)],
  Array[String],
  @git.ProtocolVersion,
  Map[String, String],
) raise @git.GitError {
  @git.discover_upload_refs_with_http(
    remote, prefer_v2, native_http_get, native_http_post,
  )
}

///|
pub async fn fetch_pack_http(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @git.FilterSpec = @git.FilterSpec::NoFilter,
) -> Bytes raise @git.GitError {
  @git.fetch_pack_with_http(
    remote, wants, prefer_v2, depth, filter, native_http_get, native_http_post,
  )
}

///|
pub async fn fetch_objects_http(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @git.FilterSpec = @git.FilterSpec::NoFilter,
) -> Array[@git.PackObject] raise @git.GitError {
  @git.fetch_objects_with_http(
    remote, wants, prefer_v2, depth, filter, native_http_get, native_http_post,
  )
}

///|
pub async fn clone_http(
  remote : String,
  prefer_v2 : Bool,
  depth? : Int = 0,
  filter? : @git.FilterSpec = @git.FilterSpec::NoFilter,
) -> (Array[(@git.ObjectId, String)], Array[@git.PackObject]) raise @git.GitError {
  @git.clone_with_http(
    remote, prefer_v2, depth, filter, native_http_get, native_http_post,
  )
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
  filter? : @git.FilterSpec = @git.FilterSpec::NoFilter,
) -> Array[(@git.ObjectId, String)] raise @git.GitError {
  @git.clone_to_fs_with_http(
    remote, prefer_v2, depth, filter, fs, root, native_http_get, native_http_post,
  )
}
