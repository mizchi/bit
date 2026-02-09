///| PR Comment operations

///|
/// Add a comment to a Pull Request
pub fn Hub::add_comment(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  pr_id : String,
  author : String,
  body : String,
  reply_to? : String? = None,
  file_path? : String? = None,
  line_number? : Int? = None,
  commit_id? : @git.ObjectId? = None,
) -> PrComment raise @git.GitError {
  // Verify PR exists
  let pr = self.get_pr(objects, pr_id)
  guard pr is Some(_) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
  }
  let timestamp = clock.now()
  // Generate comment ID from content hash
  let comment = PrComment::new(
    "",
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
  let (blob_id, _compressed) = @git.create_blob_string(comment_data)
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
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      pr_comment_key(pr_id, comment_id),
      "pr.comment",
      final_comment.serialize(),
      author,
    ),
  )
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
pub fn Hub::list_comments(
  self : Hub,
  objects : &@lib.ObjectStore,
  pr_id : String,
) -> Array[PrComment] {
  let result : Array[PrComment] = []
  let records = self.store.list_records(objects, pr_comment_prefix(pr_id))
  for record in records {
    if record.kind != "pr.comment" {
      continue
    }
    let comment = parse_pr_comment(record.payload) catch { _ => continue }
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
