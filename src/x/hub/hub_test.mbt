///| Tests for PR system

///|
/// Test adapter: TestFs -> ObjectStore
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
/// Test adapter: TestFs -> RefStore
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
      let dir = test_parent_path(ref_path)
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
fn test_parent_path(path : String) -> String {
  match path.rev_find("/") {
    None => "."
    Some(0) => "."
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
  }
}

///|
/// Test adapter: Clock
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
fn setup_repo_with_branch() -> (
  @git.TestFs,
  &@lib.ObjectStore,
  &@lib.RefStore,
  &@lib.Clock,
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
    "Alice <alice@example.com>",
    1706745600L,
    "+0000",
    "Alice <alice@example.com>",
    1706745600L,
    "+0000",
    "Initial commit\n",
  )
  let (commit_id, commit_compressed) = @git.create_commit(commit)
  write_test_object(fs, "/repo/.git", commit_id, commit_compressed)
  fs.write_string("/repo/.git/refs/heads/main", commit_id.to_hex() + "\n")
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  // Create feature branch with different content
  let feature_blob = "Hello, feature!\n"
  let (feature_blob_id, feature_blob_compressed) = @git.create_blob_string(
    feature_blob,
  )
  write_test_object(fs, "/repo/.git", feature_blob_id, feature_blob_compressed)
  let feature_tree_entries = [
    @git.TreeEntry::new("100644", "README.md", feature_blob_id),
  ]
  let (feature_tree_id, feature_tree_compressed) = @git.create_tree(
    feature_tree_entries,
  )
  write_test_object(fs, "/repo/.git", feature_tree_id, feature_tree_compressed)
  let feature_commit = @git.Commit::new(
    feature_tree_id,
    [commit_id],
    "Bob <bob@example.com>",
    1706832000L,
    "+0000",
    "Bob <bob@example.com>",
    1706832000L,
    "+0000",
    "Add feature\n",
  )
  let (feature_commit_id, feature_commit_compressed) = @git.create_commit(
    feature_commit,
  )
  write_test_object(
    fs, "/repo/.git", feature_commit_id, feature_commit_compressed,
  )
  fs.write_string(
    "/repo/.git/refs/heads/feature",
    feature_commit_id.to_hex() + "\n",
  )
  (fs, objects, refs, clock)
}

///|
fn write_test_object(
  fs : @git.TestFs,
  git_dir : String,
  id : @git.ObjectId,
  compressed : Bytes,
) -> Unit {
  let hex = id.to_hex()
  let dir = git_dir + "/objects/" + short_hex_test(hex, 0, 2)
  let path = dir + "/" + short_hex_test(hex, 2, 40)
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
}

///|
fn short_hex_test(hex : String, start : Int, end : Int) -> String {
  String::unsafe_substring(hex, start~, end~)
}

///|
test "pr: init creates notes ref on first write" {
  let (fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  assert_false(fs.is_file("/repo/.git/refs/notes/bit-hub"))
  let _ = hub.create_pr(
    objects, refs, clock, "Init PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  assert_true(fs.is_file("/repo/.git/refs/notes/bit-hub"))
}

///|
test "pr: create and get PR" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Fix authentication bug", "This PR fixes the auth issue.\n\nDetails here.",
    "refs/heads/feature", "refs/heads/main", "alice@example.com",
  )
  let pr_id = pr.id()
  assert_true(pr_id.length() > 0)
  assert_eq(pr.title(), "Fix authentication bug")
  assert_eq(pr.state(), PrState::Open)
  // Retrieve PR
  let retrieved = prs.get_pr(objects, pr_id)
  assert_true(retrieved is Some(_))
  guard retrieved is Some(r) else { panic() }
  assert_eq(r.title(), "Fix authentication bug")
  assert_eq(r.source_branch(), "refs/heads/feature")
  assert_eq(r.target_branch(), "refs/heads/main")
}

///|
test "pr: list PRs" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let _ = prs.create_pr(
    objects, refs, clock, "PR 1", "First PR", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let _ = prs.create_pr(
    objects, refs, clock, "PR 2", "Second PR", "refs/heads/feature", "refs/heads/main",
    "bob@example.com",
  )
  let all = prs.list_prs(objects)
  assert_eq(all.length(), 2)
  let open_hub = prs.list_prs(objects, state=Some(PrState::Open))
  assert_eq(open_hub.length(), 2)
}

