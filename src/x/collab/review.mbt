///| PR Review operations

///|
/// Submit a review for a Pull Request
pub fn Collab::submit_review(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  author : String,
  verdict : ReviewVerdict,
  body : String,
  commit_id : @git.ObjectId,
  timestamp : Int64,
) -> PrReview raise @git.GitError {
  // Verify PR exists and is open
  let pr = self.get_pr(backing_fs, pr_id)
  guard pr is Some(existing) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
  }
  if existing.state != PrState::Open {
    raise @git.GitError::InvalidObject("PR is not open: \{pr_id}")
  }
  // Generate review ID from content hash
  let review = PrReview::new(
    "", // Will be set after hashing
     pr_id, author, verdict, body, timestamp, commit_id,
  )
  let review_data = review.serialize()
  let (blob_id, compressed) = @git.create_blob_string(review_data)
  let review_id = short_hex(blob_id.to_hex(), 8)
  // Create final review with ID
  let final_review = PrReview::new(
    review_id, pr_id, author, verdict, body, timestamp, commit_id,
  )
  let final_data = final_review.serialize()
  let (final_blob_id, final_compressed) = @git.create_blob_string(final_data)
  write_object_bytes(fs, self.git_dir, final_blob_id, final_compressed)
  // Update _den tree with new review
  add_review_to_tree(
    fs,
    backing_fs,
    self.git_dir,
    pr_id,
    review_id,
    final_blob_id,
  )
  ignore(compressed)
  final_review
}

///|
/// List reviews for a Pull Request
pub fn Collab::list_reviews(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
) -> Array[PrReview] raise @git.GitError {
  let result : Array[PrReview] = []
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let den_commit = get_den_commit(backing_fs, self.git_dir)
  guard den_commit is Some(commit_id) else { return result }
  let den_tree = get_commit_tree(db, backing_fs, commit_id)
  guard den_tree is Some(tree_id) else { return result }
  // Navigate to prs/<id>/reviews
  let prs_dir_id = find_tree_entry(db, backing_fs, tree_id, "prs")
  guard prs_dir_id is Some(pid) else { return result }
  let pr_dir_id = find_tree_entry(db, backing_fs, pid, pr_id)
  guard pr_dir_id is Some(prid) else { return result }
  let reviews_id = find_tree_entry(db, backing_fs, prid, "reviews")
  guard reviews_id is Some(rid) else { return result }
  // List all review blobs
  let reviews_obj = db.get(backing_fs, rid)
  guard reviews_obj is Some(tree_obj) else { return result }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    let obj = db.get(backing_fs, entry.id)
    guard obj is Some(data_obj) else { continue }
    let text = @utf8.decode_lossy(data_obj.data[:])
    let review = parse_pr_review(text) catch { _ => continue }
    result.push(review)
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
/// Check if a PR is approved (has at least one Approved review with no RequestChanges after it)
pub fn Collab::is_approved(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
) -> Bool raise @git.GitError {
  let reviews = self.list_reviews(backing_fs, pr_id)
  if reviews.length() == 0 {
    return false
  }
  // Track latest verdict per author
  let latest_verdicts : Map[String, ReviewVerdict] = {}
  for review in reviews {
    latest_verdicts[review.author] = review.verdict
  }
  // Check if there's at least one approval and no pending request-changes
  let mut has_approval = false
  for item in latest_verdicts.to_array() {
    let (_, verdict) = item
    match verdict {
      Approved => has_approval = true
      RequestChanges => return false
      Comment => ()
    }
  }
  has_approval
}

///|
fn add_review_to_tree(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  pr_id : String,
  review_id : String,
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
      // Update reviews in this PR's directory
      let pr_dir_obj = db.get(backing_fs, entry.id)
      guard pr_dir_obj is Some(dir_obj) else { continue }
      let dir_entries = @git.parse_tree(dir_obj.data)
      let new_dir_entries : Array[@git.TreeEntry] = []
      for de in dir_entries {
        if de.name == "reviews" {
          // Add new review to reviews tree
          let reviews_obj = db.get(backing_fs, de.id)
          let existing_reviews = match reviews_obj {
            Some(obj) => @git.parse_tree(obj.data)
            None => []
          }
          let new_reviews : Array[@git.TreeEntry] = []
          for re in existing_reviews {
            new_reviews.push(re)
          }
          new_reviews.push(@git.TreeEntry::new("100644", review_id, blob_id))
          new_reviews.sort_by(fn(a, b) { String::compare(a.name, b.name) })
          let (new_reviews_id, reviews_compressed) = @git.create_tree(
            new_reviews,
          )
          write_object_bytes(fs, git_dir, new_reviews_id, reviews_compressed)
          new_dir_entries.push(
            @git.TreeEntry::new("040000", "reviews", new_reviews_id),
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
    "Add review to PR #\{pr_id}\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, den_ref)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}
