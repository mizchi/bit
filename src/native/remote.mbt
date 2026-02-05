///| Git HTTP push protocol - native implementation

///| This file is only compiled for native target

///|
/// Fetch receive-pack refs via smart HTTP (native)
pub async fn discover_receive_refs_http(
  remote : @git.Remote,
) -> Array[(@git.ObjectId, String)] raise @git.GitError {
  let (refs, _) = @git.discover_refs_with_http(remote, native_http_get)
  refs
}

///|
/// Discover refs and capabilities from remote (native)
pub async fn discover_refs(
  remote : @git.Remote,
) -> (Array[(@git.ObjectId, String)], Array[String]) raise @git.GitError {
  @git.discover_refs_with_http(remote, native_http_get)
}

///|
/// Push a packfile to remote repository (native)
pub async fn push(
  remote : @git.Remote,
  req : @git.PushRequest,
) -> String raise @git.GitError {
  @git.push_with_http(remote, req, native_http_get, native_http_post)
}

///|
/// Push a single file as a new commit (native)
pub async fn push_file(
  remote : @git.Remote,
  content : Bytes,
  filename : String,
  message : String,
  author : String,
  timestamp : Int64,
  parent : @git.ObjectId?,
) -> @git.ObjectId raise @git.GitError {
  let parents = match parent {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    @git.ObjectId::zero(),
    parents,
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  let (commit_id, packfile) = @git.create_commit_packfile(
    content, filename, commit,
  )
  let old_id = match parent {
    Some(p) => p
    None => @git.ObjectId::zero()
  }
  let req = @git.PushRequest::new(
    old_id, commit_id, "refs/heads/main", packfile,
  )
  let _ = push(remote, req)
  commit_id
}