///|
test "pr proposal: propose and list without mutating canonical PR list" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let proposed = hub.propose_pr(
    objects, refs, clock, "Proposal PR", "From external peer", "refs/heads/feature",
    "refs/heads/main", "carol@example.com",
  )
  let proposals = hub.list_pr_proposals(objects)
  assert_eq(proposals.length(), 1)
  assert_eq(proposals[0].id(), proposed.id())
  assert_eq(proposals[0].title(), "Proposal PR")
  let canonical = hub.list_prs(objects)
  assert_eq(canonical.length(), 0)
}

///|
test "pr proposal: classify as notify-only trigger" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let proposed = hub.propose_pr(
    objects, refs, clock, "Notify proposal", "Only notify should fire", "refs/heads/feature",
    "refs/heads/main", "dave@example.com",
  )
  let proposal_key = pr_proposal_meta_key(proposed.id())
  let proposal_record = hub.store.get_record(objects, proposal_key)
  guard proposal_record is Some(record) else { panic() }
  assert_eq(classify_record_trigger(record), RecordTriggerClass::NotifyOnly)
  assert_eq(record_notify_topic(record), Some("hub.pr.proposal"))
}

///|
test "pr: classify canonical records as full triggers" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let pr = hub.create_pr(
    objects, refs, clock, "Canonical PR", "Should keep full triggers", "refs/heads/feature",
    "refs/heads/main", "erin@example.com",
  )
  let key = pr_meta_key(pr.id())
  let record = hub.store.get_record(objects, key)
  guard record is Some(r) else { panic() }
  assert_eq(classify_record_trigger(r), RecordTriggerClass::Full)
  assert_eq(record_notify_topic(r), None)
}

///|
test "pr: close PR" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  prs.close_pr(objects, refs, clock, pr_id)
  let closed = prs.get_pr(objects, pr_id)
  guard closed is Some(pr) else { panic() }
  assert_eq(pr.state(), PrState::Closed)
}

///|
test "pr: reopen PR" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  prs.close_pr(objects, refs, clock, pr_id)
  prs.reopen_pr(objects, refs, clock, pr_id)
  let reopened = prs.get_pr(objects, pr_id)
  guard reopened is Some(pr2) else { panic() }
  assert_eq(pr2.state(), PrState::Open)
}

///|
test "pr: reopen open PR fails" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  ignore(
    prs.reopen_pr(objects, refs, clock, pr.id()) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("not closed"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "pr: update PR" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let pr = hub.create_pr(
    objects, refs, clock, "Original Title", "Original body", "refs/heads/feature",
    "refs/heads/main", "alice@example.com",
  )
  let pr_id = pr.id()
  // Update title and body
  let updated = hub.update_pr(
    objects,
    refs,
    clock,
    pr_id,
    title=Some("Updated Title"),
    body=Some("Updated body with more details"),
  )
  assert_eq(updated.title(), "Updated Title")
  assert_eq(updated.body(), "Updated body with more details")
  // Verify persisted
  let retrieved = hub.get_pr(objects, pr_id)
  guard retrieved is Some(pr) else { panic() }
  assert_eq(pr.title(), "Updated Title")
}

///|
test "pr: update PR labels" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let pr = hub.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  // Add labels
  let updated = hub.update_pr(
    objects,
    refs,
    clock,
    pr_id,
    labels=Some(["bug", "urgent"]),
  )
  assert_eq(updated.labels().length(), 2)
  assert_true(updated.labels().contains("bug"))
}

///|
test "pr: add and list comments" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  let c1 = prs.add_comment(
    objects, refs, clock, pr_id, "bob@example.com", "LGTM!",
  )
  let c2 = prs.add_comment(
    objects,
    refs,
    clock,
    pr_id,
    "carol@example.com",
    "One minor issue",
    file_path=Some("src/main.mbt"),
    line_number=Some(42),
  )
  assert_true(c1.id().length() > 0)
  assert_true(c2.file_path() is Some(_))
  let comments = prs.list_comments(objects, pr_id)
  assert_eq(comments.length(), 2)
  assert_eq(comments[0].body(), "LGTM!")
}

