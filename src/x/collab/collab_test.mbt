///| Tests for PR system

///|
fn setup_repo_with_branch() -> @git.TestFs {
  let fs = @git.TestFs::new()
  // Initialize basic git structure
  fs.mkdir_p("/repo/.git/refs/heads")
  fs.mkdir_p("/repo/.git/objects")
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
  // Set main branch
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
  // Set feature branch
  fs.write_string(
    "/repo/.git/refs/heads/feature",
    feature_commit_id.to_hex() + "\n",
  )
  fs
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
test "pr: init creates _den branch" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  assert_true(fs.is_file("/repo/.git/refs/heads/_den"))
  assert_eq(prs.next_id, 1)
}

///|
test "pr: create and get PR" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let pr = prs.create_pr(
    fs, fs, "Fix authentication bug", "This PR fixes the auth issue.\n\nDetails here.",
    "refs/heads/feature", "refs/heads/main", "alice@example.com", 1706745600L,
  )
  assert_eq(pr.id(), "1")
  assert_eq(pr.title(), "Fix authentication bug")
  assert_eq(pr.state(), PrState::Open)
  // Retrieve PR
  let retrieved = prs.get_pr(fs, "1")
  assert_true(retrieved is Some(_))
  guard retrieved is Some(r) else { panic() }
  assert_eq(r.title(), "Fix authentication bug")
  assert_eq(r.source_branch(), "refs/heads/feature")
  assert_eq(r.target_branch(), "refs/heads/main")
}

///|
test "pr: list PRs" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_pr(
    fs, fs, "PR 1", "First PR", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  let _ = prs.create_pr(
    fs, fs, "PR 2", "Second PR", "refs/heads/feature", "refs/heads/main", "bob@example.com",
    1706832000L,
  )
  let all = prs.list_prs(fs)
  assert_eq(all.length(), 2)
  let open_den = prs.list_prs(fs, state=Some(PrState::Open))
  assert_eq(open_den.length(), 2)
}

///|
test "pr: close PR" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  prs.close_pr(fs, fs, "1", 1706918400L)
  let closed = prs.get_pr(fs, "1")
  guard closed is Some(pr) else { panic() }
  assert_eq(pr.state(), PrState::Closed)
}

///|
test "pr: update PR" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let _ = den.create_pr(
    fs, fs, "Original Title", "Original body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com", 1706745600L,
  )
  // Update title and body
  let updated = den.update_pr(
    fs,
    fs,
    "1",
    1706832000L,
    title=Some("Updated Title"),
    body=Some("Updated body with more details"),
  )
  assert_eq(updated.title(), "Updated Title")
  assert_eq(updated.body(), "Updated body with more details")
  // Verify persisted
  let retrieved = den.get_pr(fs, "1")
  guard retrieved is Some(pr) else { panic() }
  assert_eq(pr.title(), "Updated Title")
}

///|
test "pr: update PR labels" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let _ = den.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  // Add labels
  let updated = den.update_pr(
    fs,
    fs,
    "1",
    1706832000L,
    labels=Some(["bug", "urgent"]),
  )
  assert_eq(updated.labels().length(), 2)
  assert_true(updated.labels().contains("bug"))
}

///|
test "pr: add and list comments" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  let c1 = prs.add_comment(fs, fs, "1", "bob@example.com", "LGTM!", 1706832000L)
  let c2 = prs.add_comment(
    fs,
    fs,
    "1",
    "carol@example.com",
    "One minor issue",
    1706918400L,
    file_path=Some("src/main.mbt"),
    line_number=Some(42),
  )
  assert_true(c1.id().length() > 0)
  assert_true(c2.file_path() is Some(_))
  let comments = prs.list_comments(fs, "1")
  assert_eq(comments.length(), 2)
  assert_eq(comments[0].body(), "LGTM!")
}

///|
test "pr: submit and list reviews" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  let feature_id = @lib.resolve_ref(fs, "/repo/.git", "refs/heads/feature")
  guard feature_id is Some(fid) else { panic() }
  let r1 = prs.submit_review(
    fs,
    fs,
    "1",
    "bob@example.com",
    ReviewVerdict::Approved,
    "Looks good!",
    fid,
    1706832000L,
  )
  assert_eq(r1.verdict(), ReviewVerdict::Approved)
  let reviews = prs.list_reviews(fs, "1")
  assert_eq(reviews.length(), 1)
  assert_true(prs.is_approved(fs, "1"))
}

