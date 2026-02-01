///| Collab - Git-native collaboration system (Pull Requests, Issues)

///|
/// The _den branch reference
let den_ref : String = "refs/heads/_den"

///|
/// Collab manages Pull Requests and Issues stored in the _den branch
pub struct Collab {
  git_dir : String
  mut next_id : Int
}

///|
/// Load an existing Collab from the _den branch
pub fn Collab::load(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Collab raise @git.GitError {
  let next_id = load_counter(backing_fs, git_dir)
  { git_dir, next_id }
}

///|
/// Initialize a new Collab, creating the _den branch if needed
pub fn Collab::init(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Collab raise @git.GitError {
  // Check if _den branch exists
  let ref_path = join_path(git_dir, den_ref)
  if not(backing_fs.is_file(ref_path)) {
    // Create initial tree structure
    let counter_content = "1\n"
    let (counter_id, counter_compressed) = @git.create_blob_string(
      counter_content,
    )
    write_object_bytes(fs, git_dir, counter_id, counter_compressed)
    let (issue_counter_id, issue_counter_compressed) = @git.create_blob_string(
      counter_content,
    )
    write_object_bytes(fs, git_dir, issue_counter_id, issue_counter_compressed)
    // Create meta directory tree with both counters
    let meta_entries = [
      @git.TreeEntry::new("100644", "counter", counter_id),
      @git.TreeEntry::new("100644", "issue_counter", issue_counter_id),
    ]
    let (meta_tree_id, meta_compressed) = @git.create_tree(meta_entries)
    write_object_bytes(fs, git_dir, meta_tree_id, meta_compressed)
    // Create empty prs, issues, and index directories
    let (empty_tree_id, empty_compressed) = @git.create_tree([])
    write_object_bytes(fs, git_dir, empty_tree_id, empty_compressed)
    // Create root tree
    let root_entries = [
      @git.TreeEntry::new("040000", "index", empty_tree_id),
      @git.TreeEntry::new("040000", "issues", empty_tree_id),
      @git.TreeEntry::new("040000", "meta", meta_tree_id),
      @git.TreeEntry::new("040000", "prs", empty_tree_id),
    ]
    let (root_tree_id, root_compressed) = @git.create_tree(root_entries)
    write_object_bytes(fs, git_dir, root_tree_id, root_compressed)
    // Create initial commit
    let commit = @git.Commit::new(
      root_tree_id,
      [],
      "Collab <den@local>",
      0L,
      "+0000",
      "Collab <den@local>",
      0L,
      "+0000",
      "Initialize PR system\n",
    )
    let (commit_id, commit_compressed) = @git.create_commit(commit)
    write_object_bytes(fs, git_dir, commit_id, commit_compressed)
    // Create _den branch ref
    let refs_dir = join_path(git_dir, "refs/heads")
    fs.mkdir_p(refs_dir)
    fs.write_string(ref_path, commit_id.to_hex() + "\n")
  }
  Collab::load(backing_fs, git_dir)
}

///|
/// Create a new Pull Request
pub fn Collab::create_pr(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  title : String,
  body : String,
  source_branch : String,
  target_branch : String,
  author : String,
  timestamp : Int64,
) -> PullRequest raise @git.GitError {
  // Resolve source and target commits
  let source_commit = @lib.resolve_ref(backing_fs, self.git_dir, source_branch) catch {
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
  let target_commit = @lib.resolve_ref(backing_fs, self.git_dir, target_branch) catch {
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
  // Generate PR ID
  let pr_id = self.next_id.to_string()
  self.next_id = self.next_id + 1
  // Create PullRequest object
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
  )
  // Serialize and store
  let pr_data = pr.serialize()
  let (pr_blob_id, pr_compressed) = @git.create_blob_string(pr_data)
  write_object_bytes(fs, self.git_dir, pr_blob_id, pr_compressed)
  // Update _den tree structure
  update_den_tree(fs, backing_fs, self.git_dir, pr_id, pr_blob_id, self.next_id)
  pr
}

///|
/// Get a Pull Request by ID
pub fn Collab::get_pr(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
) -> PullRequest? raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let den_commit = get_den_commit(backing_fs, self.git_dir)
  guard den_commit is Some(commit_id) else { return None }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return None }
  // Navigate to prs/<id>/pr.data
  let pr_tree_id = find_tree_entry(db, backing_fs, tree_id, "prs")
  guard pr_tree_id is Some(prs_dir_id) else { return None }
  let pr_dir_id = find_tree_entry(db, backing_fs, prs_dir_id, pr_id)
  guard pr_dir_id is Some(pr_dir) else { return None }
  let pr_data_id = find_tree_entry(db, backing_fs, pr_dir, "pr.data")
  guard pr_data_id is Some(data_id) else { return None }
  // Read and parse
  let obj = db.get(backing_fs, data_id)
  guard obj is Some(data_obj) else { return None }
  let text = @utf8.decode_lossy(data_obj.data[:])
  Some(parse_pull_request(text) catch { _ => return None })
}

///|
/// List Pull Requests, optionally filtered by state
pub fn Collab::list_prs(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  state? : PrState? = None,
) -> Array[PullRequest] raise @git.GitError {
  let result : Array[PullRequest] = []
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let den_commit = get_den_commit(backing_fs, self.git_dir)
  guard den_commit is Some(commit_id) else { return result }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return result }
  let pr_tree_id = find_tree_entry(db, backing_fs, tree_id, "prs")
  guard pr_tree_id is Some(prs_dir_id) else { return result }
  // List all PR directories
  let prs_obj = db.get(backing_fs, prs_dir_id)
  guard prs_obj is Some(den_tree_obj) else { return result }
  let entries = @git.parse_tree(den_tree_obj.data)
  for entry in entries {
    // Each entry is a PR directory
    let pr_data_id = find_tree_entry(db, backing_fs, entry.id, "pr.data")
    guard pr_data_id is Some(data_id) else { continue }
    let obj = db.get(backing_fs, data_id)
    guard obj is Some(data_obj) else { continue }
    let text = @utf8.decode_lossy(data_obj.data[:])
    let pr = parse_pull_request(text) catch { _ => continue }
    match state {
      None => result.push(pr)
      Some(s) => if pr.state == s { result.push(pr) }
    }
  }
  result.sort_by(fn(a, b) { parse_int(a.id) - parse_int(b.id) })
  result
}