///|
test "pr: submit and list reviews" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  let feature_id = refs.resolve("refs/heads/feature")
  guard feature_id is Some(fid) else { panic() }
  let r1 = prs.submit_review(
    objects,
    refs,
    clock,
    pr_id,
    "bob@example.com",
    ReviewVerdict::Approved,
    "Looks good!",
    fid,
  )
  assert_eq(r1.verdict(), ReviewVerdict::Approved)
  let reviews = prs.list_reviews(objects, pr_id)
  assert_eq(reviews.length(), 1)
  assert_true(prs.is_approved(objects, pr_id))
}

///|
test "pr: is_approved with request changes" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  let feature_id = refs.resolve("refs/heads/feature")
  guard feature_id is Some(fid) else { panic() }
  // First approval
  let _ = prs.submit_review(
    objects,
    refs,
    clock,
    pr_id,
    "bob@example.com",
    ReviewVerdict::Approved,
    "LGTM",
    fid,
  )
  assert_true(prs.is_approved(objects, pr_id))
  // Request changes
  let _ = prs.submit_review(
    objects,
    refs,
    clock,
    pr_id,
    "carol@example.com",
    ReviewVerdict::RequestChanges,
    "Please fix X",
    fid,
  )
  assert_false(prs.is_approved(objects, pr_id))
}

///|
test "pr: merge fast-forward" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let pr = prs.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  assert_true(prs.can_merge(objects, refs, pr_id))
  let result = prs.merge_pr(
    objects,
    refs,
    clock,
    pr_id,
    "alice@example.com",
    strategy=PrMergeStrategy::FastForward,
  )
  assert_true(result.success())
  assert_true(result.commit_id() is Some(_))
  assert_eq(result.message(), "Fast-forward merge completed")
  // Verify PR is marked as merged
  let merged = prs.get_pr(objects, pr_id)
  guard merged is Some(pr) else { panic() }
  assert_eq(pr.state(), PrState::Merged)
}

///|
test "pr: merge squash" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let pr = hub.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  let result = hub.merge_pr(
    objects,
    refs,
    clock,
    pr_id,
    "alice@example.com",
    strategy=PrMergeStrategy::Squash,
  )
  assert_true(result.success())
  assert_eq(result.message(), "Squash merge completed")
  let merged = hub.get_pr(objects, pr_id)
  guard merged is Some(pr) else { panic() }
  assert_eq(pr.state(), PrState::Merged)
}

///|
test "pr: merge commit" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let pr = hub.create_pr(
    objects, refs, clock, "Test PR", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = pr.id()
  let result = hub.merge_pr(
    objects,
    refs,
    clock,
    pr_id,
    "alice@example.com",
    strategy=PrMergeStrategy::Merge,
  )
  assert_true(result.success())
  assert_eq(result.message(), "Merge commit created")
  let merged = hub.get_pr(objects, pr_id)
  guard merged is Some(pr) else { panic() }
  assert_eq(pr.state(), PrState::Merged)
}

///|
test "format: serialize and parse PullRequest" {
  let pr = PullRequest::new(
    "42",
    "Test PR",
    "Description\nwith multiple lines",
    "refs/heads/feature",
    @git.ObjectId::zero(),
    "refs/heads/main",
    @git.ObjectId::zero(),
    "alice@example.com",
    1706745600L,
    1706832000L,
    PrState::Open,
    ["bug", "urgent"],
  )
  let serialized = pr.serialize()
  let parsed = parse_pull_request(serialized)
  assert_eq(parsed.id(), "42")
  assert_eq(parsed.title(), "Test PR")
  assert_eq(parsed.labels().length(), 2)
  assert_true(parsed.labels().contains("bug"))
}

///|
test "format: serialize and parse PullRequest with source metadata" {
  let pr = PullRequest::new(
    "44",
    "Fork PR",
    "Body",
    "feature",
    @git.ObjectId::zero(),
    "main",
    @git.ObjectId::zero(),
    "alice@example.com",
    1706745600L,
    1706832000L,
    PrState::Open,
    [],
    source_repo=Some("contrib/bit"),
    source_ref=Some("refs/heads/feature"),
  )
  let serialized = pr.serialize()
  let parsed = parse_pull_request(serialized)
  guard parsed.source_repo() is Some(repo) else { panic() }
  assert_eq(repo, "contrib/bit")
  guard parsed.source_ref() is Some(source_ref) else { panic() }
  assert_eq(source_ref, "refs/heads/feature")
}

