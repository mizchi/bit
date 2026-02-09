///|
test "hub parser: parse_pr_state handles known and unknown values" {
  assert_eq(parse_pr_state("open"), Some(@hub.PrState::Open))
  assert_eq(parse_pr_state("closed"), Some(@hub.PrState::Closed))
  assert_eq(parse_pr_state("merged"), Some(@hub.PrState::Merged))
  assert_eq(parse_pr_state("draft"), None)
}

///|
test "hub parser: parse_issue_state handles known and unknown values" {
  assert_eq(parse_issue_state("open"), Some(@hub.IssueState::Open))
  assert_eq(parse_issue_state("closed"), Some(@hub.IssueState::Closed))
  assert_eq(parse_issue_state("draft"), None)
}

///|
test "hub parser: parse_review_verdict handles known and unknown values" {
  assert_eq(
    parse_review_verdict("approved"),
    Some(@hub.ReviewVerdict::Approved),
  )
  assert_eq(parse_review_verdict("comment"), Some(@hub.ReviewVerdict::Comment))
  assert_eq(
    parse_review_verdict("request-changes"),
    Some(@hub.ReviewVerdict::RequestChanges),
  )
  assert_eq(parse_review_verdict("reject"), None)
}

///|
test "hub parser: parse_review_verdict_flag handles gh-style flags" {
  assert_eq(
    parse_review_verdict_flag("--approve"),
    Some(@hub.ReviewVerdict::Approved),
  )
  assert_eq(
    parse_review_verdict_flag("--comment"),
    Some(@hub.ReviewVerdict::Comment),
  )
  assert_eq(
    parse_review_verdict_flag("--request-changes"),
    Some(@hub.ReviewVerdict::RequestChanges),
  )
  assert_eq(parse_review_verdict_flag("--unknown"), None)
}

///|
test "hub parser: parse_merge_strategy handles known and unknown values" {
  match parse_merge_strategy("merge") {
    Some(@hub.PrMergeStrategy::Merge) => ()
    _ => fail("expected merge strategy")
  }
  match parse_merge_strategy("squash") {
    Some(@hub.PrMergeStrategy::Squash) => ()
    _ => fail("expected squash strategy")
  }
  match parse_merge_strategy("ff") {
    Some(@hub.PrMergeStrategy::FastForward) => ()
    _ => fail("expected ff strategy")
  }
  match parse_merge_strategy("rebase") {
    None => ()
    _ => fail("unexpected strategy")
  }
}

///|
test "hub parser: parse_merge_strategy_flag handles gh-style flags" {
  match parse_merge_strategy_flag("--merge") {
    Some(@hub.PrMergeStrategy::Merge) => ()
    _ => fail("expected merge strategy")
  }
  match parse_merge_strategy_flag("--squash") {
    Some(@hub.PrMergeStrategy::Squash) => ()
    _ => fail("expected squash strategy")
  }
  match parse_merge_strategy_flag("--ff") {
    Some(@hub.PrMergeStrategy::FastForward) => ()
    _ => fail("expected ff strategy")
  }
  match parse_merge_strategy_flag("--unknown") {
    None => ()
    _ => fail("unexpected strategy")
  }
}

///|
test "hub parser: normalize pr subcommand handles gh aliases" {
  assert_eq(normalize_hub_pr_subcommand("view"), "get")
  assert_eq(normalize_hub_pr_subcommand("edit"), "update")
  assert_eq(normalize_hub_pr_subcommand("proposal"), "proposals")
  assert_eq(normalize_hub_pr_subcommand("list"), "list")
}

///|
test "hub parser: normalize issue subcommand handles gh aliases" {
  assert_eq(normalize_hub_issue_subcommand("view"), "get")
  assert_eq(normalize_hub_issue_subcommand("edit"), "update")
  assert_eq(normalize_hub_issue_subcommand("list"), "list")
}

///|
test "hub parser: resolve comment subcommand defaults to add" {
  assert_eq(resolve_hub_comment_subcommand("add"), "add")
  assert_eq(resolve_hub_comment_subcommand("list"), "list")
  assert_eq(resolve_hub_comment_subcommand("123"), "add")
}

///|
test "hub parser: resolve review subcommand defaults to submit" {
  assert_eq(resolve_hub_review_subcommand("submit"), "submit")
  assert_eq(resolve_hub_review_subcommand("list"), "list")
  assert_eq(resolve_hub_review_subcommand("123"), "submit")
}

