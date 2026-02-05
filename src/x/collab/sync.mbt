///| Collab notes sync operations (fetch/push)

///|
pub struct PrSyncResult {
  success : Bool
  message : String
  local_commit : @git.ObjectId?
  remote_commit : @git.ObjectId?
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
/// Native adapter: ObjectDb + RepoFileSystem -> ObjectStore
priv struct NativeObjectStore {
  db : @lib.ObjectDb
  rfs : &@git.RepoFileSystem
  fs : &@git.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for NativeObjectStore with get(self, id) {
  self.db.get(self.rfs, id)
}

///|
impl @lib.ObjectStore for NativeObjectStore with put(self, obj_type, content) {
  let (id, compressed) = @git.create_object(obj_type, content)
  write_object_bytes(self.fs, self.git_dir, id, compressed)
  id
}

///|
impl @lib.ObjectStore for NativeObjectStore with has(self, id) {
  let obj = self.db.get(self.rfs, id)
  obj is Some(_)
}

///|
/// Native adapter: FileSystem + git_dir -> RefStore
priv struct NativeRefStore {
  fs : &@git.FileSystem
  rfs : &@git.RepoFileSystem
  git_dir : String
}

///|
impl @lib.RefStore for NativeRefStore with resolve(self, ref_name) {
  @lib.resolve_ref(self.rfs, self.git_dir, ref_name)
}

///|
impl @lib.RefStore for NativeRefStore with update(self, ref_name, id) {
  match id {
    Some(commit_id) => {
      let ref_path = join_path(self.git_dir, ref_name)
      let dir = parent_path(ref_path)
      self.fs.mkdir_p(dir)
      self.fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    None => ()
  }
}

///|
impl @lib.RefStore for NativeRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
fn write_object_bytes(
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
/// Push collab notes ref to remote
pub async fn Collab::push(
  _self : Collab,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> PrSyncResult raise @git.GitError {
  let ref_name = collab_notes_ref_name()
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  guard local_commit is Some(local_id) else {
    return {
      success: false,
      message: "No local collab notes ref found",
      local_commit: None,
      remote_commit: None,
    }
  }
  // Collect all objects reachable from notes ref
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let objects = @lib.collect_reachable_objects(db, rfs, local_id)
  let pack = @git.create_packfile(objects)
  // Discover remote refs
  let remote = @git.Remote::new(remote_url)
  let refs = @gitnative.discover_receive_refs_http(remote)
  let (old_id, push_ref) = find_remote_notes_ref(refs)
  // Push
  let req = @git.PushRequest::new(old_id, local_id, push_ref, pack)
  let result = @gitnative.push(remote, req)
  if result.has_prefix("unpack ok") ||
    result.has_prefix("ok ") ||
    result.has_prefix("Push successful") {
    {
      success: true,
      message: "Push successful",
      local_commit: Some(local_id),
      remote_commit: Some(local_id),
    }
  } else {
    {
      success: false,
      message: "Push failed: \{result}",
      local_commit: Some(local_id),
      remote_commit: None,
    }
  }
}

///|
/// Fetch collab notes ref from remote and merge
pub async fn Collab::fetch(
  self : Collab,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> PrSyncResult raise @git.GitError {
  let ref_name = collab_notes_ref_name()
  // Discover remote refs
  let (refs, _, _, _) = @gitnative.discover_upload_refs_http(remote_url, true)
  let remote_id = find_upload_notes_ref(refs)
  guard remote_id is Some((rid, remote_ref)) else {
    return {
      success: false,
      message: "No remote collab notes ref found",
      local_commit: @lib.resolve_ref(rfs, git_dir, ref_name),
      remote_commit: None,
    }
  }
  // Fetch pack
  let pack = @gitnative.fetch_pack_http(remote_url, [rid], true)
  let objects = @git.parse_packfile(pack)
  @git.write_packfile_with_index(fs, git_dir, pack, objects)
  // Update remote tracking ref (best-effort)
  let remote_short = short_ref_name(remote_ref)
  let remote_ref_path = join_path(
    git_dir,
    "refs/remotes/origin/" + remote_short,
  )
  let dir = parent_path(remote_ref_path)
  fs.mkdir_p(dir)
  fs.write_string(remote_ref_path, rid.to_hex() + "\n")
  // Get local commit
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  // Create native adapters
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs, git_dir }
  let obj_store : &@lib.ObjectStore = native_objects
  let ref_store : &@lib.RefStore = native_refs
  match local_commit {
    None => {
      ref_store.update(collab_notes_ref_name(), Some(rid))
      self.store = CollabStore::load(
        obj_store,
        ref_store,
        node_id=self.store.node_id(),
      )
      {
        success: true,
        message: "Fetched remote collab notes ref",
        local_commit: Some(rid),
        remote_commit: Some(rid),
      }
    }
    Some(lid) =>
      if lid == rid {
        {
          success: true,
          message: "Already up to date",
          local_commit: Some(lid),
          remote_commit: Some(rid),
        }
      } else {
        merge_notes_commits(self, fs, git_dir, obj_store, ref_store, lid, rid)
      }
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
fn merge_notes_commits(
  prs : Collab,
  fs : &@git.FileSystem,
  git_dir : String,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  local_id : @git.ObjectId,
  remote_id : @git.ObjectId,
) -> PrSyncResult raise @git.GitError {
  // Fast-forward if possible
  if is_commit_ancestor_store(objects, local_id, remote_id) {
    refs.update(collab_notes_ref_name(), Some(remote_id))
    prs.store = CollabStore::load(objects, refs, node_id=prs.store.node_id())
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
    "Collab <collab@local>",
    0L,
    "+0000",
    "Collab <collab@local>",
    0L,
    "+0000",
    "Merge collab notes\n",
  )
  let (commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, commit_id, commit_compressed)
  refs.update(collab_notes_ref_name(), Some(commit_id))
  prs.store = CollabStore::load(objects, refs, node_id=prs.store.node_id())
  {
    success: true,
    message: "Merged remote collab notes",
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
  merged_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
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
fn find_remote_notes_ref(
  refs : Array[(@git.ObjectId, String)],
) -> (@git.ObjectId, String) {
  let ref_name = collab_notes_ref_name()
  for item in refs {
    let (id, name) = item
    if name == ref_name {
      return (id, name)
    }
  }
  (@git.ObjectId::zero(), ref_name)
}

///|
fn find_upload_notes_ref(
  refs : Array[(@git.ObjectId, String)],
) -> (@git.ObjectId, String)? {
  let ref_name = collab_notes_ref_name()
  for item in refs {
    let (id, name) = item
    if name == ref_name {
      return Some((id, name))
    }
  }
  None
}

///|
fn short_ref_name(refname : String) -> String {
  if refname.has_prefix("refs/") {
    String::unsafe_substring(refname, start=5, end=refname.length())
  } else {
    refname
  }
}

///|
fn parent_path(path : String) -> String {
  let chars = path.to_array()
  let mut i = chars.length()
  while i > 0 {
    let idx = i - 1
    if chars[idx] == '/' {
      if idx == 0 {
        return "."
      }
      return String::unsafe_substring(path, start=0, end=idx)
    }
    i = i - 1
  }
  "."
}