///|
test "format: serialize and parse PrComment" {
  let comment = PrComment::new(
    "abc123",
    "1",
    "bob@example.com",
    "Great work!",
    1706832000L,
    file_path=Some("src/lib.mbt"),
    line_number=Some(42),
  )
  let serialized = comment.serialize()
  let parsed = parse_pr_comment(serialized)
  assert_eq(parsed.id(), "abc123")
  assert_eq(parsed.pr_id(), "1")
  assert_true(parsed.file_path() is Some(_))
  guard parsed.file_path() is Some(fp) else { panic() }
  assert_eq(fp, "src/lib.mbt")
}

///|
test "format: serialize and parse PrReview" {
  let review = PrReview::new(
    "rev123",
    "1",
    "carol@example.com",
    ReviewVerdict::Approved,
    "LGTM!",
    1706918400L,
    @git.ObjectId::zero(),
  )
  let serialized = review.serialize()
  let parsed = parse_pr_review(serialized)
  assert_eq(parsed.id(), "rev123")
  assert_eq(parsed.verdict(), ReviewVerdict::Approved)
}

///|
test "issue: create and get issue" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let issue = prs.create_issue(
    objects,
    refs,
    clock,
    "Bug report",
    "Description of the bug",
    "alice@example.com",
    labels=["bug"],
  )
  let issue_id = issue.id()
  assert_true(issue_id.length() > 0)
  assert_eq(issue.title(), "Bug report")
  assert_eq(issue.state(), IssueState::Open)
  let retrieved = prs.get_issue(objects, issue_id)
  assert_true(retrieved is Some(_))
  guard retrieved is Some(i) else { panic() }
  assert_eq(i.title(), "Bug report")
  assert_eq(i.labels().length(), 1)
}

///|
test "issue: list issues" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let _ = prs.create_issue(
    objects, refs, clock, "Issue 1", "First", "alice@example.com",
  )
  let _ = prs.create_issue(
    objects, refs, clock, "Issue 2", "Second", "bob@example.com",
  )
  let all = prs.list_issues(objects)
  assert_eq(all.length(), 2)
  let open_issues = prs.list_issues(objects, state=Some(IssueState::Open))
  assert_eq(open_issues.length(), 2)
}

///|
test "issue: close issue" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let issue = prs.create_issue(
    objects, refs, clock, "Test Issue", "Body", "alice@example.com",
  )
  let issue_id = issue.id()
  prs.close_issue(objects, refs, clock, issue_id)
  let closed = prs.get_issue(objects, issue_id)
  guard closed is Some(issue) else { panic() }
  assert_eq(issue.state(), IssueState::Closed)
}

///|
test "issue: reopen issue" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let issue = prs.create_issue(
    objects, refs, clock, "Test Issue", "Body", "alice@example.com",
  )
  let issue_id = issue.id()
  prs.close_issue(objects, refs, clock, issue_id)
  prs.reopen_issue(objects, refs, clock, issue_id)
  let reopened = prs.get_issue(objects, issue_id)
  guard reopened is Some(issue2) else { panic() }
  assert_eq(issue2.state(), IssueState::Open)
}

