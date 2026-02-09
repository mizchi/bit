///| Tests for agent workflow and policy

///|
struct TestObjectStore {
  fs : @git.TestFs
  git_dir : String
}

///|
impl @lib.ObjectStore for TestObjectStore with get(self, id) {
  let db = @lib.ObjectDb::load_lazy(self.fs, self.git_dir)
  db.get(self.fs, id)
}

///|
impl @lib.ObjectStore for TestObjectStore with put(self, obj_type, content) {
  let (id, compressed) = @git.create_object(obj_type, content)
  let hex = id.to_hex()
  let dir = self.git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2)
  let path = dir + "/" + String::unsafe_substring(hex, start=2, end=40)
  self.fs.mkdir_p(dir)
  self.fs.write_file(path, compressed)
  id
}

///|
impl @lib.ObjectStore for TestObjectStore with has(self, id) {
  let db = @lib.ObjectDb::load_lazy(self.fs, self.git_dir)
  let obj = db.get(self.fs, id)
  obj is Some(_)
}

///|
struct TestRefStore {
  fs : @git.TestFs
  git_dir : String
}

///|
impl @lib.RefStore for TestRefStore with resolve(self, ref_name) {
  @lib.resolve_ref(self.fs, self.git_dir, ref_name)
}

///|
impl @lib.RefStore for TestRefStore with update(self, ref_name, id) {
  match id {
    Some(commit_id) => {
      let ref_path = self.git_dir + "/" + ref_name
      let dir = parent_path(ref_path)
      self.fs.mkdir_p(dir)
      self.fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    None => ()
  }
}

///|
impl @lib.RefStore for TestRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
fn parent_path(path : String) -> String {
  match path.rev_find("/") {
    None => "."
    Some(0) => "."
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
  }
}

///|
struct TestClock {
  mut time : Int64
}

///|
impl @lib.Clock for TestClock with now(self) {
  let t = self.time
  self.time = self.time + 1L
  t
}

///|
struct TestWorkingTree {
  files : Map[String, Bytes]
  fs : @git.TestFs
  git_dir : String
  mut last_commit : @git.ObjectId?
}

///|
impl @lib.WorkingTree for TestWorkingTree with read_file(self, path) {
  match self.files.get(path) {
    Some(content) => content
    None => raise @git.GitError::InvalidObject("file not found: \{path}")
  }
}

///|
impl @lib.WorkingTree for TestWorkingTree with write_file(self, path, content) {
  self.files[path] = content
}

///|
impl @lib.WorkingTree for TestWorkingTree with remove_file(self, path) {
  ignore(self.files.remove(path))
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_file(self, path) {
  self.files.contains(path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_dir(self, _path) {
  ignore(self)
  false
}

///|
impl @lib.WorkingTree for TestWorkingTree with readdir(self, _path) {
  ignore(self)
  []
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_dirty(self) {
  ignore(self)
  true
}

///|
impl @lib.WorkingTree for TestWorkingTree with rollback(self) {
  self.files.clear()
}

///|
impl @lib.WorkingTree for TestWorkingTree with get_working_files(self) {
  let result : Array[String] = []
  for key, _ in self.files {
    result.push(key)
  }
  result
}

///|
impl @lib.WorkingTree for TestWorkingTree with snapshot(
  self,
  message,
  author,
  timestamp,
) {
  // Build tree entries from files
  let entries : Array[@git.TreeEntry] = []
  for path, content in self.files {
    let (blob_id, blob_compressed) = @git.create_object(
      @git.ObjectType::Blob,
      content,
    )
    write_test_object(self.fs, self.git_dir, blob_id, blob_compressed)
    entries.push(@git.TreeEntry::new("100644", path, blob_id))
  }
  entries.sort_by(fn(a, b) { a.name.compare(b.name) })
  let (tree_id, tree_compressed) = @git.create_tree(entries)
  write_test_object(self.fs, self.git_dir, tree_id, tree_compressed)
  let parents = match self.last_commit {
    Some(id) => [id]
    None => []
  }
  let commit = @git.Commit::new(
    tree_id,
    parents,
    "\{author} <\{author}@agent>",
    timestamp,
    "+0000",
    "\{author} <\{author}@agent>",
    timestamp,
    "+0000",
    message + "\n",
  )
  let (commit_id, commit_compressed) = @git.create_commit(commit)
  write_test_object(self.fs, self.git_dir, commit_id, commit_compressed)
  self.last_commit = Some(commit_id)
  commit_id
}

///|
impl @lib.WorkingTree for TestWorkingTree with checkout(self, _commit_id) {
  ignore(self)
}

///|
fn write_test_object(
  fs : @git.TestFs,
  git_dir : String,
  id : @git.ObjectId,
  compressed : Bytes,
) -> Unit {
  let hex = id.to_hex()
  let dir = git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2)
  let path = dir + "/" + String::unsafe_substring(hex, start=2, end=40)
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
}

///|
fn setup_test() -> (
  @git.TestFs,
  &@lib.ObjectStore,
  &@lib.RefStore,
  &@lib.Clock,
  &@lib.WorkingTree,
) {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git/refs/heads")
  fs.mkdir_p("/repo/.git/objects")
  let objects : TestObjectStore = { fs, git_dir: "/repo/.git" }
  let refs : TestRefStore = { fs, git_dir: "/repo/.git" }
  let clock : TestClock = { time: 1706745600L }
  // Create initial commit on main
  let blob_content = "Hello, world!\n"
  let (blob_id, blob_compressed) = @git.create_blob_string(blob_content)
  write_test_object(fs, "/repo/.git", blob_id, blob_compressed)
  let tree_entries = [@git.TreeEntry::new("100644", "README.md", blob_id)]
  let (tree_id, tree_compressed) = @git.create_tree(tree_entries)
  write_test_object(fs, "/repo/.git", tree_id, tree_compressed)
  let commit = @git.Commit::new(
    tree_id,
    [],
    "test <test@example.com>",
    1706745600L,
    "+0000",
    "test <test@example.com>",
    1706745600L,
    "+0000",
    "Initial commit\n",
  )
  let (commit_id, commit_compressed) = @git.create_commit(commit)
  write_test_object(fs, "/repo/.git", commit_id, commit_compressed)
  fs.write_string("/repo/.git/refs/heads/main", commit_id.to_hex() + "\n")
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  let tree : TestWorkingTree = {
    files: {},
    fs,
    git_dir: "/repo/.git",
    last_commit: Some(commit_id),
  }
  tree.files["README.md"] = b"Hello, world!\n"
  (fs, objects, refs, clock, tree)
}

///|
test "execute_task creates PR" {
  let (_fs, objects, refs, clock, tree) = setup_test()
  let hub = @hub.Hub::init(objects, refs)
  let config = @agent.AgentConfig::new(
    "agent-1",
    "http://localhost:8080",
    target_branch="main",
  )
  let task = @agent.AgentTask::new(
    "task-1",
    "Add hello.txt",
    [@agent.FileEdit::Write("hello.txt", b"Hello from agent\n")],
    "Add hello.txt",
    "This adds a hello file",
    "agent-1/task-1",
  )
  let result = @agent.execute_task(
    task, config, hub, objects, refs, clock, tree,
  )
  guard result is @agent.TaskResult::PrCreated(pr_id) else {
    fail("expected PrCreated, got \{result}")
  }
  // Verify PR exists
  let pr = hub.get_pr(objects, pr_id)
  assert_true(pr is Some(_))
  let pr = pr.unwrap()
  assert_eq(pr.title(), "Add hello.txt")
  assert_eq(pr.source_branch(), "refs/heads/agent-1/task-1")
  assert_eq(pr.target_branch(), "refs/heads/main")
  assert_eq(pr.author(), "agent-1")
}

///|
test "check_and_merge merges approved PR" {
  let (_fs, objects, refs, clock, tree) = setup_test()
  let hub = @hub.Hub::init(objects, refs)
  let config = @agent.AgentConfig::new(
    "agent-1",
    "http://localhost:8080",
    target_branch="main",
  )
  let task = @agent.AgentTask::new(
    "task-2",
    "Add file",
    [@agent.FileEdit::Write("file.txt", b"content\n")],
    "Add file",
    "body",
    "agent-1/task-2",
  )
  let result = @agent.execute_task(
    task, config, hub, objects, refs, clock, tree,
  )
  guard result is @agent.TaskResult::PrCreated(pr_id) else {
    fail("expected PrCreated")
  }
  // Not approved yet → rejected
  let merge_result = @agent.check_and_merge(
    pr_id, config, hub, objects, refs, clock,
  )
  assert_eq(merge_result, @agent.TaskResult::PrRejected(pr_id, "not approved"))
  // Approve the PR
  let pr = hub.get_pr(objects, pr_id).unwrap()
  ignore(
    hub.submit_review(
      objects,
      refs,
      clock,
      pr_id,
      "reviewer-1",
      @hub.ReviewVerdict::Approved,
      "LGTM",
      pr.source_commit(),
    ),
  )
  // Now merge should succeed
  let merge_result2 = @agent.check_and_merge(
    pr_id, config, hub, objects, refs, clock,
  )
  assert_eq(merge_result2, @agent.TaskResult::PrMerged(pr_id))
}

///|
test "evaluate_validation pass" {
  assert_eq(@agent.evaluate_validation(0, "ok"), @agent.ReviewResult::Approved)
}

///|
test "evaluate_validation fail" {
  let result = @agent.evaluate_validation(1, "tests failed")
  guard result is @agent.ReviewResult::Rejected(_) else {
    fail("expected Rejected")
  }
}

///|
test "should_auto_review filters correctly" {
  let (_fs, objects, refs, clock, _tree) = setup_test()
  let hub = @hub.Hub::init(objects, refs)
  let config = @agent.AgentConfig::new(
    "agent-1",
    "http://localhost:8080",
    target_branch="main",
  )
  // Create a PR by a different author
  let source_ref = refs.resolve("refs/heads/main").unwrap()
  refs.update("refs/heads/other-feature", Some(source_ref))
  let pr = hub.create_pr(
    objects, refs, clock, "Feature PR", "body", "refs/heads/other-feature", "refs/heads/main",
    "other-agent",
  )
  assert_true(@agent.should_auto_review(pr, config))
  // PR by self should not be reviewed
  let pr_self = hub.create_pr(
    objects, refs, clock, "My PR", "body", "refs/heads/other-feature", "refs/heads/main",
    "agent-1",
  )
  assert_false(@agent.should_auto_review(pr_self, config))
}
