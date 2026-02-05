///|
pub(open) trait ObjectStore {
  get(Self, @git.ObjectId) -> @git.PackObject? raise @git.GitError
  put(Self, @git.ObjectType, Bytes) -> @git.ObjectId raise @git.GitError
  has(Self, @git.ObjectId) -> Bool raise @git.GitError
}

///|
pub(open) trait RefStore {
  resolve(Self, String) -> @git.ObjectId? raise @git.GitError
  update(Self, String, @git.ObjectId?) -> Unit raise @git.GitError
  list(Self, String) -> Array[String] raise @git.GitError
}

///|
pub(open) trait Clock {
  now(Self) -> Int64
}

///|
pub(open) trait Random {
  short(Self) -> String
}

///|
pub struct PushUpdate {
  refname : String
  old_id : @git.ObjectId?
  new_id : @git.ObjectId?
}

///|
pub(open) trait Transport {
  fetch(Self, String, Array[@git.ObjectId]) -> Bytes raise @git.GitError
  push(Self, String, Array[PushUpdate]) -> Result[Unit, String] raise @git.GitError
}

///|
pub struct EnvProvider {
  get : (String) -> String?
  current_dir : () -> String?
}

///|
pub fn EnvProvider::new(
  get : (String) -> String?,
  current_dir : () -> String?,
) -> EnvProvider {
  { get, current_dir }
}

///|
pub fn EnvProvider::none() -> EnvProvider {
  {
    get: fn(_ : String) { None },
    current_dir: fn() { None },
  }
}
