///| Root package public facade.

///|
pub using @types {
  type ObjectId,
  type ObjectType,
  type GitError,
  type TreeEntry,
  type Commit,
  type PackObject,
  type PackDeltaMode,
  type PackCompression,
  type Sha1State,
  trait FileSystem,
  trait RepoFileSystem,
}

///|
pub using @io {type TestFs}

///|
pub using @repo {
  type ObjectStore,
  type CommitInfo,
  parse_commit,
  parse_tree,
  checkout_commit,
  checkout_commit_to_fs,
  join_path,
  materialize_clone_to_fs,
  write_git_metadata,
}

///|
pub using @object {
  create_object,
  hash_object_content,
  create_blob,
  create_blob_string,
  create_tree,
  create_commit,
  hash_blob,
  serialize_tree,
  serialize_commit_content,
  hash_blob_string,
  sha1_prefix,
  sha1,
  sha1_array_prefix,
  sha1_array,
}
