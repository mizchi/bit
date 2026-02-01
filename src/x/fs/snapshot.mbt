///| Snapshot operations: commit, checkout, rollback

///|
pub fn Fs::snapshot(
  self : Fs,
  backing_fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  message : String,
  author : String,
  timestamp : Int64,
) -> Snapshot raise @git.GitError {
  if not(self.working.is_dirty()) {
    raise @git.GitError::InvalidObject("No changes to commit")
  }
  let tree_id = build_tree_from_working(
    backing_fs,
    rfs,
    self.git_dir,
    self.base_tree,
    self.working,
  )
  let parents = match self.base_commit {
    Some(id) => [id]
    None => []
  }
  let commit = @git.Commit::new(
    tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000", message,
  )
  let (commit_id, compressed) = @git.create_commit(commit)
  @lib.write_object_bytes(backing_fs, self.git_dir, commit_id, compressed)
  self.base_tree = tree_id
  self.base_commit = Some(commit_id)
  self.working.clear()
  self.cache.clear()
  self.cached_db = None // Invalidate ObjectDb cache since new objects were written
  Snapshot::new(commit_id, tree_id, message, author, timestamp)
}

///|
pub fn Fs::checkout_snapshot(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let db = self.get_db(backing_fs)
  let obj = db.get(backing_fs, commit_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Commit not found: \{commit_id}")
  }
  if o.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Not a commit: \{commit_id}")
  }
  let info = @git.parse_commit(o.data)
  self.base_tree = info.tree
  self.base_commit = Some(commit_id)
  self.working.clear()
  self.cache.clear()
}

///|
pub fn Fs::rollback(self : Fs) -> Unit {
  self.working.clear()
  self.cache.clear()
}

///|
pub fn Fs::list_snapshots(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  max_count? : Int = 100,
) -> Array[Snapshot] raise @git.GitError {
  let result : Array[Snapshot] = []
  let mut current = self.base_commit
  let db = self.get_db(backing_fs)
  let mut count = 0
  while count < max_count {
    match current {
      None => break
      Some(commit_id) => {
        let obj = db.get(backing_fs, commit_id)
        match obj {
          None => break
          Some(o) => {
            if o.obj_type != @git.ObjectType::Commit {
              break
            }
            let info = @git.parse_commit(o.data)
            let (author, timestamp, message) = parse_commit_details(o.data)
            result.push(
              Snapshot::new(commit_id, info.tree, message, author, timestamp),
            )
            current = if info.parents.length() > 0 {
              Some(info.parents[0])
            } else {
              None
            }
          }
        }
      }
    }
    count += 1
  }
  result
}

///|
fn parse_commit_details(content : Bytes) -> (String, Int64, String) {
  let text = @utf8.decode_lossy(content[:])
  let mut author = ""
  let mut timestamp = 0L
  let mut in_message = false
  let message_buf = StringBuilder::new()
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      if message_buf.to_string().length() > 0 {
        message_buf.write_char('\n')
      }
      message_buf.write_string(line)
    } else if line.length() == 0 {
      in_message = true
    } else if line.has_prefix("author ") {
      let rest = String::unsafe_substring(line, start=7, end=line.length())
      match rest.rev_find(" ") {
        Some(space2) => {
          let before_tz = String::unsafe_substring(rest, start=0, end=space2)
          match before_tz.rev_find(" ") {
            Some(space1) => {
              author = String::unsafe_substring(before_tz, start=0, end=space1)
              let ts_str = String::unsafe_substring(
                before_tz,
                start=space1 + 1,
                end=before_tz.length(),
              )
              timestamp = parse_int64(ts_str)
            }
            None => author = rest
          }
        }
        None => author = rest
      }
    }
  } else {
    ()
  }
  (author, timestamp, message_buf.to_string().trim().to_string())
}

///|
fn parse_int64(s : String) -> Int64 {
  let mut result = 0L
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
  }
  result
}

///|
pub fn Fs::discard_changes(self : Fs) -> Unit {
  self.rollback()
}

///|
pub fn Fs::get_working_files(self : Fs) -> Array[String] {
  let out = self.working.files.keys().collect()
  out.sort()
  out
}

///|
pub fn Fs::get_deleted_files(self : Fs) -> Array[String] {
  let out = self.working.deleted.keys().collect()
  out.sort()
  out
}