///|
/// Update a Pull Request (title, body, labels)
pub fn Collab::update_pr(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  timestamp : Int64,
  title? : String? = None,
  body? : String? = None,
  labels? : Array[String]? = None,
) -> PullRequest raise @git.GitError {
  let pr = self.get_pr(backing_fs, pr_id)
  guard pr is Some(existing) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
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
  let updated = PullRequest::new(
    existing.id,
    new_title,
    new_body,
    existing.source_branch,
    existing.source_commit,
    existing.target_branch,
    existing.target_commit,
    existing.author,
    existing.created_at,
    timestamp,
    existing.state,
    new_labels,
  )
  let pr_data = updated.serialize()
  let (pr_blob_id, pr_compressed) = @git.create_blob_string(pr_data)
  write_object_bytes(fs, self.git_dir, pr_blob_id, pr_compressed)
  update_pr_data(fs, backing_fs, self.git_dir, pr_id, pr_blob_id)
  updated
}

///|
/// Close a Pull Request
pub fn Collab::close_pr(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  let pr = self.get_pr(backing_fs, pr_id)
  guard pr is Some(existing) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
  }
  if existing.state != PrState::Open {
    raise @git.GitError::InvalidObject("PR is not open: \{pr_id}")
  }
  // Create updated PR with Closed state
  let updated = PullRequest::new(
    existing.id,
    existing.title,
    existing.body,
    existing.source_branch,
    existing.source_commit,
    existing.target_branch,
    existing.target_commit,
    existing.author,
    existing.created_at,
    timestamp,
    PrState::Closed,
    existing.labels,
  )
  // Store updated PR
  let pr_data = updated.serialize()
  let (pr_blob_id, pr_compressed) = @git.create_blob_string(pr_data)
  write_object_bytes(fs, self.git_dir, pr_blob_id, pr_compressed)
  // Update tree
  update_pr_data(fs, backing_fs, self.git_dir, pr_id, pr_blob_id)
}

///|
fn load_counter(
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
  let counter_id = find_tree_entry(db, backing_fs, mid, "counter")
  guard counter_id is Some(cid) else { return 1 }
  let obj = db.get(backing_fs, cid)
  guard obj is Some(counter_obj) else { return 1 }
  let text = @utf8.decode_lossy(counter_obj.data[:])
  parse_int(trim_whitespace(text))
}

///|
fn get_den_commit(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId? raise @git.GitError {
  @lib.resolve_ref(backing_fs, git_dir, den_ref)
}

///|
fn get_commit_tree(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(backing_fs, commit_id)
  guard obj is Some(commit_obj) else { return None }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return None
  }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|
fn find_tree_entry(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  name : String,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(tree_obj) else { return None }
  if tree_obj.obj_type != @git.ObjectType::Tree {
    return None
  }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    if entry.name == name {
      return Some(entry.id)
    }
  }
  None
}

