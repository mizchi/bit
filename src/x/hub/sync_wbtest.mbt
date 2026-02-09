///| Whitebox tests for hub notes merge logic

///|
priv struct TestHubObjectStore {
  db : @lib.ObjectDb
  rfs : &@git.RepoFileSystem
  fs : &@git.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for TestHubObjectStore with get(self, id) {
  self.db.get(self.rfs, id)
}

///|
impl @lib.ObjectStore for TestHubObjectStore with put(self, obj_type, content) {
  let (id, compressed) = @git.create_object(obj_type, content)
  write_object_bytes(self.fs, self.git_dir, id, compressed)
  id
}

///|
impl @lib.ObjectStore for TestHubObjectStore with has(self, id) {
  let obj = self.db.get(self.rfs, id)
  obj is Some(_)
}

///|
fn setup_sync_repo() -> (@git.TestFs, String) {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  (fs, "/repo/.git")
}

///|
fn make_test_object_store(
  fs : @git.TestFs,
  git_dir : String,
) -> TestHubObjectStore raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  { db, rfs: fs, fs, git_dir }
}

///|
fn write_tree(
  fs : @git.TestFs,
  git_dir : String,
  entries : Array[@git.TreeEntry],
) -> @git.ObjectId {
  let (id, compressed) = @git.create_tree(entries)
  write_object_bytes(fs, git_dir, id, compressed) catch {
    _ => panic()
  }
  id
}

///|
fn read_blob_string(objects : TestHubObjectStore, id : @git.ObjectId) -> String {
  let obj = objects.db.get(objects.rfs, id) catch { _ => None }
  guard obj is Some(blob) else { return "" }
  @utf8.decode_lossy(blob.data[:])
}

///|
fn write_record_blob(
  fs : @git.TestFs,
  git_dir : String,
  record : HubRecord,
) -> @git.ObjectId {
  let (id, compressed) = @git.create_blob_string(record.serialize())
  write_object_bytes(fs, git_dir, id, compressed) catch {
    _ => panic()
  }
  id
}

///|
fn find_tree_entry(
  objects : TestHubObjectStore,
  tree_id : @git.ObjectId,
  name : String,
) -> @git.ObjectId? {
  let obj_store : &@lib.ObjectStore = objects
  let entries = read_tree_entries_store(obj_store, tree_id)
  for entry in entries {
    if entry.name == name {
      return Some(entry.id)
    }
  }
  None
}

///|
test "sync: merge notes unions entries" {
  let (fs, git_dir) = setup_sync_repo()
  let objects = make_test_object_store(fs, git_dir)
  let key1 = "hub/pr/1/meta"
  let key2 = "hub/pr/2/meta"
  let (key1_id, key1_compressed) = @git.create_blob_string(key1)
  write_object_bytes(fs, git_dir, key1_id, key1_compressed) catch {
    _ => panic()
  }
  let (key2_id, key2_compressed) = @git.create_blob_string(key2)
  write_object_bytes(fs, git_dir, key2_id, key2_compressed) catch {
    _ => panic()
  }
  let record1 = HubRecord::new(key1, "pr", "payload 1", "nodeA", 1L)
  let record2 = HubRecord::new(key2, "pr", "payload 2", "nodeB", 2L)
  let blob1 = write_record_blob(fs, git_dir, record1)
  let blob2 = write_record_blob(fs, git_dir, record2)
  let local_notes = write_tree(fs, git_dir, [
    @git.TreeEntry::new("100644", key1_id.to_hex(), blob1),
  ])
  let remote_notes = write_tree(fs, git_dir, [
    @git.TreeEntry::new("100644", key2_id.to_hex(), blob2),
  ])
  let obj_store : &@lib.ObjectStore = objects
  let merged = merge_notes_trees_store(
    obj_store, fs, git_dir, local_notes, remote_notes,
  )
  let merged_entries = read_tree_entries_store(obj_store, merged)
  assert_eq(merged_entries.length(), 2)
}

///|
test "sync: merge notes uses LWW by clock and timestamp" {
  let (fs, git_dir) = setup_sync_repo()
  let objects = make_test_object_store(fs, git_dir)
  let key = "hub/pr/1/meta"
  let (key_id, key_compressed) = @git.create_blob_string(key)
  write_object_bytes(fs, git_dir, key_id, key_compressed) catch {
    _ => panic()
  }
  let local_record = HubRecord::new(key, "pr", "payload local", "nodeA", 1L, clock={
    "nodeA": 1,
  })
  let remote_record = HubRecord::new(key, "pr", "payload remote", "nodeB", 2L, clock={
    "nodeA": 1,
    "nodeB": 1,
  })
  let local_blob = write_record_blob(fs, git_dir, local_record)
  let remote_blob = write_record_blob(fs, git_dir, remote_record)
  let local_notes = write_tree(fs, git_dir, [
    @git.TreeEntry::new("100644", key_id.to_hex(), local_blob),
  ])
  let remote_notes = write_tree(fs, git_dir, [
    @git.TreeEntry::new("100644", key_id.to_hex(), remote_blob),
  ])
  let obj_store : &@lib.ObjectStore = objects
  let merged = merge_notes_trees_store(
    obj_store, fs, git_dir, local_notes, remote_notes,
  )
  let merged_entry = find_tree_entry(objects, merged, key_id.to_hex())
  guard merged_entry is Some(mid) else { panic() }
  let merged_text = read_blob_string(objects, mid)
  let merged_record = parse_hub_record(merged_text)
  assert_eq(merged_record.payload, "payload remote")
}
