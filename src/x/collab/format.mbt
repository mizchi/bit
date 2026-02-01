///| Git-style text format serialization for PR data

///|
/// Serialize PullRequest to Git-style text format
pub fn PullRequest::serialize(self : PullRequest) -> String {
  let sb = StringBuilder::new()
  sb.write_string("pr ")
  sb.write_string(self.id)
  sb.write_char('\n')
  sb.write_string("title ")
  sb.write_string(self.title)
  sb.write_char('\n')
  sb.write_string("source ")
  sb.write_string(self.source_branch)
  sb.write_char('\n')
  sb.write_string("source-commit ")
  sb.write_string(self.source_commit.to_hex())
  sb.write_char('\n')
  sb.write_string("target ")
  sb.write_string(self.target_branch)
  sb.write_char('\n')
  sb.write_string("target-commit ")
  sb.write_string(self.target_commit.to_hex())
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(self.author)
  sb.write_char('\n')
  sb.write_string("created ")
  sb.write_string(self.created_at.to_string())
  sb.write_char('\n')
  sb.write_string("updated ")
  sb.write_string(self.updated_at.to_string())
  sb.write_char('\n')
  sb.write_string("state ")
  sb.write_string(self.state.to_string())
  sb.write_char('\n')
  for label in self.labels {
    sb.write_string("label ")
    sb.write_string(label)
    sb.write_char('\n')
  }
  for issue_id in self.closes_issues {
    sb.write_string("closes ")
    sb.write_string(issue_id)
    sb.write_char('\n')
  }
  sb.write_char('\n')
  sb.write_string(self.body)
  sb.to_string()
}

///|
/// Parse PullRequest from Git-style text format
pub fn parse_pull_request(text : String) -> PullRequest raise PrError {
  let mut id = ""
  let mut title = ""
  let mut source_branch = ""
  let mut source_commit_hex = ""
  let mut target_branch = ""
  let mut target_commit_hex = ""
  let mut author = ""
  let mut created_at : Int64 = 0
  let mut updated_at : Int64 = 0
  let mut state = PrState::Open
  let labels : Array[String] = []
  let closes_issues : Array[String] = []
  let body_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      body_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match key {
          "pr" => id = value
          "title" => title = value
          "source" => source_branch = value
          "source-commit" => source_commit_hex = value
          "target" => target_branch = value
          "target-commit" => target_commit_hex = value
          "author" => author = value
          "created" => created_at = parse_int64(value)
          "updated" => updated_at = parse_int64(value)
          "state" => state = parse_pr_state(value)
          "label" => labels.push(value)
          "closes" => closes_issues.push(value)
          _ => ()
        }
      }
    }
  }
  if id.length() == 0 {
    raise PrError::InvalidFormat("Missing pr id")
  }
  let source_commit = @git.ObjectId::from_hex(source_commit_hex) catch {
    _ => raise PrError::InvalidFormat("Invalid source-commit hex")
  }
  let target_commit = @git.ObjectId::from_hex(target_commit_hex) catch {
    _ => raise PrError::InvalidFormat("Invalid target-commit hex")
  }
  PullRequest::new(
    id,
    title,
    body_lines.join("\n"),
    source_branch,
    source_commit,
    target_branch,
    target_commit,
    author,
    created_at,
    updated_at,
    state,
    labels,
    closes_issues~,
  )
}

///|
/// Serialize PrComment to Git-style text format
pub fn PrComment::serialize(self : PrComment) -> String {
  let sb = StringBuilder::new()
  sb.write_string("comment ")
  sb.write_string(self.id)
  sb.write_char('\n')
  sb.write_string("pr ")
  sb.write_string(self.pr_id)
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(self.author)
  sb.write_char('\n')
  sb.write_string("created ")
  sb.write_string(self.created_at.to_string())
  sb.write_char('\n')
  match self.reply_to {
    Some(r) => {
      sb.write_string("reply-to ")
      sb.write_string(r)
      sb.write_char('\n')
    }
    None => ()
  }
  match self.file_path {
    Some(p) => {
      sb.write_string("file ")
      sb.write_string(p)
      sb.write_char('\n')
    }
    None => ()
  }
  match self.line_number {
    Some(n) => {
      sb.write_string("line ")
      sb.write_string(n.to_string())
      sb.write_char('\n')
    }
    None => ()
  }
  match self.commit_id {
    Some(c) => {
      sb.write_string("commit ")
      sb.write_string(c.to_hex())
      sb.write_char('\n')
    }
    None => ()
  }
  sb.write_char('\n')
  sb.write_string(self.body)
  sb.to_string()
}

