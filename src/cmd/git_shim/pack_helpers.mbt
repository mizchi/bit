///|
fn git_dir_from_env() -> String {
  let base = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(cwd) => Some(cwd)
    None => @sys.get_env_var("GIT_SHIM_PWD")
  }
  match @sys.get_env_var("GIT_DIR") {
    Some(path) =>
      if path.has_prefix("/") {
        path
      } else {
        match base {
          None => path
          Some(cwd) => cwd + "/" + path
        }
      }
    None =>
      match base {
        None => ".git"
        Some(cwd) => cwd + "/.git"
      }
  }
}

///|
fn shim_cwd_from_env() -> String? {
  @sys.get_env_var("GIT_SHIM_CWD")
}

///|
fn resolve_in_cwd(path : String) -> String {
  let base = match shim_cwd_from_env() {
    Some(cwd) => Some(cwd)
    None => @sys.get_env_var("GIT_SHIM_PWD")
  }
  match base {
    None => path
    Some(cwd) => if path.has_prefix("/") { path } else { cwd + "/" + path }
  }
}

///|
fn pack_hash_id(pack : Bytes) -> @git.ObjectId raise @git.GitError {
  if pack.length() < 20 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  let start = pack.length() - 20
  let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i = 0; i < 20; i = i + 1 {
    bytes[i] = pack[start + i]
  }
  @git.ObjectId::new(bytes)
}

///|
fn pack_hash_hex(pack : Bytes) -> String raise @git.GitError {
  pack_hash_id(pack).to_hex()
}