///|
test "hub parser: parse_pr_state_flag handles gh-style flags" {
  assert_eq(parse_pr_state_flag("--open"), Some(@hub.PrState::Open))
  assert_eq(parse_pr_state_flag("--closed"), Some(@hub.PrState::Closed))
  assert_eq(parse_pr_state_flag("--merged"), Some(@hub.PrState::Merged))
  assert_eq(parse_pr_state_flag("--all"), None)
}

///|
test "hub parser: parse_issue_state_flag handles gh-style flags" {
  assert_eq(parse_issue_state_flag("--open"), Some(@hub.IssueState::Open))
  assert_eq(parse_issue_state_flag("--closed"), Some(@hub.IssueState::Closed))
  assert_eq(parse_issue_state_flag("--all"), None)
}

///|
test "hub parser: parse_head_branch_name handles symbolic and detached head" {
  assert_eq(parse_head_branch_name("ref: refs/heads/main\n"), Some("main"))
  assert_eq(
    parse_head_branch_name("ref: refs/heads/feature/topic\n"),
    Some("feature/topic"),
  )
  assert_eq(
    parse_head_branch_name("9fceb02f5f7a6f5a5be74e5f7d2d9d31b2f9f0f5\n"),
    None,
  )
}

///|
test "hub parser: parse_hub_pr_list_options handles gh-style flags and limit" {
  let opts = parse_hub_pr_list_options(["--closed", "--limit", "5"])
  assert_eq(opts.limit, Some(5))
  match opts.state {
    Some(@hub.PrState::Closed) => ()
    _ => fail("expected closed state")
  }
  let opts2 = parse_hub_pr_list_options(["-L", "3", "--open"])
  assert_eq(opts2.limit, Some(3))
  match opts2.state {
    Some(@hub.PrState::Open) => ()
    _ => fail("expected open state")
  }
}

///|
test "hub parser: parse_hub_issue_list_options handles gh-style flags and limit" {
  let opts = parse_hub_issue_list_options(["--closed", "--limit", "7"])
  assert_eq(opts.limit, Some(7))
  match opts.state {
    Some(@hub.IssueState::Closed) => ()
    _ => fail("expected closed state")
  }
  let opts2 = parse_hub_issue_list_options(["-L", "2", "--open"])
  assert_eq(opts2.limit, Some(2))
  match opts2.state {
    Some(@hub.IssueState::Open) => ()
    _ => fail("expected open state")
  }
}

