///|
/// Create a PR proposal record (notify-only event stream)
pub fn Hub::propose_pr(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  title : String,
  body : String,
  source_branch : String,
  target_branch : String,
  author : String,
  source_repo? : String? = None,
  source_ref? : String? = None,
) -> PullRequest raise @git.GitError {
  let timestamp = clock.now()
  let source_commit = refs.resolve(source_branch) catch {
    _ =>
      raise @git.GitError::InvalidObject(
        "Cannot resolve source branch: \{source_branch}",
      )
  }
  guard source_commit is Some(src_id) else {
    raise @git.GitError::InvalidObject(
      "Source branch not found: \{source_branch}",
    )
  }
  let target_commit = refs.resolve(target_branch) catch {
    _ =>
      raise @git.GitError::InvalidObject(
        "Cannot resolve target branch: \{target_branch}",
      )
  }
  guard target_commit is Some(tgt_id) else {
    raise @git.GitError::InvalidObject(
      "Target branch not found: \{target_branch}",
    )
  }
  let pr_id = generate_entity_id(
    "proposal-pr",
    author,
    timestamp,
    source_branch + "\n" + target_branch + "\n" + title + "\n" + body,
  )
  let pr = PullRequest::new(
    pr_id,
    title,
    body,
    source_branch,
    src_id,
    target_branch,
    tgt_id,
    author,
    timestamp,
    timestamp,
    PrState::Open,
    [],
    source_repo~,
    source_ref~,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      pr_proposal_meta_key(pr_id),
      "pr-proposal",
      pr.serialize(),
      author,
    ),
  )
  pr
}

///|
pub fn Hub::list_pr_proposals(
  self : Hub,
  objects : &@lib.ObjectStore,
) -> Array[PullRequest] {
  let result : Array[PullRequest] = []
  let records = self.store.list_records(objects, pr_proposal_prefix())
  for record in records {
    if not(record.key.has_suffix("/meta")) || record.kind != "pr-proposal" {
      continue
    }
    let pr = parse_pull_request(record.payload) catch { _ => continue }
    result.push(pr)
  }
  result.sort_by(fn(a, b) {
    if a.created_at < b.created_at {
      -1
    } else if a.created_at > b.created_at {
      1
    } else {
      0
    }
  })
  result
}
