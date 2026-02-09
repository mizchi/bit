///| Tests for hub import helpers

///|
test "import pr: creates" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let source_id = refs.resolve("refs/heads/feature")
  guard source_id is Some(sid) else { panic() }
  let target_id = refs.resolve("refs/heads/main")
  guard target_id is Some(tid) else { panic() }
  let pr = PullRequest::new(
    "10",
    "Imported PR",
    "Imported body",
    "refs/heads/feature",
    sid,
    "refs/heads/main",
    tid,
    "gh-user",
    1700000000L,
    1700000100L,
    PrState::Open,
    ["imported"],
  )
  let stats = hub.import_prs(objects, refs, clock, [pr])
  assert_eq(stats.created(), 1)
  assert_eq(stats.updated(), 0)
  let stored = hub.get_pr(objects, "10")
  guard stored is Some(val) else { panic() }
  assert_eq(val.title(), "Imported PR")
}

///|
test "import pr: updates existing" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let created = hub.create_pr(
    objects, refs, clock, "Original", "Body", "refs/heads/feature", "refs/heads/main",
    "alice@example.com",
  )
  let pr_id = created.id()
  let source_id = refs.resolve("refs/heads/feature")
  guard source_id is Some(sid) else { panic() }
  let target_id = refs.resolve("refs/heads/main")
  guard target_id is Some(tid) else { panic() }
  let pr = PullRequest::new(
    pr_id,
    "Updated Title",
    "Updated Body",
    "refs/heads/feature",
    sid,
    "refs/heads/main",
    tid,
    "gh-user",
    1707000000L,
    1707000200L,
    PrState::Closed,
    ["sync"],
  )
  let stats = hub.import_prs(objects, refs, clock, [pr])
  assert_eq(stats.created(), 0)
  assert_eq(stats.updated(), 1)
  let stored = hub.get_pr(objects, pr_id)
  guard stored is Some(val) else { panic() }
  assert_eq(val.title(), "Updated Title")
  assert_eq(val.state(), PrState::Closed)
}

///|
test "import pr proposal: stores notify-only proposal records" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
  let source_id = refs.resolve("refs/heads/feature")
  guard source_id is Some(sid) else { panic() }
  let target_id = refs.resolve("refs/heads/main")
  guard target_id is Some(tid) else { panic() }
  let proposal = PullRequest::new(
    "p1",
    "External Proposal",
    "Notify only",
    "refs/heads/feature",
    sid,
    "refs/heads/main",
    tid,
    "peer-user",
    1700000200L,
    1700000300L,
    PrState::Open,
    [],
  )
  let stats = hub.import_pr_proposals(objects, refs, clock, [proposal])
  assert_eq(stats.created(), 1)
  assert_eq(stats.updated(), 0)
  assert_eq(hub.list_prs(objects).length(), 0)
  let proposals = hub.list_pr_proposals(objects)
  assert_eq(proposals.length(), 1)
  assert_eq(proposals[0].id(), "p1")
  let key = pr_proposal_meta_key("p1")
  let record = hub.store.get_record(objects, key)
  guard record is Some(r) else { panic() }
  assert_eq(classify_record_trigger(r), RecordTriggerClass::NotifyOnly)
  assert_eq(record_notify_topic(r), Some("hub.pr.proposal"))
}

///|
test "import pr proposal: strict reader hides unsigned imported records" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let writer = Hub::init(objects, refs)
  let reader = Hub::init(
    objects,
    refs,
    signing_key=Some("k1"),
    require_signed=true,
  )
  let source_id = refs.resolve("refs/heads/feature")
  guard source_id is Some(sid) else { panic() }
  let target_id = refs.resolve("refs/heads/main")
  guard target_id is Some(tid) else { panic() }
  let proposal = PullRequest::new(
    "p-unsigned",
    "External Proposal",
    "Notify only",
    "refs/heads/feature",
    sid,
    "refs/heads/main",
    tid,
    "peer-user",
    1701000200L,
    1701000300L,
    PrState::Open,
    [],
  )
  let stats = writer.import_pr_proposals(objects, refs, clock, [proposal])
  assert_eq(stats.created(), 1)
  reader.reload_store(objects, refs)
  assert_eq(reader.list_pr_proposals(objects).length(), 0)
}

///|
test "import pr proposal: wrong key hides signed imported records" {
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
  let source_id = refs.resolve("refs/heads/feature")
  guard source_id is Some(sid) else { panic() }
  let target_id = refs.resolve("refs/heads/main")
  guard target_id is Some(tid) else { panic() }
  let proposal = PullRequest::new(
    "p-signed",
    "Signed Proposal",
    "Notify only",
    "refs/heads/feature",
    sid,
    "refs/heads/main",
    tid,
    "peer-user",
    1702000200L,
    1702000300L,
    PrState::Open,
    [],
  )
  let stats = writer.import_pr_proposals(objects, refs, clock, [proposal])
  assert_eq(stats.created(), 1)
  reader.reload_store(objects, refs)
  assert_eq(reader.list_pr_proposals(objects).length(), 0)
}

///|
test "import pr proposal: require_signed without key rejects writes" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let strict = Hub::init(objects, refs, require_signed=true)
  let source_id = refs.resolve("refs/heads/feature")
  guard source_id is Some(sid) else { panic() }
  let target_id = refs.resolve("refs/heads/main")
  guard target_id is Some(tid) else { panic() }
  let proposal = PullRequest::new(
    "p-reject",
    "Signed Proposal",
    "Notify only",
    "refs/heads/feature",
    sid,
    "refs/heads/main",
    tid,
    "peer-user",
    1703000200L,
    1703000300L,
    PrState::Open,
    [],
  )
  ignore(
    strict.import_pr_proposals(objects, refs, clock, [proposal]) catch {
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
test "import issue: creates" {
  let (_fs, objects, refs, clock) = setup_repo_with_branch()
  let hub = Hub::init(objects, refs)
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
  let stats = hub.import_issues(objects, refs, clock, [issue])
  assert_eq(stats.created(), 1)
  assert_eq(stats.updated(), 0)
  let created = hub.create_issue(
    objects, refs, clock, "Next", "Body", "alice@example.com",
  )
  assert_true(created.id().length() > 0)
}