///|
fn trim_whitespace(s : String) -> String {
  let chars = s.to_array()
  let mut start = 0
  let mut end = chars.length()
  while start < end {
    let c = chars[start]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      start = start + 1
    } else {
      break
    }
  }
  while end > start {
    let c = chars[end - 1]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      end = end - 1
    } else {
      break
    }
  }
  if start >= end {
    ""
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn update_den_tree(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  pr_id : String,
  pr_blob_id : @git.ObjectId,
  next_id : Int,
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
  // Get current tree entries
  let root_obj = db.get(backing_fs, root_tree_id)
  guard root_obj is Some(root_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read root tree")
  }
  let root_entries = @git.parse_tree(root_tree_obj.data)
  // Find prs, meta, index, issues tree IDs
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
  // Create new PR directory tree with pr.data, empty comments, empty reviews
  let (empty_tree_id, empty_compressed) = @git.create_tree([])
  write_object_bytes(fs, git_dir, empty_tree_id, empty_compressed)
  let pr_dir_entries = [
    @git.TreeEntry::new("040000", "comments", empty_tree_id),
    @git.TreeEntry::new("100644", "pr.data", pr_blob_id),
    @git.TreeEntry::new("040000", "reviews", empty_tree_id),
  ]
  let (pr_dir_id, pr_dir_compressed) = @git.create_tree(pr_dir_entries)
  write_object_bytes(fs, git_dir, pr_dir_id, pr_dir_compressed)
  // Update prs tree with new entry
  let prs_obj = db.get(backing_fs, den_tree_id)
  let existing_den_entries = match prs_obj {
    Some(obj) => @git.parse_tree(obj.data)
    None => []
  }
  let new_den_entries : Array[@git.TreeEntry] = []
  for entry in existing_den_entries {
    new_den_entries.push(entry)
  }
  new_den_entries.push(@git.TreeEntry::new("040000", pr_id, pr_dir_id))
  new_den_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_den_tree_id, new_den_compressed) = @git.create_tree(new_den_entries)
  write_object_bytes(fs, git_dir, new_den_tree_id, new_den_compressed)
  // Update counter in meta (preserve issue_counter if exists)
  let counter_content = next_id.to_string() + "\n"
  let (counter_id, counter_compressed) = @git.create_blob_string(
    counter_content,
  )
  write_object_bytes(fs, git_dir, counter_id, counter_compressed)
  let meta_obj = db.get(backing_fs, meta_tree_id)
  let existing_meta_entries = match meta_obj {
    Some(obj) => @git.parse_tree(obj.data)
    None => []
  }
  let new_meta_entries : Array[@git.TreeEntry] = []
  let mut found_counter = false
  for entry in existing_meta_entries {
    if entry.name == "counter" {
      new_meta_entries.push(
        @git.TreeEntry::new("100644", "counter", counter_id),
      )
      found_counter = true
    } else {
      new_meta_entries.push(entry)
    }
  }
  if not(found_counter) {
    new_meta_entries.push(@git.TreeEntry::new("100644", "counter", counter_id))
  }
  new_meta_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_meta_tree_id, new_meta_compressed) = @git.create_tree(
    new_meta_entries,
  )
  write_object_bytes(fs, git_dir, new_meta_tree_id, new_meta_compressed)
  // Create new root tree (include issues tree)
  let new_root_entries = [
    @git.TreeEntry::new("040000", "index", index_tree_id),
    @git.TreeEntry::new("040000", "issues", issues_tree_id),
    @git.TreeEntry::new("040000", "meta", new_meta_tree_id),
    @git.TreeEntry::new("040000", "prs", new_den_tree_id),
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
    "Create PR #\{pr_id}\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, den_ref)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}

///|
fn update_pr_data(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  pr_id : String,
  pr_blob_id : @git.ObjectId,
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
  // Get existing prs tree
  let prs_obj = db.get(backing_fs, den_tree_id)
  guard prs_obj is Some(den_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read prs tree")
  }
  let prs_entries = @git.parse_tree(den_tree_obj.data)
  // Find and update the PR directory
  let new_den_entries : Array[@git.TreeEntry] = []
  for entry in prs_entries {
    if entry.name == pr_id {
      // Update this PR's directory
      let pr_dir_obj = db.get(backing_fs, entry.id)
      guard pr_dir_obj is Some(dir_obj) else { continue }
      let dir_entries = @git.parse_tree(dir_obj.data)
      let new_dir_entries : Array[@git.TreeEntry] = []
      for de in dir_entries {
        if de.name == "pr.data" {
          new_dir_entries.push(
            @git.TreeEntry::new("100644", "pr.data", pr_blob_id),
          )
        } else {
          new_dir_entries.push(de)
        }
      }
      new_dir_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
      let (new_dir_id, dir_compressed) = @git.create_tree(new_dir_entries)
      write_object_bytes(fs, git_dir, new_dir_id, dir_compressed)
      new_den_entries.push(@git.TreeEntry::new("040000", pr_id, new_dir_id))
    } else {
      new_den_entries.push(entry)
    }
  }
  new_den_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_den_tree_id, new_den_compressed) = @git.create_tree(new_den_entries)
  write_object_bytes(fs, git_dir, new_den_tree_id, new_den_compressed)
  // Create new root tree (include issues tree)
  let new_root_entries = [
    @git.TreeEntry::new("040000", "index", index_tree_id),
    @git.TreeEntry::new("040000", "issues", issues_tree_id),
    @git.TreeEntry::new("040000", "meta", meta_tree_id),
    @git.TreeEntry::new("040000", "prs", new_den_tree_id),
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
    "Update PR #\{pr_id}\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, den_ref)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}

///|
fn write_object_bytes(
  fs : &@git.FileSystem,
  git_dir : String,
  id : @git.ObjectId,
  compressed : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let dir = join_path(
    git_dir,
    "objects/" + String::unsafe_substring(hex, start=0, end=2),
  )
  let path = join_path(dir, String::unsafe_substring(hex, start=2, end=40))
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
}

///|
fn join_path(a : String, b : String) -> String {
  if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}