///|
/// Parse PrComment from Git-style text format
pub fn parse_pr_comment(text : String) -> PrComment raise PrError {
  let mut id = ""
  let mut pr_id = ""
  let mut author = ""
  let mut created_at : Int64 = 0
  let mut reply_to : String? = None
  let mut file_path : String? = None
  let mut line_number : Int? = None
  let mut commit_id : @git.ObjectId? = None
  let body_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      body_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match key {
          "comment" => id = value
          "pr" => pr_id = value
          "author" => author = value
          "created" => created_at = parse_int64(value)
          "reply-to" => reply_to = Some(value)
          "file" => file_path = Some(value)
          "line" => line_number = Some(parse_int(value))
          "commit" =>
            commit_id = Some(
              @git.ObjectId::from_hex(value) catch {
                _ => raise PrError::InvalidFormat("Invalid commit hex")
              },
            )
          _ => ()
        }
      }
    }
  }
  if id.length() == 0 {
    raise PrError::InvalidFormat("Missing comment id")
  }
  PrComment::new(
    id,
    pr_id,
    author,
    body_lines.join("\n"),
    created_at,
    reply_to~,
    file_path~,
    line_number~,
    commit_id~,
  )
}

///|
/// Serialize PrReview to Git-style text format
pub fn PrReview::serialize(self : PrReview) -> String {
  let sb = StringBuilder::new()
  sb.write_string("review ")
  sb.write_string(self.id)
  sb.write_char('\n')
  sb.write_string("pr ")
  sb.write_string(self.pr_id)
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(self.author)
  sb.write_char('\n')
  sb.write_string("verdict ")
  sb.write_string(self.verdict.to_string())
  sb.write_char('\n')
  sb.write_string("created ")
  sb.write_string(self.created_at.to_string())
  sb.write_char('\n')
  sb.write_string("commit ")
  sb.write_string(self.commit_id.to_hex())
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(self.body)
  sb.to_string()
}

///|
/// Parse PrReview from Git-style text format
pub fn parse_pr_review(text : String) -> PrReview raise PrError {
  let mut id = ""
  let mut pr_id = ""
  let mut author = ""
  let mut verdict = ReviewVerdict::Comment
  let mut created_at : Int64 = 0
  let mut commit_hex = ""
  let body_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      body_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match key {
          "review" => id = value
          "pr" => pr_id = value
          "author" => author = value
          "verdict" => verdict = parse_review_verdict(value)
          "created" => created_at = parse_int64(value)
          "commit" => commit_hex = value
          _ => ()
        }
      }
    }
  }
  if id.length() == 0 {
    raise PrError::InvalidFormat("Missing review id")
  }
  let commit_id = @git.ObjectId::from_hex(commit_hex) catch {
    _ => raise PrError::InvalidFormat("Invalid commit hex")
  }
  PrReview::new(
    id,
    pr_id,
    author,
    verdict,
    body_lines.join("\n"),
    created_at,
    commit_id,
  )
}

///|
fn parse_int64(s : String) -> Int64 {
  let mut result : Int64 = 0
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int()).to_int64()
    }
  }
  result
}

///|
fn parse_int(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
    }
  }
  result
}

///|
fn parse_pr_state(s : String) -> PrState {
  match s {
    "open" => PrState::Open
    "merged" => PrState::Merged
    "closed" => PrState::Closed
    _ => PrState::Open
  }
}

///|
fn parse_review_verdict(s : String) -> ReviewVerdict {
  match s {
    "approved" => ReviewVerdict::Approved
    "request-changes" => ReviewVerdict::RequestChanges
    "comment" => ReviewVerdict::Comment
    _ => ReviewVerdict::Comment
  }
}

///|
/// Serialize Issue to Git-style text format
pub fn Issue::serialize(self : Issue) -> String {
  let sb = StringBuilder::new()
  sb.write_string("issue ")
  sb.write_string(self.id)
  sb.write_char('\n')
  sb.write_string("title ")
  sb.write_string(self.title)
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(self.author)
  sb.write_char('\n')
  sb.write_string("created ")
  sb.write_string(self.created_at.to_string())
  sb.write_char('\n')
  sb.write_string("updated ")
  sb.write_string(self.updated_at.to_string())
  sb.write_char('\n')
  sb.write_string("state ")
  sb.write_string(self.state.to_string())
  sb.write_char('\n')
  for label in self.labels {
    sb.write_string("label ")
    sb.write_string(label)
    sb.write_char('\n')
  }
  for assignee in self.assignees {
    sb.write_string("assignee ")
    sb.write_string(assignee)
    sb.write_char('\n')
  }
  for pr_id in self.linked_prs {
    sb.write_string("linked-pr ")
    sb.write_string(pr_id)
    sb.write_char('\n')
  }
  sb.write_char('\n')
  sb.write_string(self.body)
  sb.to_string()
}

