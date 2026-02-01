///| PR Comment operations

///|
/// Add a comment to a Pull Request
pub fn Collab::add_comment(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  author : String,
  body : String,
  timestamp : Int64,
  reply_to? : String? = None,
  file_path? : String? = None,
  line_number? : Int? = None,
  commit_id? : @git.ObjectId? = None,
) -> PrComment raise @git.GitError {
  // Verify PR exists
  let pr = self.get_pr(backing_fs, pr_id)
  guard pr is Some(_) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
  }
  // Generate comment ID from content hash
  let comment = PrComment::new(
    "", // Will be set after hashing
    pr_id,
    author,
    body,
    timestamp,
    reply_to~,
    file_path~,
    line_number~,
    commit_id~,
  )
  let comment_data = comment.serialize()
  let (blob_id, compressed) = @git.create_blob_string(comment_data)
  let comment_id = short_hex(blob_id.to_hex(), 8)
  // Create final comment with ID
  let final_comment = PrComment::new(
    comment_id,
    pr_id,
    author,
    body,
    timestamp,
    reply_to~,
    file_path~,
    line_number~,
    commit_id~,
  )
  let final_data = final_comment.serialize()
  let (final_blob_id, final_compressed) = @git.create_blob_string(final_data)
  write_object_bytes(fs, self.git_dir, final_blob_id, final_compressed)
  // Update _den tree with new comment
  add_comment_to_tree(
    fs,
    backing_fs,
    self.git_dir,
    pr_id,
    comment_id,
    final_blob_id,
  )
  ignore(compressed)
  final_comment
}

///|
fn short_hex(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
}

///|
/// List comments for a Pull Request
pub fn Collab::list_comments(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
) -> Array[PrComment] raise @git.GitError {
  let result : Array[PrComment] = []
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let den_commit = get_den_commit(backing_fs, self.git_dir)
  guard den_commit is Some(commit_id) else { return result }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return result }
  // Navigate to prs/<id>/comments
  let prs_dir_id = find_tree_entry(db, backing_fs, tree_id, "prs")
  guard prs_dir_id is Some(pid) else { return result }
  let pr_dir_id = find_tree_entry(db, backing_fs, pid, pr_id)
  guard pr_dir_id is Some(prid) else { return result }
  let comments_id = find_tree_entry(db, backing_fs, prid, "comments")
  guard comments_id is Some(cid) else { return result }
  // List all comment blobs
  let comments_obj = db.get(backing_fs, cid)
  guard comments_obj is Some(tree_obj) else { return result }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    let obj = db.get(backing_fs, entry.id)
    guard obj is Some(data_obj) else { continue }
    let text = @utf8.decode_lossy(data_obj.data[:])
    let comment = parse_pr_comment(text) catch { _ => continue }
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
fn add_comment_to_tree(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  pr_id : String,
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
  // Get prs tree
  let prs_obj = db.get(backing_fs, den_tree_id)
  guard prs_obj is Some(den_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read prs tree")
  }
  let prs_entries = @git.parse_tree(den_tree_obj.data)
  // Find and update the PR directory
  let new_den_entries : Array[@git.TreeEntry] = []
  for entry in prs_entries {
    if entry.name == pr_id {
      // Update comments in this PR's directory
      let pr_dir_obj = db.get(backing_fs, entry.id)
      guard pr_dir_obj is Some(dir_obj) else { continue }
      let dir_entries = @git.parse_tree(dir_obj.data)
      let new_dir_entries : Array[@git.TreeEntry] = []
      for de in dir_entries {
        if de.name == "comments" {
          // Add new comment to comments tree
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
    [commit_id_val],
    "Collab <den@local>",
    0L,
    "+0000",
    "Collab <den@local>",
    0L,
    "+0000",
    "Add comment to PR #\{pr_id}\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, den_ref)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}