///|
test "hub parser: parse_hub_pr_list_options rejects invalid limit" {
  ignore(
    parse_hub_pr_list_options(["--limit", "0"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Limit must be positive"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub parser: parse_hub_issue_list_options rejects missing limit value" {
  ignore(
    parse_hub_issue_list_options(["-L"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("--limit requires a value"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub dump parser: defaults" {
  let opts = parse_hub_dump_options([])
  assert_eq(opts.prefix, "hub/")
  assert_false(opts.raw)
  assert_false(opts.include_deleted)
}

///|
test "hub dump parser: options and positional prefix" {
  let opts1 = parse_hub_dump_options([
    "--prefix", "hub/pr/", "--raw", "--include-deleted",
  ])
  assert_eq(opts1.prefix, "hub/pr/")
  assert_true(opts1.raw)
  assert_true(opts1.include_deleted)
  let opts2 = parse_hub_dump_options(["hub/issue/"])
  assert_eq(opts2.prefix, "hub/issue/")
  assert_false(opts2.raw)
  assert_false(opts2.include_deleted)
}

///|
test "hub dump parser: --prefix requires value" {
  ignore(
    parse_hub_dump_options(["--prefix"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("--prefix requires a value"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub dump parser: unknown option fails" {
  ignore(
    parse_hub_dump_options(["--unknown"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown hub dump option"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub dump summary: includes key and kind" {
  let record = @hub.HubRecord::new(
    "hub/pr/1/meta", "pr", "payload", "node-a", 10L,
  )
  let out = format_hub_record_summary(record)
  assert_true(out.contains("kind=pr"))
  assert_true(out.contains("key=hub/pr/1/meta"))
}

///|
async test "hub pr list: --state requires a value" {
  handle_hub_pr_list(["--state"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--state requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub issue list: --state requires a value" {
  handle_hub_issue_list(["--state"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--state requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub pr import: --limit requires a value" {
  handle_hub_pr_import(["--limit"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--limit requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub issue import: --limit requires a value" {
  handle_hub_issue_import(["--limit"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--limit requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
test "hub parser: parse_gh_prs rejects missing branch names" {
  let payload =
    #|[{
    #|  "id": "1",
    #|  "title": "demo",
    #|  "body": "",
    #|  "source_commit": "1111111111111111111111111111111111111111",
    #|  "target_commit": "2222222222222222222222222222222222222222"
    #|}]
  ignore(
    parse_gh_prs(payload) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Missing branch name"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub parser: parse_gh_prs captures source repo/ref" {
  let payload =
    #|[{
    #|  "id": "7",
    #|  "title": "fork pr",
    #|  "body": "body",
    #|  "source_branch": "feature",
    #|  "source_ref": "refs/heads/feature",
    #|  "source_repo": "contrib/bit",
    #|  "source_commit": "1111111111111111111111111111111111111111",
    #|  "target_branch": "main",
    #|  "target_commit": "2222222222222222222222222222222222222222",
    #|  "author": "contrib",
    #|  "created_at": 1,
    #|  "updated_at": 2,
    #|  "state": "open",
    #|  "labels": []
    #|}]
  let prs = parse_gh_prs(payload)
  assert_eq(prs.length(), 1)
  let pr = prs[0]
  guard pr.source_repo() is Some(source_repo) else {
    fail("missing source_repo")
  }
  assert_eq(source_repo, "contrib/bit")
  guard pr.source_ref() is Some(source_ref) else { fail("missing source_ref") }
  assert_eq(source_ref, "refs/heads/feature")
}

///|
test "hub parser: parse_gh_issues rejects non-array JSON" {
  ignore(
    parse_gh_issues("{}") catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Expected JSON array"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub notify: select_notify_records filters notify-only records" {
  let canonical = @hub.HubRecord::new(
    "hub/pr/1/meta", "pr", "canonical", "node-a", 1L,
  )
  let proposal = @hub.HubRecord::new(
    "hub/proposal/pr/p1/meta", "pr-proposal", "proposal", "node-b", 2L,
  )
  let selected = select_notify_records([canonical, proposal])
  assert_eq(selected.length(), 1)
  assert_true(selected.contains("hub/proposal/pr/p1/meta"))
}

///|
test "hub notify: collect_changed_notify_records detects new and updated" {
  let before : Map[String, @hub.HubRecord] = {}
  before["hub/proposal/pr/p1/meta"] = @hub.HubRecord::new(
    "hub/proposal/pr/p1/meta", "pr-proposal", "old", "node-a", 1L,
  )
  let after : Map[String, @hub.HubRecord] = {}
  after["hub/proposal/pr/p1/meta"] = @hub.HubRecord::new(
    "hub/proposal/pr/p1/meta", "pr-proposal", "new", "node-a", 2L,
  )
  after["hub/proposal/pr/p2/meta"] = @hub.HubRecord::new(
    "hub/proposal/pr/p2/meta", "pr-proposal", "created", "node-b", 3L,
  )
  let changed = collect_changed_notify_records(before, after)
  assert_eq(changed.length(), 2)
  assert_eq(changed[0].key, "hub/proposal/pr/p1/meta")
  assert_eq(changed[1].key, "hub/proposal/pr/p2/meta")
}

///|
test "hub notify: format_hub_notify_message handles hub.pr.proposal" {
  let proposal = @hub.PullRequest::new(
    "p-1",
    "External Proposal",
    "Body",
    "refs/heads/feature",
    @git.ObjectId::zero(),
    "refs/heads/main",
    @git.ObjectId::zero(),
    "peer-user",
    10L,
    10L,
    @hub.PrState::Open,
    [],
  )
  let record = @hub.HubRecord::new(
    @hub.pr_proposal_meta_key("p-1"),
    "pr-proposal",
    proposal.serialize(),
    "peer-node",
    10L,
  )
  let message = format_hub_notify_message("hub.pr.proposal", record)
  assert_true(message.contains("hub.pr.proposal"))
  assert_true(message.contains("#p-1"))
  assert_true(message.contains("External Proposal"))
  assert_eq(
    format_hub_notify_message("hub.other", record),
    "[hub.notify] hub.other key=hub/proposal/pr/p-1/meta",
  )
}
