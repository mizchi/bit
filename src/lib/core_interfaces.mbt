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
pub(open) trait WorkingTree {
  read_file(Self, String) -> Bytes raise @git.GitError
  write_file(Self, String, Bytes) -> Unit
  remove_file(Self, String) -> Unit
  is_file(Self, String) -> Bool
  is_dir(Self, String) -> Bool
  readdir(Self, String) -> Array[String] raise @git.GitError
  is_dirty(Self) -> Bool
  rollback(Self) -> Unit
  get_working_files(Self) -> Array[String]
  snapshot(Self, String, String, Int64) -> @git.ObjectId raise @git.GitError
  checkout(Self, @git.ObjectId) -> Unit raise @git.GitError
}
