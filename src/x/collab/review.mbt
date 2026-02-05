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
  ignore(
    self.store.put_record(
      fs,
      backing_fs,
      pr_review_key(pr_id, review_id),
      "pr.review",
      final_review.serialize(),
      author,
      timestamp,
    ),
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
) -> Array[PrReview] {
  let result : Array[PrReview] = []
  let records = self.store.list_records(backing_fs, pr_review_prefix(pr_id))
  for record in records {
    if record.kind != "pr.review" {
      continue
    }
    let review = parse_pr_review(record.payload) catch { _ => continue }
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
) -> Bool {
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
