///| Git-native Pull Request and Issue system types

///|
/// State of a Pull Request
pub(all) enum PrState {
  Open
  Merged
  Closed
} derive(Eq)

///|
/// State of an Issue
pub(all) enum IssueState {
  Open
  Closed
} derive(Eq)

///|
pub fn IssueState::to_string(self : IssueState) -> String {
  match self {
    Open => "open"
    Closed => "closed"
  }
}

///|
pub impl Show for IssueState with output(self, logger) {
  logger.write_string(self.to_string())
}

///|
pub fn PrState::to_string(self : PrState) -> String {
  match self {
    Open => "open"
    Merged => "merged"
    Closed => "closed"
  }
}

///|
pub impl Show for PrState with output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// Pull Request data
pub struct PullRequest {
  id : String
  title : String
  body : String
  source_branch : String // refs/heads/feature-x
  source_repo : String? // owner/repo of source branch
  source_ref : String? // refs/heads/feature-x in source repo
  source_commit : @git.ObjectId
  target_branch : String // refs/heads/main
  target_commit : @git.ObjectId
  author : String
  created_at : Int64
  updated_at : Int64
  state : PrState
  labels : Array[String]
  closes_issues : Array[String] // Issues this PR closes
  merge_commit : @git.ObjectId?
}

///|
pub fn PullRequest::new(
  id : String,
  title : String,
  body : String,
  source_branch : String,
  source_commit : @git.ObjectId,
  target_branch : String,
  target_commit : @git.ObjectId,
  author : String,
  created_at : Int64,
  updated_at : Int64,
  state : PrState,
  labels : Array[String],
  closes_issues? : Array[String] = [],
  merge_commit? : @git.ObjectId? = None,
  source_repo? : String? = None,
  source_ref? : String? = None,
) -> PullRequest {
  {
    id,
    title,
    body,
    source_branch,
    source_repo,
    source_ref,
    source_commit,
    target_branch,
    target_commit,
    author,
    created_at,
    updated_at,
    state,
    labels,
    closes_issues,
    merge_commit,
  }
}

///|
pub fn PullRequest::id(self : PullRequest) -> String {
  self.id
}

///|
pub fn PullRequest::title(self : PullRequest) -> String {
  self.title
}

///|
pub fn PullRequest::body(self : PullRequest) -> String {
  self.body
}

///|
pub fn PullRequest::source_branch(self : PullRequest) -> String {
  self.source_branch
}

///|
pub fn PullRequest::source_repo(self : PullRequest) -> String? {
  self.source_repo
}

///|
pub fn PullRequest::source_ref(self : PullRequest) -> String? {
  self.source_ref
}

///|
pub fn PullRequest::source_commit(self : PullRequest) -> @git.ObjectId {
  self.source_commit
}

///|
pub fn PullRequest::target_branch(self : PullRequest) -> String {
  self.target_branch
}

///|
pub fn PullRequest::target_commit(self : PullRequest) -> @git.ObjectId {
  self.target_commit
}

///|
pub fn PullRequest::author(self : PullRequest) -> String {
  self.author
}

///|
pub fn PullRequest::created_at(self : PullRequest) -> Int64 {
  self.created_at
}

///|
pub fn PullRequest::updated_at(self : PullRequest) -> Int64 {
  self.updated_at
}

///|
pub fn PullRequest::state(self : PullRequest) -> PrState {
  self.state
}

///|
pub fn PullRequest::labels(self : PullRequest) -> Array[String] {
  self.labels
}

///|
pub fn PullRequest::closes_issues(self : PullRequest) -> Array[String] {
  self.closes_issues
}

///|
pub fn PullRequest::merge_commit(self : PullRequest) -> @git.ObjectId? {
  self.merge_commit
}

///|
/// Comment on a Pull Request
pub struct PrComment {
  id : String
  pr_id : String
  author : String
  body : String
  created_at : Int64
  reply_to : String? // threading
  file_path : String? // file-level comment
  line_number : Int? // line-level comment
  commit_id : @git.ObjectId?
}

///|
pub fn PrComment::new(
  id : String,
  pr_id : String,
  author : String,
  body : String,
  created_at : Int64,
  reply_to? : String? = None,
  file_path? : String? = None,
  line_number? : Int? = None,
  commit_id? : @git.ObjectId? = None,
) -> PrComment {
  {
    id,
    pr_id,
    author,
    body,
    created_at,
    reply_to,
    file_path,
    line_number,
    commit_id,
  }
}

///|
pub fn PrComment::id(self : PrComment) -> String {
  self.id
}

///|
pub fn PrComment::pr_id(self : PrComment) -> String {
  self.pr_id
}

///|
pub fn PrComment::author(self : PrComment) -> String {
  self.author
}

///|
pub fn PrComment::body(self : PrComment) -> String {
  self.body
}

///|
pub fn PrComment::created_at(self : PrComment) -> Int64 {
  self.created_at
}

///|
pub fn PrComment::reply_to(self : PrComment) -> String? {
  self.reply_to
}

///|
pub fn PrComment::file_path(self : PrComment) -> String? {
  self.file_path
}

///|
pub fn PrComment::line_number(self : PrComment) -> Int? {
  self.line_number
}

///|
pub fn PrComment::commit_id(self : PrComment) -> @git.ObjectId? {
  self.commit_id
}