///|
test "pr: is_approved with request changes" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  let feature_id = @lib.resolve_ref(fs, "/repo/.git", "refs/heads/feature")
  guard feature_id is Some(fid) else { panic() }
  // First approval
  let _ = prs.submit_review(
    fs,
    fs,
    "1",
    "bob@example.com",
    ReviewVerdict::Approved,
    "LGTM",
    fid,
    1706832000L,
  )
  assert_true(prs.is_approved(fs, "1"))
  // Request changes
  let _ = prs.submit_review(
    fs,
    fs,
    "1",
    "carol@example.com",
    ReviewVerdict::RequestChanges,
    "Please fix X",
    fid,
    1706918400L,
  )
  assert_false(prs.is_approved(fs, "1"))
}

///|
test "pr: merge fast-forward" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  assert_true(prs.can_merge(fs, "1"))
  let result = prs.merge_pr(
    fs,
    fs,
    "1",
    "alice@example.com",
    1707004800L,
    strategy=PrMergeStrategy::FastForward,
  )
  assert_true(result.success())
  assert_true(result.commit_id() is Some(_))
  assert_eq(result.message(), "Fast-forward merge completed")
  // Verify PR is marked as merged
  let merged = prs.get_pr(fs, "1")
  guard merged is Some(pr) else { panic() }
  assert_eq(pr.state(), PrState::Merged)
}

///|
test "pr: merge squash" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let _ = den.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  let result = den.merge_pr(
    fs,
    fs,
    "1",
    "alice@example.com",
    1707004800L,
    strategy=PrMergeStrategy::Squash,
  )
  assert_true(result.success())
  assert_eq(result.message(), "Squash merge completed")
  // Verify PR is marked as merged
  let merged = den.get_pr(fs, "1")
  guard merged is Some(pr) else { panic() }
  assert_eq(pr.state(), PrState::Merged)
}

///|
test "pr: merge commit" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let _ = den.create_pr(
    fs, fs, "Test PR", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  let result = den.merge_pr(
    fs,
    fs,
    "1",
    "alice@example.com",
    1707004800L,
    strategy=PrMergeStrategy::Merge,
  )
  assert_true(result.success())
  assert_eq(result.message(), "Merge commit created")
  // Verify PR is marked as merged
  let merged = den.get_pr(fs, "1")
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
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let issue = prs.create_issue(
    fs,
    fs,
    "Bug report",
    "Description of the bug",
    "alice@example.com",
    1706745600L,
    labels=["bug"],
  )
  assert_eq(issue.id(), "1")
  assert_eq(issue.title(), "Bug report")
  assert_eq(issue.state(), IssueState::Open)
  // Retrieve issue
  let retrieved = prs.get_issue(fs, "1")
  assert_true(retrieved is Some(_))
  guard retrieved is Some(i) else { panic() }
  assert_eq(i.title(), "Bug report")
  assert_eq(i.labels().length(), 1)
}

///|
test "issue: list issues" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_issue(
    fs, fs, "Issue 1", "First", "alice@example.com", 1706745600L,
  )
  let _ = prs.create_issue(
    fs, fs, "Issue 2", "Second", "bob@example.com", 1706832000L,
  )
  let all = prs.list_issues(fs)
  assert_eq(all.length(), 2)
  let open_issues = prs.list_issues(fs, state=Some(IssueState::Open))
  assert_eq(open_issues.length(), 2)
}

///|
test "issue: close issue" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_issue(
    fs, fs, "Test Issue", "Body", "alice@example.com", 1706745600L,
  )
  prs.close_issue(fs, fs, "1", 1706918400L)
  let closed = prs.get_issue(fs, "1")
  guard closed is Some(issue) else { panic() }
  assert_eq(issue.state(), IssueState::Closed)
}

///|
test "issue: add and list comments" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let _ = prs.create_issue(
    fs, fs, "Test Issue", "Body", "alice@example.com", 1706745600L,
  )
  let c1 = prs.add_issue_comment(
    fs, fs, "1", "bob@example.com", "Thanks for reporting!", 1706832000L,
  )
  let c2 = prs.add_issue_comment(
    fs, fs, "1", "carol@example.com", "I can reproduce this", 1706918400L,
  )
  assert_true(c1.id().length() > 0)
  assert_true(c2.id().length() > 0)
  let comments = prs.list_issue_comments(fs, "1")
  assert_eq(comments.length(), 2)
}