///|
/// Parse Issue from Git-style text format
pub fn parse_issue(text : String) -> Issue raise PrError {
  let mut id = ""
  let mut title = ""
  let mut author = ""
  let mut created_at : Int64 = 0
  let mut updated_at : Int64 = 0
  let mut state = IssueState::Open
  let labels : Array[String] = []
  let assignees : Array[String] = []
  let linked_prs : Array[String] = []
  let body_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      body_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match key {
          "issue" => id = value
          "title" => title = value
          "author" => author = value
          "created" => created_at = parse_int64(value)
          "updated" => updated_at = parse_int64(value)
          "state" => state = parse_issue_state(value)
          "label" => labels.push(value)
          "assignee" => assignees.push(value)
          "linked-pr" => linked_prs.push(value)
          _ => ()
        }
      }
    }
  }
  if id.length() == 0 {
    raise PrError::InvalidFormat("Missing issue id")
  }
  Issue::new(
    id,
    title,
    body_lines.join("\n"),
    author,
    created_at,
    updated_at,
    state,
    labels~,
    assignees~,
    linked_prs~,
  )
}

///|
/// Serialize IssueComment to Git-style text format
pub fn IssueComment::serialize(self : IssueComment) -> String {
  let sb = StringBuilder::new()
  sb.write_string("comment ")
  sb.write_string(self.id)
  sb.write_char('\n')
  sb.write_string("issue ")
  sb.write_string(self.issue_id)
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(self.author)
  sb.write_char('\n')
  sb.write_string("created ")
  sb.write_string(self.created_at.to_string())
  sb.write_char('\n')
  match self.reply_to {
    Some(r) => {
      sb.write_string("reply-to ")
      sb.write_string(r)
      sb.write_char('\n')
    }
    None => ()
  }
  sb.write_char('\n')
  sb.write_string(self.body)
  sb.to_string()
}

///|
/// Parse IssueComment from Git-style text format
pub fn parse_issue_comment(text : String) -> IssueComment raise PrError {
  let mut id = ""
  let mut issue_id = ""
  let mut author = ""
  let mut created_at : Int64 = 0
  let mut reply_to : String? = None
  let body_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      body_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match key {
          "comment" => id = value
          "issue" => issue_id = value
          "author" => author = value
          "created" => created_at = parse_int64(value)
          "reply-to" => reply_to = Some(value)
          _ => ()
        }
      }
    }
  }
  if id.length() == 0 {
    raise PrError::InvalidFormat("Missing comment id")
  }
  IssueComment::new(
    id,
    issue_id,
    author,
    body_lines.join("\n"),
    created_at,
    reply_to~,
  )
}

///|
fn parse_issue_state(s : String) -> IssueState {
  match s {
    "open" => IssueState::Open
    "closed" => IssueState::Closed
    _ => IssueState::Open
  }
}

///|
/// Serialize Note to Git-style text format
/// Note: Git standard notes are plain text, but we add metadata for Collab
pub fn Note::serialize(self : Note) -> String {
  let sb = StringBuilder::new()
  sb.write_string("commit ")
  sb.write_string(self.commit_id.to_hex())
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(self.author)
  sb.write_char('\n')
  sb.write_string("created ")
  sb.write_string(self.created_at.to_string())
  sb.write_char('\n')
  sb.write_string("ns ")
  sb.write_string(self.ns)
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(self.body)
  sb.to_string()
}

///|
/// Serialize Note as plain text (Git compatible, no metadata)
pub fn Note::serialize_plain(self : Note) -> String {
  self.body
}

///|
/// Parse Note from Git-style text format (with metadata)
pub fn parse_note(text : String) -> Note {
  let mut commit_id = @git.ObjectId::zero()
  let mut author = ""
  let mut created_at : Int64 = 0
  let mut ns = "commits"
  let body_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      body_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match key {
          "commit" =>
            commit_id = @git.ObjectId::from_hex(value) catch {
              _ => @git.ObjectId::zero()
            }
          "author" => author = value
          "created" => created_at = parse_int64(value)
          "ns" => ns = value
          _ => ()
        }
      }
    }
  }
  Note::new(commit_id, body_lines.join("\n"), author, created_at, ns~)
}

///|
/// Parse Note from plain text (Git compatible, creates minimal Note)
pub fn parse_note_plain(commit_id : @git.ObjectId, text : String) -> Note {
  Note::new(commit_id, text, "", 0L, ns="commits")
}