///|
/// Review verdict
pub(all) enum ReviewVerdict {
  Approved
  RequestChanges
  Comment
} derive(Eq)

///|
pub fn ReviewVerdict::to_string(self : ReviewVerdict) -> String {
  match self {
    Approved => "approved"
    RequestChanges => "request-changes"
    Comment => "comment"
  }
}

///|
pub impl Show for ReviewVerdict with output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// Review on a Pull Request
pub struct PrReview {
  id : String
  pr_id : String
  author : String
  verdict : ReviewVerdict
  body : String
  created_at : Int64
  commit_id : @git.ObjectId
}

///|
pub fn PrReview::new(
  id : String,
  pr_id : String,
  author : String,
  verdict : ReviewVerdict,
  body : String,
  created_at : Int64,
  commit_id : @git.ObjectId,
) -> PrReview {
  { id, pr_id, author, verdict, body, created_at, commit_id }
}

///|
pub fn PrReview::id(self : PrReview) -> String {
  self.id
}

///|
pub fn PrReview::pr_id(self : PrReview) -> String {
  self.pr_id
}

///|
pub fn PrReview::author(self : PrReview) -> String {
  self.author
}

///|
pub fn PrReview::verdict(self : PrReview) -> ReviewVerdict {
  self.verdict
}

///|
pub fn PrReview::body(self : PrReview) -> String {
  self.body
}

///|
pub fn PrReview::created_at(self : PrReview) -> Int64 {
  self.created_at
}

///|
pub fn PrReview::commit_id(self : PrReview) -> @git.ObjectId {
  self.commit_id
}

///|
/// PR operation error
pub(all) suberror PrError {
  NotFound(String)
  InvalidFormat(String)
  InvalidState(String)
  MergeConflict(Array[String])
} derive(Show, Eq)

///|
/// Issue data
pub struct Issue {
  id : String
  title : String
  body : String
  author : String
  created_at : Int64
  updated_at : Int64
  state : IssueState
  labels : Array[String]
  assignees : Array[String]
  linked_prs : Array[String] // Related PRs
}

///|
pub fn Issue::new(
  id : String,
  title : String,
  body : String,
  author : String,
  created_at : Int64,
  updated_at : Int64,
  state : IssueState,
  labels? : Array[String] = [],
  assignees? : Array[String] = [],
  linked_prs? : Array[String] = [],
) -> Issue {
  {
    id,
    title,
    body,
    author,
    created_at,
    updated_at,
    state,
    labels,
    assignees,
    linked_prs,
  }
}

///|
pub fn Issue::id(self : Issue) -> String {
  self.id
}

///|
pub fn Issue::title(self : Issue) -> String {
  self.title
}

///|
pub fn Issue::body(self : Issue) -> String {
  self.body
}

///|
pub fn Issue::author(self : Issue) -> String {
  self.author
}

///|
pub fn Issue::created_at(self : Issue) -> Int64 {
  self.created_at
}

///|
pub fn Issue::updated_at(self : Issue) -> Int64 {
  self.updated_at
}

///|
pub fn Issue::state(self : Issue) -> IssueState {
  self.state
}

///|
pub fn Issue::labels(self : Issue) -> Array[String] {
  self.labels
}

///|
pub fn Issue::assignees(self : Issue) -> Array[String] {
  self.assignees
}

///|
pub fn Issue::linked_prs(self : Issue) -> Array[String] {
  self.linked_prs
}

///|
/// Comment on an Issue
pub struct IssueComment {
  id : String
  issue_id : String
  author : String
  body : String
  created_at : Int64
  reply_to : String? // threading
}

///|
pub fn IssueComment::new(
  id : String,
  issue_id : String,
  author : String,
  body : String,
  created_at : Int64,
  reply_to? : String? = None,
) -> IssueComment {
  { id, issue_id, author, body, created_at, reply_to }
}

///|
pub fn IssueComment::id(self : IssueComment) -> String {
  self.id
}

///|
pub fn IssueComment::issue_id(self : IssueComment) -> String {
  self.issue_id
}

///|
pub fn IssueComment::author(self : IssueComment) -> String {
  self.author
}

///|
pub fn IssueComment::body(self : IssueComment) -> String {
  self.body
}

///|
pub fn IssueComment::created_at(self : IssueComment) -> Int64 {
  self.created_at
}

///|
pub fn IssueComment::reply_to(self : IssueComment) -> String? {
  self.reply_to
}

///|
/// Note attached to a commit (Git notes compatible)
pub struct Note {
  commit_id : @git.ObjectId // The commit this note is attached to
  body : String
  author : String
  created_at : Int64
  ns : String // e.g., "commits", "review", "tips"
}

///|
pub fn Note::new(
  commit_id : @git.ObjectId,
  body : String,
  author : String,
  created_at : Int64,
  ns? : String = "commits",
) -> Note {
  { commit_id, body, author, created_at, ns }
}

///|
pub fn Note::commit_id(self : Note) -> @git.ObjectId {
  self.commit_id
}

///|
pub fn Note::body(self : Note) -> String {
  self.body
}

///|
pub fn Note::author(self : Note) -> String {
  self.author
}

///|
pub fn Note::created_at(self : Note) -> Int64 {
  self.created_at
}

///|
pub fn Note::ns(self : Note) -> String {
  self.ns
}