///|
test "issue: reopen open issue fails" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let issue = prs.create_issue(
    objects, refs, clock, "Test Issue", "Body", "alice@example.com",
  )
  ignore(
    prs.reopen_issue(objects, refs, clock, issue.id()) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("not closed"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "issue: add and list comments" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let issue = prs.create_issue(
    objects, refs, clock, "Test Issue", "Body", "alice@example.com",
  )
  let issue_id = issue.id()
  let c1 = prs.add_issue_comment(
    objects, refs, clock, issue_id, "bob@example.com", "Thanks for reporting!",
  )
  let c2 = prs.add_issue_comment(
    objects, refs, clock, issue_id, "carol@example.com", "I can reproduce this",
  )
  assert_true(c1.id().length() > 0)
  assert_true(c2.id().length() > 0)
  let comments = prs.list_issue_comments(objects, issue_id)
  assert_eq(comments.length(), 2)
}

///|
test "issue: link PR to issue" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let prs = Hub::init(objects, refs)
  let issue = prs.create_issue(
    objects, refs, clock, "Bug", "Fix needed", "alice@example.com",
  )
  let pr = prs.create_pr(
    objects, refs, clock, "Fix bug", "Fixes #1", "refs/heads/feature", "refs/heads/main",
    "bob@example.com",
  )
  let issue_id = issue.id()
  let pr_id = pr.id()
  prs.link_pr_to_issue(objects, refs, clock, issue_id, pr_id)
  let updated = prs.get_issue(objects, issue_id)
  guard updated is Some(i) else { panic() }
  assert_eq(i.linked_prs().length(), 1)
  assert_true(i.linked_prs().contains(pr_id))
}

///|
test "issue: update issue" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let issue = hub.create_issue(
    objects, refs, clock, "Original Title", "Original body", "alice@example.com",
  )
  let issue_id = issue.id()
  let updated = hub.update_issue(
    objects,
    refs,
    clock,
    issue_id,
    title=Some("Updated Title"),
    body=Some("Updated body"),
  )
  assert_eq(updated.title(), "Updated Title")
  assert_eq(updated.body(), "Updated body")
  let retrieved = hub.get_issue(objects, issue_id)
  guard retrieved is Some(issue) else { panic() }
  assert_eq(issue.title(), "Updated Title")
}

///|
test "issue: update issue labels and assignees" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let issue = hub.create_issue(
    objects, refs, clock, "Bug", "Details", "alice@example.com",
  )
  let issue_id = issue.id()
  let updated = hub.update_issue(
    objects,
    refs,
    clock,
    issue_id,
    labels=Some(["bug", "critical"]),
    assignees=Some(["bob@example.com"]),
  )
  assert_eq(updated.labels().length(), 2)
  assert_eq(updated.assignees().length(), 1)
  assert_true(updated.assignees().contains("bob@example.com"))
}

///|
test "format: serialize and parse Issue" {
  let issue = Issue::new(
    "42",
    "Bug report",
    "Description\nwith details",
    "alice@example.com",
    1706745600L,
    1706832000L,
    IssueState::Open,
    labels=["bug", "urgent"],
    assignees=["bob@example.com"],
  )
  let serialized = issue.serialize()
  let parsed = parse_issue(serialized)
  assert_eq(parsed.id(), "42")
  assert_eq(parsed.title(), "Bug report")
  assert_eq(parsed.labels().length(), 2)
  assert_eq(parsed.assignees().length(), 1)
}

///|
test "format: serialize and parse IssueComment" {
  let comment = IssueComment::new(
    "abc123", "1", "bob@example.com", "Thanks!", 1706832000L,
  )
  let serialized = comment.serialize()
  let parsed = parse_issue_comment(serialized)
  assert_eq(parsed.id(), "abc123")
  assert_eq(parsed.issue_id(), "1")
}

///|
test "notes: add and get note" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let commit_id = refs.resolve("refs/heads/main")
  guard commit_id is Some(cid) else { panic() }
  let note = hub.add_note(
    objects, refs, clock, cid, "This commit introduces the initial README.", "alice@example.com",
    1706745600L,
  )
  assert_eq(note.body(), "This commit introduces the initial README.")
  assert_eq(note.author(), "alice@example.com")
  let retrieved = hub.get_note(objects, refs, cid)
  assert_true(retrieved is Some(_))
  guard retrieved is Some(n) else { panic() }
  assert_eq(n.body(), "This commit introduces the initial README.")
}

///|
test "notes: list notes" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let main_commit = refs.resolve("refs/heads/main")
  guard main_commit is Some(main_id) else { panic() }
  let feature_commit = refs.resolve("refs/heads/feature")
  guard feature_commit is Some(feature_id) else { panic() }
  let _ = hub.add_note(
    objects, refs, clock, main_id, "Note on main", "alice@example.com", 1706745600L,
  )
  let _ = hub.add_note(
    objects, refs, clock, feature_id, "Note on feature", "bob@example.com", 1706832000L,
  )
  let notes = hub.list_notes(objects, refs)
  assert_eq(notes.length(), 2)
}

