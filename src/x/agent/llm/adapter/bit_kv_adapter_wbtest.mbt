///| Tests for KV-based CoordinationBackend via BitKvAdapter

///|
priv struct KvTestWorkingTree {
  fs : @fs.Fs
  backing_fs : &@git.RepoFileSystem
  write_fs : &@git.FileSystem
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with read_file(self, path) {
  self.fs.read_file(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with write_file(self, path, data) {
  self.fs.write_file(path, data)
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with remove_file(self, path) {
  self.fs.remove_file(path)
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with is_file(self, path) {
  self.fs.is_file(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with is_dir(self, path) {
  self.fs.is_dir(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with readdir(self, path) {
  self.fs.readdir(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with is_dirty(self) {
  self.fs.is_dirty()
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with rollback(self) {
  self.fs.rollback()
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with get_working_files(self) {
  self.fs.get_working_files()
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with snapshot(
  self,
  message,
  author,
  timestamp,
) {
  let snapshot = self.fs.snapshot(
    self.write_fs,
    self.backing_fs,
    message,
    author,
    timestamp,
  )
  snapshot.commit_id
}

///|
impl @lib.WorkingTree for KvTestWorkingTree with checkout(self, commit_id) {
  self.fs.checkout_snapshot(self.backing_fs, commit_id)
}

///|
priv struct KvTestObjectStore {
  backing_fs : &@git.RepoFileSystem
  write_fs : &@git.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for KvTestObjectStore with get(self, id) {
  let db = @lib.ObjectDb::load(self.backing_fs, self.git_dir)
  db.get(self.backing_fs, id)
}

///|
impl @lib.ObjectStore for KvTestObjectStore with put(self, obj_type, data) {
  @lib.write_loose_object(self.write_fs, self.git_dir, obj_type, data)
}

///|
impl @lib.ObjectStore for KvTestObjectStore with has(self, id) {
  let db = @lib.ObjectDb::load(self.backing_fs, self.git_dir) catch {
    _ => return false
  }
  let obj = db.get(self.backing_fs, id) catch { _ => return false }
  obj is Some(_)
}

///|
fn make_test_kv_coord() -> &@agent.CoordinationBackend {
  let testfs = @git.TestFs::new()
  let git_dir = "/repo/.git"
  let bitfs = @fs.Fs::empty(git_dir)
  let tree : KvTestWorkingTree = {
    fs: bitfs,
    backing_fs: testfs,
    write_fs: testfs,
  }
  let store : KvTestObjectStore = {
    backing_fs: testfs,
    write_fs: testfs,
    git_dir,
  }
  @agent.kv_coordination_backend("test-node", fn() {
    bit_kv_store("test-node", tree, store)
  })
}

///|
test "kv coord write and read status" {
  let coord = make_test_kv_coord()
  let session = coord.init_session("test-session")
  coord.init_agent(session, "agent-0")
  coord.write_status(session, "agent-0", Running)
  let status = coord.read_status(session, "agent-0")
  assert_true(status == @agent.Running)
}

///|
test "kv coord write and read step" {
  let coord = make_test_kv_coord()
  let session = coord.init_session("test-session")
  coord.init_agent(session, "agent-0")
  coord.write_step(session, "agent-0", 5)
  let agents = coord.read_all_agents(session)
  assert_true(agents.length() > 0)
  let found = agents.iter().find_first(fn(a) { a.agent_id == "agent-0" })
  assert_true(found is Some(_))
  guard found is Some(a) else { panic() }
  assert_eq(a.step, 5)
}

///|
test "kv coord append and read events" {
  let coord = make_test_kv_coord()
  let session = coord.init_session("test-session")
  coord.init_agent(session, "agent-0")
  coord.append_event(
    session,
    "agent-0",
    @agent.StepCompleted(step=1, tools_called=3),
  )
  coord.append_event(
    session,
    "agent-0",
    @agent.FileChanged(path="src/main.mbt"),
  )
  let events = coord.read_events_since(session, "agent-0", 0)
  assert_eq(events.length(), 2)
  assert_true(events[0].contains("step_completed"))
  assert_true(events[1].contains("file_changed"))
}
