///| Git log helpers

///|
pub struct LogEntry {
  id : @git.ObjectId
  message : String
  author : String
  timestamp : Int64
  tree : @git.ObjectId
  parent_tree : @git.ObjectId?
}

///|
/// Read commit history from HEAD.
pub fn log_head(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  max_count? : Int = 100,
  since? : Int64 = 0L,
  until? : Int64 = 9223372036854775807L,
) -> Array[LogEntry] raise @git.GitError {
  let result : Array[LogEntry] = []
  let mut current = resolve_head_commit(fs, git_dir)
  let mut count = 0
  let db = ObjectDb::load(fs, git_dir)
  while count < max_count {
    match current {
      None => break
      Some(id) => {
        let obj = db.get(fs, id)
        match obj {
          None => break
          Some(o) => {
            if o.obj_type != @git.ObjectType::Commit {
              raise @git.GitError::InvalidObject("Object is not a commit")
            }
            let info = @git.parse_commit(o.data)
            let entry = parse_log_entry(id, o.data, info.tree)
            // Get parent tree for diff
            let parent_tree : @git.ObjectId? = if info.parents.length() > 0 {
              let parent_obj = db.get(fs, info.parents[0])
              match parent_obj {
                Some(po) => {
                  let parent_info = @git.parse_commit(po.data)
                  Some(parent_info.tree)
                }
                None => None
              }
            } else {
              None
            }
            // Filter by since/until
            if entry.timestamp < since {
              // Older than since, stop traversal
              break
            }
            if entry.timestamp <= until {
              result.push(
                {
                  ..entry,
                  parent_tree,
                },
              )
              count += 1
            }
            current = if info.parents.length() > 0 {
              Some(info.parents[0])
            } else {
              None
            }
          }
        }
      }
    }
  }
  result
}

///|
/// Format like `git log --oneline`.
pub fn log_head_oneline(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  max_count? : Int = 100,
  since? : Int64 = 0L,
  until? : Int64 = 9223372036854775807L,
) -> Array[String] raise @git.GitError {
  let entries = log_head(fs, git_dir, max_count~, since~, until~)
  let lines : Array[String] = []
  for e in entries {
    let short = log_shorten_hex(e.id.to_hex(), 7)
    lines.push("\{short} \{e.message}")
  }
  lines
}

///|
fn parse_log_entry(
  id : @git.ObjectId,
  data : Bytes,
  tree : @git.ObjectId,
) -> LogEntry {
  let text = @utf8.decode_lossy(data[:])
  let lines = text.split("\n")
  let mut author = ""
  let mut timestamp = 0L
  let mut in_message = false
  let message_lines : Array[String] = []
  for line_view in lines {
    let line = line_view.to_string()
    if in_message {
      message_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
      continue
    }
    if line.has_prefix("author ") {
      let rest = String::unsafe_substring(line, start=7, end=line.length())
      let (name, time) = parse_author_line(rest)
      author = name
      timestamp = time
    }
  }
  let message = if message_lines.length() > 0 { message_lines[0] } else { "" }
  { id, message, author, timestamp, tree, parent_tree: None }
}

///|
fn parse_author_line(line : String) -> (String, Int64) {
  // format: Name <email> 1700000000 +0000
  let mut last_space = line.rev_find(" ")
  if last_space is None {
    return (line, 0L)
  }
  let tz_idx = last_space.unwrap()
  let before_tz = String::unsafe_substring(line, start=0, end=tz_idx)
  last_space = before_tz.rev_find(" ")
  if last_space is None {
    return (before_tz, 0L)
  }
  let time_idx = last_space.unwrap()
  let name = String::unsafe_substring(before_tz, start=0, end=time_idx)
  let time_str = String::unsafe_substring(
    before_tz,
    start=time_idx + 1,
    end=before_tz.length(),
  )
  let ts = parse_int64(time_str)
  (name, ts)
}

///|
fn parse_int64(s : String) -> Int64 {
  let mut result = 0L
  for c in s {
    if c < '0' || c > '9' {
      continue
    }
    let digit = c.to_int() - '0'.to_int()
    result = result * 10L + digit.to_int64()
  }
  result
}

///|
fn log_shorten_hex(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
}
