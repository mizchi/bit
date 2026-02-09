///| Hub notes sync operations (pure merge logic)

///|
pub struct PrSyncResult {
  success : Bool
  message : String
  local_commit : @git.ObjectId?
  remote_commit : @git.ObjectId?
}

///|
pub fn PrSyncResult::new(
  success : Bool,
  message : String,
  local_commit : @git.ObjectId?,
  remote_commit : @git.ObjectId?,
) -> PrSyncResult {
  { success, message, local_commit, remote_commit }
}

///|
pub fn PrSyncResult::success(self : PrSyncResult) -> Bool {
  self.success
}

///|
pub fn PrSyncResult::message(self : PrSyncResult) -> String {
  self.message
}

///|
pub fn PrSyncResult::local_commit(self : PrSyncResult) -> @git.ObjectId? {
  self.local_commit
}

///|
pub fn PrSyncResult::remote_commit(self : PrSyncResult) -> @git.ObjectId? {
  self.remote_commit
}

///|
pub fn write_object_bytes(
  fs : &@git.FileSystem,
  git_dir : String,
  id : @git.ObjectId,
  compressed : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let dir = join_path(
    git_dir,
    "objects/" + String::unsafe_substring(hex, start=0, end=2),
  )
  let path = join_path(dir, String::unsafe_substring(hex, start=2, end=40))
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
}

///|
fn join_path(a : String, b : String) -> String {
  if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
fn get_commit_tree(
  objects : &@lib.ObjectStore,
  commit_id : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let obj = objects.get(commit_id)
  guard obj is Some(commit_obj) else { return None }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return None
  }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|
pub fn merge_notes_commits(
  prs : Hub,
  fs : &@git.FileSystem,
  git_dir : String,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  local_id : @git.ObjectId,
  remote_id : @git.ObjectId,
) -> PrSyncResult raise @git.GitError {
  // Fast-forward if possible
  if is_commit_ancestor_store(objects, local_id, remote_id) {
    refs.update(hub_notes_ref_name(), Some(remote_id))
    prs.store = HubStore::load(
      objects,
      refs,
      node_id=prs.store.node_id(),
      signing_key=prs.store.signing_key(),
      require_signed=prs.store.require_signed(),
    )
    return {
      success: true,
      message: "Fast-forward to remote",
      local_commit: Some(remote_id),
      remote_commit: Some(remote_id),
    }
  }
  if is_commit_ancestor_store(objects, remote_id, local_id) {
    return {
      success: true,
      message: "Local is ahead of remote",
      local_commit: Some(local_id),
      remote_commit: Some(remote_id),
    }
  }
  let local_tree = get_commit_tree(objects, local_id)
  guard local_tree is Some(ltree) else {
    raise @git.GitError::InvalidObject("Cannot read local notes tree")
  }
  let remote_tree = get_commit_tree(objects, remote_id)
  guard remote_tree is Some(rtree) else {
    raise @git.GitError::InvalidObject("Cannot read remote notes tree")
  }
  let merged_tree_id = merge_notes_trees_store(
    objects, fs, git_dir, ltree, rtree,
  )
  let commit = @git.Commit::new(
    merged_tree_id,
    [local_id, remote_id],
    "Hub <hub@local>",
    0L,
    "+0000",
    "Hub <hub@local>",
    0L,
    "+0000",
    "Merge hub notes\n",
  )
  let (commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, commit_id, commit_compressed)
  refs.update(hub_notes_ref_name(), Some(commit_id))
  prs.store = HubStore::load(
    objects,
    refs,
    node_id=prs.store.node_id(),
    signing_key=prs.store.signing_key(),
    require_signed=prs.store.require_signed(),
  )
  {
    success: true,
    message: "Merged remote hub notes",
    local_commit: Some(commit_id),
    remote_commit: Some(remote_id),
  }
}

///|
fn is_commit_ancestor_store(
  objects : &@lib.ObjectStore,
  ancestor : @git.ObjectId,
  commit : @git.ObjectId,
) -> Bool raise @git.GitError {
  if ancestor == commit {
    return true
  }
  let obj = objects.get(commit)
  guard obj is Some(commit_obj) else { return false }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return false
  }
  let info = @git.parse_commit(commit_obj.data)
  for parent in info.parents {
    if is_commit_ancestor_store(objects, ancestor, parent) {
      return true
    }
  }
  false
}

