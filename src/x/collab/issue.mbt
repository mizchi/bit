///| Issue operations

///|
/// Create a new Issue
pub fn Collab::create_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  title : String,
  body : String,
  author : String,
  timestamp : Int64,
  labels? : Array[String] = [],
  assignees? : Array[String] = [],
) -> Issue raise @git.GitError {
  // Load issue counter
  let issue_id = load_issue_counter(backing_fs, self.git_dir).to_string()
  let next_issue_id = load_issue_counter(backing_fs, self.git_dir) + 1
  // Create Issue object
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
  // Serialize and store
  let issue_data = issue.serialize()
  let (issue_blob_id, issue_compressed) = @git.create_blob_string(issue_data)
  write_object_bytes(fs, self.git_dir, issue_blob_id, issue_compressed)
  // Update _den tree structure with new issue
  update_issues_tree(
    fs,
    backing_fs,
    self.git_dir,
    issue_id,
    issue_blob_id,
    next_issue_id,
  )
  issue
}

///|
/// Get an Issue by ID
pub fn Collab::get_issue(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
) -> Issue? raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let den_commit = get_den_commit(backing_fs, self.git_dir)
  guard den_commit is Some(commit_id) else { return None }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return None }
  // Navigate to issues/<id>/issue.data
  let issues_tree_id = find_tree_entry(db, backing_fs, tree_id, "issues")
  guard issues_tree_id is Some(issues_dir_id) else { return None }
  let issue_dir_id = find_tree_entry(db, backing_fs, issues_dir_id, issue_id)
  guard issue_dir_id is Some(issue_dir) else { return None }
  let issue_data_id = find_tree_entry(db, backing_fs, issue_dir, "issue.data")
  guard issue_data_id is Some(data_id) else { return None }
  // Read and parse
  let obj = db.get(backing_fs, data_id)
  guard obj is Some(data_obj) else { return None }
  let text = @utf8.decode_lossy(data_obj.data[:])
  Some(parse_issue(text) catch { _ => return None })
}

///|
/// List Issues, optionally filtered by state
pub fn Collab::list_issues(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  state? : IssueState? = None,
) -> Array[Issue] raise @git.GitError {
  let result : Array[Issue] = []
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let den_commit = get_den_commit(backing_fs, self.git_dir)
  guard den_commit is Some(commit_id) else { return result }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return result }
  let issues_tree_id = find_tree_entry(db, backing_fs, tree_id, "issues")
  guard issues_tree_id is Some(issues_dir_id) else { return result }
  // List all issue directories
  let issues_obj = db.get(backing_fs, issues_dir_id)
  guard issues_obj is Some(issues_tree_obj) else { return result }
  let entries = @git.parse_tree(issues_tree_obj.data)
  for entry in entries {
    let issue_data_id = find_tree_entry(db, backing_fs, entry.id, "issue.data")
    guard issue_data_id is Some(data_id) else { continue }
    let obj = db.get(backing_fs, data_id)
    guard obj is Some(data_obj) else { continue }
    let text = @utf8.decode_lossy(data_obj.data[:])
    let issue = parse_issue(text) catch { _ => continue }
    match state {
      None => result.push(issue)
      Some(s) => if issue.state == s { result.push(issue) }
    }
  }
  result.sort_by(fn(a, b) { parse_int(a.id) - parse_int(b.id) })
  result
}

///|
/// Update an Issue (title, body, labels, assignees)
pub fn Collab::update_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  timestamp : Int64,
  title? : String? = None,
  body? : String? = None,
  labels? : Array[String]? = None,
  assignees? : Array[String]? = None,
) -> Issue raise @git.GitError {
  let issue = self.get_issue(backing_fs, issue_id)
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
    timestamp,
    existing.state,
    labels=new_labels,
    assignees=new_assignees,
    linked_prs=existing.linked_prs,
  )
  let issue_data = updated.serialize()
  let (issue_blob_id, issue_compressed) = @git.create_blob_string(issue_data)
  write_object_bytes(fs, self.git_dir, issue_blob_id, issue_compressed)
  update_issue_data(fs, backing_fs, self.git_dir, issue_id, issue_blob_id)
  updated
}

