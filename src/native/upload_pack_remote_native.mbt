///| Upload-pack dispatcher (native targets)

///|
fn ensure_process_remote(remote : String) -> Unit raise @git.GitError {
  let spec = @git.parse_remote(remote)
  if spec.kind == @git.RemoteKind::Http {
    raise @git.GitError::ProtocolError("HTTP transport requires wasm targets")
  }
}

///|
pub async fn upload_pack_info_refs(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  ensure_process_remote(remote)
  upload_pack_info_refs_process(remote, prefer_v2)
}

///|
pub async fn upload_pack_request(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  ensure_process_remote(remote)
  upload_pack_request_process(remote, body, prefer_v2)
}

///|
pub async fn discover_upload_refs(
  remote : String,
  prefer_v2 : Bool,
) -> (
  Array[(@git.ObjectId, String)],
  Array[String],
  @git.ProtocolVersion,
  Map[String, String],
) raise @git.GitError {
  ensure_process_remote(remote)
  discover_upload_refs_process(remote, prefer_v2)
}

///|
pub async fn fetch_pack(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
) -> Bytes raise @git.GitError {
  ensure_process_remote(remote)
  fetch_pack_process(remote, wants, prefer_v2)
}

///|
pub async fn fetch_objects(
  remote : String,
  wants : Array[@git.ObjectId],
  prefer_v2 : Bool,
) -> Array[@git.PackObject] raise @git.GitError {
  ensure_process_remote(remote)
  fetch_objects_process(remote, wants, prefer_v2)
}

///|
pub async fn clone_remote(
  remote : String,
  prefer_v2 : Bool,
) -> (Array[(@git.ObjectId, String)], Array[@git.PackObject]) raise @git.GitError {
  ensure_process_remote(remote)
  clone_process(remote, prefer_v2)
}

///|
pub async fn clone_remote_to_fs(
  remote : String,
  prefer_v2 : Bool,
  fs : &@git.FileSystem,
  root : String,
) -> Array[(@git.ObjectId, String)] raise @git.GitError {
  ensure_process_remote(remote)
  clone_process_to_fs(remote, prefer_v2, fs, root)
}