///|
test "notes: remove note" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let commit_id = refs.resolve("refs/heads/main")
  guard commit_id is Some(cid) else { panic() }
  let _ = hub.add_note(
    objects, refs, clock, cid, "Temporary note", "alice@example.com", 1706745600L,
  )
  let before = hub.get_note(objects, refs, cid)
  assert_true(before is Some(_))
  hub.remove_note(objects, refs, clock, cid)
  let after = hub.get_note(objects, refs, cid)
  assert_true(after is None)
}

///|
test "notes: custom ns" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let commit_id = refs.resolve("refs/heads/main")
  guard commit_id is Some(cid) else { panic() }
  let _ = hub.add_note(
    objects,
    refs,
    clock,
    cid,
    "Pro tip: use --verbose flag",
    "alice@example.com",
    1706745600L,
    ns="tips",
  )
  let default_note = hub.get_note(objects, refs, cid)
  assert_true(default_note is None)
  let tips_note = hub.get_note(objects, refs, cid, ns="tips")
  assert_true(tips_note is Some(_))
}

///|
test "hub_record version round-trip" {
  let record = @hub.HubRecord::new(
    "hub/pr/1/meta",
    "pr",
    "some payload",
    "node-a",
    1706745600L,
    version=1,
  )
  let serialized = record.serialize()
  let parsed = @hub.parse_hub_record(serialized)
  assert_eq(parsed.version, 1)
  assert_eq(parsed.key, "hub/pr/1/meta")
  assert_eq(parsed.kind, "pr")
  assert_eq(parsed.node, "node-a")
}

///|
test "hub_record signature round-trip" {
  let record = @hub.HubRecord::new(
    "hub/pr/1/meta",
    "pr",
    "some payload",
    "node-a",
    1706745600L,
    signature=Some("deadbeef"),
  )
  let serialized = record.serialize()
  let parsed = @hub.parse_hub_record(serialized)
  assert_eq(parsed.signature, Some("deadbeef"))
}

///|
test "hub_record version=0 backward compat" {
  // Manually construct text without version line
  let text =
    #|key hub/pr/1/meta
    #|kind pr
    #|clock
    #|timestamp 1706745600
    #|node node-a
    #|deleted 0
    #|
    #|payload data
  let parsed = @hub.parse_hub_record(text)
  assert_eq(parsed.version, 0)
  assert_eq(parsed.key, "hub/pr/1/meta")
}

///|
test "pr merge_commit round-trip" {
  let merge_id = @git.ObjectId::from_hex(
    "abcdef0123456789abcdef0123456789abcdef01",
  ) catch {
    _ => panic()
  }
  let pr = PullRequest::new(
    "42",
    "Test PR",
    "Body",
    "refs/heads/feature",
    @git.ObjectId::zero(),
    "refs/heads/main",
    @git.ObjectId::zero(),
    "alice@example.com",
    1706745600L,
    1706832000L,
    PrState::Open,
    [],
    merge_commit=Some(merge_id),
  )
  let serialized = pr.serialize()
  let parsed = parse_pull_request(serialized) catch { _ => panic() }
  assert_true(parsed.merge_commit() is Some(_))
  guard parsed.merge_commit() is Some(mc) else { panic() }
  assert_eq(mc.to_hex(), "abcdef0123456789abcdef0123456789abcdef01")
}

///|
test "pr merge_commit none round-trip" {
  let pr = PullRequest::new(
    "43",
    "No merge commit",
    "Body",
    "refs/heads/feature",
    @git.ObjectId::zero(),
    "refs/heads/main",
    @git.ObjectId::zero(),
    "bob@example.com",
    1706745600L,
    1706832000L,
    PrState::Open,
    [],
  )
  let serialized = pr.serialize()
  let parsed = parse_pull_request(serialized) catch { _ => panic() }
  assert_true(parsed.merge_commit() is None)
}

