///| Tests for collab import helpers

///|
fn read_ref_id(fs : @git.TestFs, path : String) -> @git.ObjectId {
  let hex = fs.read_string(path) catch { _ => panic() }
  let hex = hex.trim().to_string()
  @git.ObjectId::from_hex(hex) catch {
    _ => panic()
  }
}

///|
test "import pr: creates" {
  let fs = setup_repo_with_branch()
  let collab = Collab::init(fs, fs, "/repo/.git")
  let source_id = read_ref_id(fs, "/repo/.git/refs/heads/feature")
  let target_id = read_ref_id(fs, "/repo/.git/refs/heads/main")
  let pr = PullRequest::new(
    "10",
    "Imported PR",
    "Imported body",
    "refs/heads/feature",
    source_id,
    "refs/heads/main",
    target_id,
    "gh-user",
    1700000000L,
    1700000100L,
    PrState::Open,
    ["imported"],
  )
  let stats = collab.import_prs(fs, fs, [pr])
  assert_eq(stats.created(), 1)
  assert_eq(stats.updated(), 0)
  let stored = collab.get_pr(fs, "10")
  guard stored is Some(val) else { panic() }
  assert_eq(val.title(), "Imported PR")
}

///|
test "import pr: updates existing" {
  let fs = setup_repo_with_branch()
  let collab = Collab::init(fs, fs, "/repo/.git")
  let created = collab.create_pr(
    fs, fs, "Original", "Body", "refs/heads/feature", "refs/heads/main", "alice@example.com",
    1706745600L,
  )
  let pr_id = created.id()
  let source_id = read_ref_id(fs, "/repo/.git/refs/heads/feature")
  let target_id = read_ref_id(fs, "/repo/.git/refs/heads/main")
  let pr = PullRequest::new(
    pr_id,
    "Updated Title",
    "Updated Body",
    "refs/heads/feature",
    source_id,
    "refs/heads/main",
    target_id,
    "gh-user",
    1707000000L,
    1707000200L,
    PrState::Closed,
    ["sync"],
  )
  let stats = collab.import_prs(fs, fs, [pr])
  assert_eq(stats.created(), 0)
  assert_eq(stats.updated(), 1)
  let stored = collab.get_pr(fs, pr_id)
  guard stored is Some(val) else { panic() }
  assert_eq(val.title(), "Updated Title")
  assert_eq(val.state(), PrState::Closed)
}

///|
test "import issue: creates" {
  let fs = setup_repo_with_branch()
  let collab = Collab::init(fs, fs, "/repo/.git")
  let issue = Issue::new(
    "7",
    "Imported Issue",
    "Issue body",
    "gh-user",
    1700000000L,
    1700000100L,
    IssueState::Open,
    labels=["bug"],
    assignees=["alice"],
  )
  let stats = collab.import_issues(fs, fs, [issue])
  assert_eq(stats.created(), 1)
  assert_eq(stats.updated(), 0)
  let created = collab.create_issue(
    fs, fs, "Next", "Body", "alice@example.com", 1700000200L,
  )
  assert_true(created.id().length() > 0)
}