///|
/// Close an Issue
pub fn Collab::close_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  let issue = self.get_issue(backing_fs, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  if existing.state != IssueState::Open {
    raise @git.GitError::InvalidObject("Issue is not open: \{issue_id}")
  }
  // Create updated Issue with Closed state
  let updated = Issue::new(
    existing.id,
    existing.title,
    existing.body,
    existing.author,
    existing.created_at,
    timestamp,
    IssueState::Closed,
    labels=existing.labels,
    assignees=existing.assignees,
    linked_prs=existing.linked_prs,
  )
  // Store updated Issue
  let issue_data = updated.serialize()
  let (issue_blob_id, issue_compressed) = @git.create_blob_string(issue_data)
  write_object_bytes(fs, self.git_dir, issue_blob_id, issue_compressed)
  // Update tree
  update_issue_data(fs, backing_fs, self.git_dir, issue_id, issue_blob_id)
}

///|
/// Add a comment to an Issue
pub fn Collab::add_issue_comment(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  author : String,
  body : String,
  timestamp : Int64,
  reply_to? : String? = None,
) -> IssueComment raise @git.GitError {
  // Verify Issue exists
  let issue = self.get_issue(backing_fs, issue_id)
  guard issue is Some(_) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  // Generate comment ID from content hash
  let comment = IssueComment::new(
    "",
    issue_id,
    author,
    body,
    timestamp,
    reply_to~,
  )
  let comment_data = comment.serialize()
  let (blob_id, compressed) = @git.create_blob_string(comment_data)
  let comment_id = short_hex(blob_id.to_hex(), 8)
  // Create final comment with ID
  let final_comment = IssueComment::new(
    comment_id,
    issue_id,
    author,
    body,
    timestamp,
    reply_to~,
  )
  let final_data = final_comment.serialize()
  let (final_blob_id, final_compressed) = @git.create_blob_string(final_data)
  write_object_bytes(fs, self.git_dir, final_blob_id, final_compressed)
  // Update _den tree with new comment
  add_issue_comment_to_tree(
    fs,
    backing_fs,
    self.git_dir,
    issue_id,
    comment_id,
    final_blob_id,
  )
  ignore(compressed)
  final_comment
}

///|
/// List comments for an Issue
pub fn Collab::list_issue_comments(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
) -> Array[IssueComment] raise @git.GitError {
  let result : Array[IssueComment] = []
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let den_commit = get_den_commit(backing_fs, self.git_dir)
  guard den_commit is Some(commit_id) else { return result }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return result }
  // Navigate to issues/<id>/comments
  let issues_dir_id = find_tree_entry(db, backing_fs, tree_id, "issues")
  guard issues_dir_id is Some(iid) else { return result }
  let issue_dir_id = find_tree_entry(db, backing_fs, iid, issue_id)
  guard issue_dir_id is Some(isid) else { return result }
  let comments_id = find_tree_entry(db, backing_fs, isid, "comments")
  guard comments_id is Some(cid) else { return result }
  // List all comment blobs
  let comments_obj = db.get(backing_fs, cid)
  guard comments_obj is Some(tree_obj) else { return result }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    let obj = db.get(backing_fs, entry.id)
    guard obj is Some(data_obj) else { continue }
    let text = @utf8.decode_lossy(data_obj.data[:])
    let comment = parse_issue_comment(text) catch { _ => continue }
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
pub fn Collab::link_pr_to_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  pr_id : String,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  let issue = self.get_issue(backing_fs, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  // Add PR to linked_prs if not already present
  let linked = existing.linked_prs
  if not(linked.contains(pr_id)) {
    linked.push(pr_id)
  }
  // Create updated Issue
  let updated = Issue::new(
    existing.id,
    existing.title,
    existing.body,
    existing.author,
    existing.created_at,
    timestamp,
    existing.state,
    labels=existing.labels,
    assignees=existing.assignees,
    linked_prs=linked,
  )
  // Store updated Issue
  let issue_data = updated.serialize()
  let (issue_blob_id, issue_compressed) = @git.create_blob_string(issue_data)
  write_object_bytes(fs, self.git_dir, issue_blob_id, issue_compressed)
  update_issue_data(fs, backing_fs, self.git_dir, issue_id, issue_blob_id)
}