///|
test "issue: link PR to issue" {
  let fs = setup_repo_with_branch()
  let prs = Collab::init(fs, fs, "/repo/.git")
  let issue = prs.create_issue(
    fs, fs, "Bug", "Fix needed", "alice@example.com", 1706745600L,
  )
  let pr = prs.create_pr(
    fs, fs, "Fix bug", "Fixes #1", "refs/heads/feature", "refs/heads/main", "bob@example.com",
    1706832000L,
  )
  prs.link_pr_to_issue(fs, fs, issue.id(), pr.id(), 1706918400L)
  let updated = prs.get_issue(fs, "1")
  guard updated is Some(i) else { panic() }
  assert_eq(i.linked_prs().length(), 1)
  assert_true(i.linked_prs().contains("1"))
}

///|
test "issue: update issue" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let _ = den.create_issue(
    fs, fs, "Original Title", "Original body", "alice@example.com", 1706745600L,
  )
  // Update title and body
  let updated = den.update_issue(
    fs,
    fs,
    "1",
    1706832000L,
    title=Some("Updated Title"),
    body=Some("Updated body"),
  )
  assert_eq(updated.title(), "Updated Title")
  assert_eq(updated.body(), "Updated body")
  // Verify persisted
  let retrieved = den.get_issue(fs, "1")
  guard retrieved is Some(issue) else { panic() }
  assert_eq(issue.title(), "Updated Title")
}

///|
test "issue: update issue labels and assignees" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let _ = den.create_issue(
    fs, fs, "Bug", "Details", "alice@example.com", 1706745600L,
  )
  // Update labels and assignees
  let updated = den.update_issue(
    fs,
    fs,
    "1",
    1706832000L,
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
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  // Get a commit to attach note to
  let commit_id = @lib.resolve_ref(fs, "/repo/.git", "refs/heads/main")
  guard commit_id is Some(cid) else { panic() }
  // Add note
  let note = den.add_note(
    fs, fs, cid, "This commit introduces the initial README.", "alice@example.com",
    1706745600L,
  )
  assert_eq(note.body(), "This commit introduces the initial README.")
  assert_eq(note.author(), "alice@example.com")
  // Get note
  let retrieved = den.get_note(fs, cid)
  assert_true(retrieved is Some(_))
  guard retrieved is Some(n) else { panic() }
  assert_eq(n.body(), "This commit introduces the initial README.")
}

///|
test "notes: list notes" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let main_commit = @lib.resolve_ref(fs, "/repo/.git", "refs/heads/main")
  guard main_commit is Some(main_id) else { panic() }
  let feature_commit = @lib.resolve_ref(fs, "/repo/.git", "refs/heads/feature")
  guard feature_commit is Some(feature_id) else { panic() }
  // Add notes to both commits
  let _ = den.add_note(
    fs, fs, main_id, "Note on main", "alice@example.com", 1706745600L,
  )
  let _ = den.add_note(
    fs, fs, feature_id, "Note on feature", "bob@example.com", 1706832000L,
  )
  let notes = den.list_notes(fs)
  assert_eq(notes.length(), 2)
}

///|
test "notes: remove note" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let commit_id = @lib.resolve_ref(fs, "/repo/.git", "refs/heads/main")
  guard commit_id is Some(cid) else { panic() }
  let _ = den.add_note(
    fs, fs, cid, "Temporary note", "alice@example.com", 1706745600L,
  )
  // Verify note exists
  let before = den.get_note(fs, cid)
  assert_true(before is Some(_))
  // Remove note
  den.remove_note(fs, fs, cid)
  // Verify note is gone
  let after = den.get_note(fs, cid)
  assert_true(after is None)
}

///|
test "notes: custom ns" {
  let fs = setup_repo_with_branch()
  let den = Collab::init(fs, fs, "/repo/.git")
  let commit_id = @lib.resolve_ref(fs, "/repo/.git", "refs/heads/main")
  guard commit_id is Some(cid) else { panic() }
  // Add note to custom ns "tips"
  let _ = den.add_note(
    fs,
    fs,
    cid,
    "Pro tip: use --verbose flag",
    "alice@example.com",
    1706745600L,
    ns="tips",
  )
  // Should not find in default ns
  let default_note = den.get_note(fs, cid)
  assert_true(default_note is None)
  // Should find in tips ns
  let tips_note = den.get_note(fs, cid, ns="tips")
  assert_true(tips_note is Some(_))
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
