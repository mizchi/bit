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
  ignore(
    self.store.put_record(
      fs,
      backing_fs,
      pr_comment_key(pr_id, comment_id),
      "pr.comment",
      final_comment.serialize(),
      author,
      timestamp,
    ),
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
) -> Array[PrComment] {
  let result : Array[PrComment] = []
  let records = self.store.list_records(backing_fs, pr_comment_prefix(pr_id))
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