///|
fn merge_notes_trees_store(
  objects : &@lib.ObjectStore,
  fs : &@git.FileSystem,
  git_dir : String,
  local_tree : @git.ObjectId,
  remote_tree : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  let local_entries = read_tree_entries_store(objects, local_tree)
  let remote_entries = read_tree_entries_store(objects, remote_tree)
  let local_map : Map[String, @git.ObjectId] = {}
  for entry in local_entries {
    local_map[entry.name] = entry.id
  }
  let remote_map : Map[String, @git.ObjectId] = {}
  for entry in remote_entries {
    remote_map[entry.name] = entry.id
  }
  let keys : Map[String, Bool] = {}
  for item in local_map.to_array() {
    let (key, _) = item
    keys[key] = true
  }
  for item in remote_map.to_array() {
    let (key, _) = item
    keys[key] = true
  }
  let merged_entries : Array[@git.TreeEntry] = []
  for item in keys.to_array() {
    let (key, _) = item
    match (local_map.get(key), remote_map.get(key)) {
      (Some(lid), Some(rid)) =>
        if lid == rid {
          merged_entries.push(@git.TreeEntry::new("100644", key, lid))
        } else {
          let ours = objects.get(lid)
          let theirs = objects.get(rid)
          match (ours, theirs) {
            (Some(o), Some(t)) => {
              let merged_bytes = merge_record_bytes(o.data, t.data)
              let merged_text = @utf8.decode_lossy(merged_bytes[:])
              let (blob_id, compressed) = @git.create_blob_string(merged_text)
              write_object_bytes(fs, git_dir, blob_id, compressed)
              merged_entries.push(@git.TreeEntry::new("100644", key, blob_id))
            }
            _ => merged_entries.push(@git.TreeEntry::new("100644", key, lid))
          }
        }
      (Some(lid), None) =>
        merged_entries.push(@git.TreeEntry::new("100644", key, lid))
      (None, Some(rid)) =>
        merged_entries.push(@git.TreeEntry::new("100644", key, rid))
      _ => ()
    }
  }
  merged_entries.sort_by((a, b) => String::compare(a.name, b.name))
  let (new_tree_id, tree_compressed) = @git.create_tree(merged_entries)
  write_object_bytes(fs, git_dir, new_tree_id, tree_compressed)
  new_tree_id
}

///|
fn read_tree_entries_store(
  objects : &@lib.ObjectStore,
  tree_id : @git.ObjectId,
) -> Array[@git.TreeEntry] {
  let obj = objects.get(tree_id) catch { _ => None }
  match obj {
    Some(tree_obj) => @git.parse_tree(tree_obj.data) catch { _ => [] }
    None => []
  }
}

///|
pub fn find_remote_notes_ref(
  refs : Array[(@git.ObjectId, String)],
) -> (@git.ObjectId, String) {
  let ref_name = hub_notes_ref_name()
  for item in refs {
    let (id, name) = item
    if name == ref_name {
      return (id, name)
    }
  }
  (@git.ObjectId::zero(), ref_name)
}

///|
pub fn find_upload_notes_ref(
  refs : Array[(@git.ObjectId, String)],
) -> (@git.ObjectId, String)? {
  let ref_name = hub_notes_ref_name()
  for item in refs {
    let (id, name) = item
    if name == ref_name {
      return Some((id, name))
    }
  }
  None
}

///|
pub fn short_ref_name(refname : String) -> String {
  if refname.has_prefix("refs/") {
    String::unsafe_substring(refname, start=5, end=refname.length())
  } else {
    refname
  }
}