///|
test "pr: merge uses source_commit when source branch is missing" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let source_id = refs.resolve("refs/heads/feature")
  guard source_id is Some(sid) else { panic() }
  let target_id = refs.resolve("refs/heads/main")
  guard target_id is Some(tid) else { panic() }
  let pr = PullRequest::new(
    "9000",
    "Forked branch PR",
    "Body",
    "missing-fork-branch",
    sid,
    "refs/heads/main",
    tid,
    "contrib@example.com",
    1706745600L,
    1706832000L,
    PrState::Open,
    [],
    source_repo=Some("contrib/bit"),
    source_ref=Some("refs/heads/missing-fork-branch"),
  )
  let _ = hub.import_prs(objects, refs, clock, [pr])
  let result = hub.merge_pr(
    objects,
    refs,
    clock,
    "9000",
    "maintainer@example.com",
    strategy=PrMergeStrategy::Merge,
  )
  assert_true(result.success())
}

///|
test "signature: require_signed hides unsigned records" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let unsigned_hub = Hub::init(objects, refs)
  let strict_hub = Hub::init(
    objects,
    refs,
    signing_key=Some("k1"),
    require_signed=true,
  )
  let unsigned_pr = unsigned_hub.create_pr(
    objects, refs, clock, "Unsigned", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  strict_hub.reload_store(objects, refs)
  let strict_view = strict_hub.get_pr(objects, unsigned_pr.id())
  assert_true(strict_view is None)
  let signed_pr = strict_hub.create_pr(
    objects, refs, clock, "Signed", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let strict_signed = strict_hub.get_pr(objects, signed_pr.id())
  assert_true(strict_signed is Some(_))
}

///|
test "signature: wrong key hides signed records" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let writer = Hub::init(
    objects,
    refs,
    signing_key=Some("writer-key"),
    require_signed=true,
  )
  let reader = Hub::init(
    objects,
    refs,
    signing_key=Some("reader-key"),
    require_signed=true,
  )
  let pr = writer.create_pr(
    objects, refs, clock, "Signed", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  reader.reload_store(objects, refs)
  let seen = reader.get_pr(objects, pr.id())
  assert_true(seen is None)
}

///|
test "signature: require_signed without key rejects writes" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let strict = Hub::init(objects, refs, require_signed=true)
  ignore(
    strict.create_pr(
      objects, refs, clock, "Signed", "Body", "refs/heads/feature", "refs/heads/main",
      "alice@example.com",
    ) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("signing key"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "signature: require_signed hides unsigned proposal records" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let unsigned_hub = Hub::init(objects, refs)
  let strict_hub = Hub::init(
    objects,
    refs,
    signing_key=Some("k1"),
    require_signed=true,
  )
  let _ = unsigned_hub.propose_pr(
    objects, refs, clock, "Unsigned proposal", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  strict_hub.reload_store(objects, refs)
  let strict_view = strict_hub.list_pr_proposals(objects)
  assert_eq(strict_view.length(), 0)
  let signed = strict_hub.propose_pr(
    objects, refs, clock, "Signed proposal", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let strict_signed = strict_hub.list_pr_proposals(objects)
  assert_eq(strict_signed.length(), 1)
  assert_eq(strict_signed[0].id(), signed.id())
}

///|
test "signature: wrong key hides signed proposal records" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let writer = Hub::init(
    objects,
    refs,
    signing_key=Some("writer-key"),
    require_signed=true,
  )
  let reader = Hub::init(
    objects,
    refs,
    signing_key=Some("reader-key"),
    require_signed=true,
  )
  let _ = writer.propose_pr(
    objects, refs, clock, "Signed proposal", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  reader.reload_store(objects, refs)
  let seen = reader.list_pr_proposals(objects)
  assert_eq(seen.length(), 0)
}

///|
test "signature: require_signed without key rejects proposal writes" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let strict = Hub::init(objects, refs, require_signed=true)
  ignore(
    strict.propose_pr(
      objects, refs, clock, "Signed proposal", "Body", "refs/heads/feature", "refs/heads/main",
      "alice@example.com",
    ) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("signing key"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "format: serialize and parse Note" {
  let note = Note::new(
    @git.ObjectId::zero(),
    "This is a helpful note.",
    "alice@example.com",
    1706745600L,
    ns="commits",
  )
  let serialized = note.serialize()
  let parsed = parse_note(serialized)
  assert_eq(parsed.body(), "This is a helpful note.")
  assert_eq(parsed.author(), "alice@example.com")
  assert_eq(parsed.ns(), "commits")
}