///|
fn load_issue_counter(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Int raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let den_commit = get_den_commit(backing_fs, git_dir)
  guard den_commit is Some(commit_id) else { return 1 }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return 1 }
  let meta_id = find_tree_entry(db, backing_fs, tree_id, "meta")
  guard meta_id is Some(mid) else { return 1 }
  let counter_id = find_tree_entry(db, backing_fs, mid, "issue_counter")
  guard counter_id is Some(cid) else { return 1 }
  let obj = db.get(backing_fs, cid)
  guard obj is Some(counter_obj) else { return 1 }
  let text = @utf8.decode_lossy(counter_obj.data[:])
  parse_int(trim_whitespace(text))
}

///|
fn update_issues_tree(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  issue_id : String,
  issue_blob_id : @git.ObjectId,
  next_issue_id : Int,
) -> Unit raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let den_commit = get_den_commit(backing_fs, git_dir)
  guard den_commit is Some(commit_id) else {
    raise @git.GitError::InvalidObject("_den branch not found")
  }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(root_tree_id) else {
    raise @git.GitError::InvalidObject("_den tree not found")
  }
  let root_obj = db.get(backing_fs, root_tree_id)
  guard root_obj is Some(root_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read root tree")
  }
  let root_entries = @git.parse_tree(root_tree_obj.data)
  // Find existing tree IDs
  let mut den_tree_id = @git.ObjectId::zero()
  let mut meta_tree_id = @git.ObjectId::zero()
  let mut index_tree_id = @git.ObjectId::zero()
  let mut issues_tree_id = @git.ObjectId::zero()
  for entry in root_entries {
    match entry.name {
      "prs" => den_tree_id = entry.id
      "meta" => meta_tree_id = entry.id
      "index" => index_tree_id = entry.id
      "issues" => issues_tree_id = entry.id
      _ => ()
    }
  }
  // Create empty tree if needed
  if issues_tree_id == @git.ObjectId::zero() {
    let (empty_tree_id, empty_compressed) = @git.create_tree([])
    write_object_bytes(fs, git_dir, empty_tree_id, empty_compressed)
    issues_tree_id = empty_tree_id
  }
  // Create new issue directory tree
  let (empty_comments_id, comments_compressed) = @git.create_tree([])
  write_object_bytes(fs, git_dir, empty_comments_id, comments_compressed)
  let issue_dir_entries = [
    @git.TreeEntry::new("040000", "comments", empty_comments_id),
    @git.TreeEntry::new("100644", "issue.data", issue_blob_id),
  ]
  let (issue_dir_id, issue_dir_compressed) = @git.create_tree(issue_dir_entries)
  write_object_bytes(fs, git_dir, issue_dir_id, issue_dir_compressed)
  // Update issues tree
  let issues_obj = db.get(backing_fs, issues_tree_id)
  let existing_issues_entries = match issues_obj {
    Some(obj) => @git.parse_tree(obj.data)
    None => []
  }
  let new_issues_entries : Array[@git.TreeEntry] = []
  for entry in existing_issues_entries {
    new_issues_entries.push(entry)
  }
  new_issues_entries.push(@git.TreeEntry::new("040000", issue_id, issue_dir_id))
  new_issues_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_issues_tree_id, new_issues_compressed) = @git.create_tree(
    new_issues_entries,
  )
  write_object_bytes(fs, git_dir, new_issues_tree_id, new_issues_compressed)
  // Update issue_counter in meta
  let meta_obj = db.get(backing_fs, meta_tree_id)
  let existing_meta_entries = match meta_obj {
    Some(obj) => @git.parse_tree(obj.data)
    None => []
  }
  let issue_counter_content = next_issue_id.to_string() + "\n"
  let (issue_counter_id, counter_compressed) = @git.create_blob_string(
    issue_counter_content,
  )
  write_object_bytes(fs, git_dir, issue_counter_id, counter_compressed)
  let new_meta_entries : Array[@git.TreeEntry] = []
  let mut found_issue_counter = false
  for entry in existing_meta_entries {
    if entry.name == "issue_counter" {
      new_meta_entries.push(
        @git.TreeEntry::new("100644", "issue_counter", issue_counter_id),
      )
      found_issue_counter = true
    } else {
      new_meta_entries.push(entry)
    }
  }
  if not(found_issue_counter) {
    new_meta_entries.push(
      @git.TreeEntry::new("100644", "issue_counter", issue_counter_id),
    )
  }
  new_meta_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_meta_tree_id, new_meta_compressed) = @git.create_tree(
    new_meta_entries,
  )
  write_object_bytes(fs, git_dir, new_meta_tree_id, new_meta_compressed)
  // Create new root tree
  let new_root_entries = [
    @git.TreeEntry::new("040000", "index", index_tree_id),
    @git.TreeEntry::new("040000", "issues", new_issues_tree_id),
    @git.TreeEntry::new("040000", "meta", new_meta_tree_id),
    @git.TreeEntry::new("040000", "prs", den_tree_id),
  ]
  let (new_root_tree_id, new_root_compressed) = @git.create_tree(
    new_root_entries,
  )
  write_object_bytes(fs, git_dir, new_root_tree_id, new_root_compressed)
  // Create commit
  let commit = @git.Commit::new(
    new_root_tree_id,
    [commit_id],
    "Collab <den@local>",
    0L,
    "+0000",
    "Collab <den@local>",
    0L,
    "+0000",
    "Create Issue #\{issue_id}\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, den_ref)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}

///|
fn update_issue_data(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  issue_id : String,
  issue_blob_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let den_commit = get_den_commit(backing_fs, git_dir)
  guard den_commit is Some(commit_id) else {
    raise @git.GitError::InvalidObject("_den branch not found")
  }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(root_tree_id) else {
    raise @git.GitError::InvalidObject("_den tree not found")
  }
  let root_obj = db.get(backing_fs, root_tree_id)
  guard root_obj is Some(root_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read root tree")
  }
  let root_entries = @git.parse_tree(root_tree_obj.data)
  let mut den_tree_id = @git.ObjectId::zero()
  let mut meta_tree_id = @git.ObjectId::zero()
  let mut index_tree_id = @git.ObjectId::zero()
  let mut issues_tree_id = @git.ObjectId::zero()
  for entry in root_entries {
    match entry.name {
      "prs" => den_tree_id = entry.id
      "meta" => meta_tree_id = entry.id
      "index" => index_tree_id = entry.id
      "issues" => issues_tree_id = entry.id
      _ => ()
    }
  }
  // Get existing issues tree
  let issues_obj = db.get(backing_fs, issues_tree_id)
  guard issues_obj is Some(issues_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read issues tree")
  }
  let issues_entries = @git.parse_tree(issues_tree_obj.data)
  // Find and update the issue directory
  let new_issues_entries : Array[@git.TreeEntry] = []
  for entry in issues_entries {
    if entry.name == issue_id {
      let issue_dir_obj = db.get(backing_fs, entry.id)
      guard issue_dir_obj is Some(dir_obj) else { continue }
      let dir_entries = @git.parse_tree(dir_obj.data)
      let new_dir_entries : Array[@git.TreeEntry] = []
      for de in dir_entries {
        if de.name == "issue.data" {
          new_dir_entries.push(
            @git.TreeEntry::new("100644", "issue.data", issue_blob_id),
          )
        } else {
          new_dir_entries.push(de)
        }
      }
      new_dir_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
      let (new_dir_id, dir_compressed) = @git.create_tree(new_dir_entries)
      write_object_bytes(fs, git_dir, new_dir_id, dir_compressed)
      new_issues_entries.push(
        @git.TreeEntry::new("040000", issue_id, new_dir_id),
      )
    } else {
      new_issues_entries.push(entry)
    }
  }
  new_issues_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_issues_tree_id, new_issues_compressed) = @git.create_tree(
    new_issues_entries,
  )
  write_object_bytes(fs, git_dir, new_issues_tree_id, new_issues_compressed)
  // Create new root tree
  let new_root_entries = [
    @git.TreeEntry::new("040000", "index", index_tree_id),
    @git.TreeEntry::new("040000", "issues", new_issues_tree_id),
    @git.TreeEntry::new("040000", "meta", meta_tree_id),
    @git.TreeEntry::new("040000", "prs", den_tree_id),
  ]
  let (new_root_tree_id, new_root_compressed) = @git.create_tree(
    new_root_entries,
  )
  write_object_bytes(fs, git_dir, new_root_tree_id, new_root_compressed)
  // Create commit
  let commit = @git.Commit::new(
    new_root_tree_id,
    [commit_id],
    "Collab <den@local>",
    0L,
    "+0000",
    "Collab <den@local>",
    0L,
    "+0000",
    "Update Issue #\{issue_id}\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, den_ref)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}

///|
fn add_issue_comment_to_tree(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  issue_id : String,
  comment_id : String,
  blob_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let den_commit = get_den_commit(backing_fs, git_dir)
  guard den_commit is Some(commit_id_val) else {
    raise @git.GitError::InvalidObject("_den branch not found")
  }
  let den_tree = get_commit_tree(db, backing_fs, commit_id_val)
  guard den_tree is Some(root_tree_id) else {
    raise @git.GitError::InvalidObject("_den tree not found")
  }
  let root_obj = db.get(backing_fs, root_tree_id)
  guard root_obj is Some(root_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read root tree")
  }
  let root_entries = @git.parse_tree(root_tree_obj.data)
  let mut den_tree_id = @git.ObjectId::zero()
  let mut meta_tree_id = @git.ObjectId::zero()
  let mut index_tree_id = @git.ObjectId::zero()
  let mut issues_tree_id = @git.ObjectId::zero()
  for entry in root_entries {
    match entry.name {
      "prs" => den_tree_id = entry.id
      "meta" => meta_tree_id = entry.id
      "index" => index_tree_id = entry.id
      "issues" => issues_tree_id = entry.id
      _ => ()
    }
  }
  // Get issues tree
  let issues_obj = db.get(backing_fs, issues_tree_id)
  guard issues_obj is Some(issues_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read issues tree")
  }
  let issues_entries = @git.parse_tree(issues_tree_obj.data)
  // Find and update the issue directory
  let new_issues_entries : Array[@git.TreeEntry] = []
  for entry in issues_entries {
    if entry.name == issue_id {
      let issue_dir_obj = db.get(backing_fs, entry.id)
      guard issue_dir_obj is Some(dir_obj) else { continue }
      let dir_entries = @git.parse_tree(dir_obj.data)
      let new_dir_entries : Array[@git.TreeEntry] = []
      for de in dir_entries {
        if de.name == "comments" {
          // Add new comment
          let comments_obj = db.get(backing_fs, de.id)
          let existing_comments = match comments_obj {
            Some(obj) => @git.parse_tree(obj.data)
            None => []
          }
          let new_comments : Array[@git.TreeEntry] = []
          for ce in existing_comments {
            new_comments.push(ce)
          }
          new_comments.push(@git.TreeEntry::new("100644", comment_id, blob_id))
          new_comments.sort_by(fn(a, b) { String::compare(a.name, b.name) })
          let (new_comments_id, comments_compressed) = @git.create_tree(
            new_comments,
          )
          write_object_bytes(fs, git_dir, new_comments_id, comments_compressed)
          new_dir_entries.push(
            @git.TreeEntry::new("040000", "comments", new_comments_id),
          )
        } else {
          new_dir_entries.push(de)
        }
      }
      new_dir_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
      let (new_dir_id, dir_compressed) = @git.create_tree(new_dir_entries)
      write_object_bytes(fs, git_dir, new_dir_id, dir_compressed)
      new_issues_entries.push(
        @git.TreeEntry::new("040000", issue_id, new_dir_id),
      )
    } else {
      new_issues_entries.push(entry)
    }
  }
  new_issues_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_issues_tree_id, new_issues_compressed) = @git.create_tree(
    new_issues_entries,
  )
  write_object_bytes(fs, git_dir, new_issues_tree_id, new_issues_compressed)
  // Create new root tree
  let new_root_entries = [
    @git.TreeEntry::new("040000", "index", index_tree_id),
    @git.TreeEntry::new("040000", "issues", new_issues_tree_id),
    @git.TreeEntry::new("040000", "meta", meta_tree_id),
    @git.TreeEntry::new("040000", "prs", den_tree_id),
  ]
  let (new_root_tree_id, new_root_compressed) = @git.create_tree(
    new_root_entries,
  )
  write_object_bytes(fs, git_dir, new_root_tree_id, new_root_compressed)
  // Create commit
  let commit = @git.Commit::new(
    new_root_tree_id,
    [commit_id_val],
    "Collab <den@local>",
    0L,
    "+0000",
    "Collab <den@local>",
    0L,
    "+0000",
    "Add comment to Issue #\{issue_id}\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, den_ref)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}
