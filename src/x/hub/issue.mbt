///| Issue operations

///|
/// Create a new Issue
pub fn Hub::create_issue(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  title : String,
  body : String,
  author : String,
  labels? : Array[String] = [],
  assignees? : Array[String] = [],
) -> Issue raise @git.GitError {
  let timestamp = clock.now()
  let issue_id = generate_entity_id(
    "issue",
    author,
    timestamp,
    title + "\n" + body,
  )
  let issue = Issue::new(
    issue_id,
    title,
    body,
    author,
    timestamp,
    timestamp,
    IssueState::Open,
    labels~,
    assignees~,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      issue_meta_key(issue_id),
      "issue",
      issue.serialize(),
      author,
    ),
  )
  issue
}

///|
/// Get an Issue by ID
pub fn Hub::get_issue(
  self : Hub,
  objects : &@lib.ObjectStore,
  issue_id : String,
) -> Issue? {
  let record = self.store.get_record(objects, issue_meta_key(issue_id))
  match record {
    None => None
    Some(r) => {
      let result : Result[Issue, PrError] = try? parse_issue(r.payload)
      match result {
        Ok(issue) => Some(issue)
        Err(_) => None
      }
    }
  }
}

///|
/// List Issues, optionally filtered by state
pub fn Hub::list_issues(
  self : Hub,
  objects : &@lib.ObjectStore,
  state? : IssueState? = None,
) -> Array[Issue] {
  let result : Array[Issue] = []
  let records = self.store.list_records(objects, "hub/issue/")
  for record in records {
    if not(record.key.has_suffix("/meta")) || record.kind != "issue" {
      continue
    }
    let issue = parse_issue(record.payload) catch { _ => continue }
    match state {
      None => result.push(issue)
      Some(s) => if issue.state == s { result.push(issue) }
    }
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

///|
/// Update an Issue (title, body, labels, assignees)
pub fn Hub::update_issue(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  issue_id : String,
  title? : String? = None,
  body? : String? = None,
  labels? : Array[String]? = None,
  assignees? : Array[String]? = None,
) -> Issue raise @git.GitError {
  let issue = self.get_issue(objects, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  let new_title = match title {
    Some(t) => t
    None => existing.title
  }
  let new_body = match body {
    Some(b) => b
    None => existing.body
  }
  let new_labels = match labels {
    Some(l) => l
    None => existing.labels
  }
  let new_assignees = match assignees {
    Some(a) => a
    None => existing.assignees
  }
  let updated = Issue::new(
    existing.id,
    new_title,
    new_body,
    existing.author,
    existing.created_at,
    clock.now(),
    existing.state,
    labels=new_labels,
    assignees=new_assignees,
    linked_prs=existing.linked_prs,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      issue_meta_key(issue_id),
      "issue",
      updated.serialize(),
      existing.author,
    ),
  )
  updated
}

///|
/// Close an Issue
pub fn Hub::close_issue(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  issue_id : String,
) -> Unit raise @git.GitError {
  let issue = self.get_issue(objects, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  if existing.state != IssueState::Open {
    raise @git.GitError::InvalidObject("Issue is not open: \{issue_id}")
  }
  let updated = Issue::new(
    existing.id,
    existing.title,
    existing.body,
    existing.author,
    existing.created_at,
    clock.now(),
    IssueState::Closed,
    labels=existing.labels,
    assignees=existing.assignees,
    linked_prs=existing.linked_prs,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      issue_meta_key(issue_id),
      "issue",
      updated.serialize(),
      existing.author,
    ),
  )
}

///|
/// Reopen a closed Issue
pub fn Hub::reopen_issue(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  issue_id : String,
) -> Unit raise @git.GitError {
  let issue = self.get_issue(objects, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  if existing.state != IssueState::Closed {
    raise @git.GitError::InvalidObject("Issue is not closed: \{issue_id}")
  }
  let updated = Issue::new(
    existing.id,
    existing.title,
    existing.body,
    existing.author,
    existing.created_at,
    clock.now(),
    IssueState::Open,
    labels=existing.labels,
    assignees=existing.assignees,
    linked_prs=existing.linked_prs,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      issue_meta_key(issue_id),
      "issue",
      updated.serialize(),
      existing.author,
    ),
  )
}

///|
/// Add a comment to an Issue
pub fn Hub::add_issue_comment(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  issue_id : String,
  author : String,
  body : String,
  reply_to? : String? = None,
) -> IssueComment raise @git.GitError {
  let issue = self.get_issue(objects, issue_id)
  guard issue is Some(_) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  let timestamp = clock.now()
  let comment = IssueComment::new(
    "",
    issue_id,
    author,
    body,
    timestamp,
    reply_to~,
  )
  let comment_data = comment.serialize()
  let (blob_id, _compressed) = @git.create_blob_string(comment_data)
  let comment_id = short_hex(blob_id.to_hex(), 8)
  let final_comment = IssueComment::new(
    comment_id,
    issue_id,
    author,
    body,
    timestamp,
    reply_to~,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      issue_comment_key(issue_id, comment_id),
      "issue.comment",
      final_comment.serialize(),
      author,
    ),
  )
  final_comment
}

///|
/// List comments for an Issue
pub fn Hub::list_issue_comments(
  self : Hub,
  objects : &@lib.ObjectStore,
  issue_id : String,
) -> Array[IssueComment] {
  let result : Array[IssueComment] = []
  let records = self.store.list_records(objects, issue_comment_prefix(issue_id))
  for record in records {
    if record.kind != "issue.comment" {
      continue
    }
    let comment = parse_issue_comment(record.payload) catch { _ => continue }
    result.push(comment)
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

///|
/// Link a PR to an Issue
pub fn Hub::link_pr_to_issue(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  issue_id : String,
  pr_id : String,
) -> Unit raise @git.GitError {
  let issue = self.get_issue(objects, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  let linked = existing.linked_prs
  if not(linked.contains(pr_id)) {
    linked.push(pr_id)
  }
  let updated = Issue::new(
    existing.id,
    existing.title,
    existing.body,
    existing.author,
    existing.created_at,
    clock.now(),
    existing.state,
    labels=existing.labels,
    assignees=existing.assignees,
    linked_prs=linked,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      issue_meta_key(issue_id),
      "issue",
      updated.serialize(),
      existing.author,
    ),
  )
}

///|
