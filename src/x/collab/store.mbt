///| Collab notes storage (git notes + kv-friendly)

///|
let collab_notes_ns : String = "bit-collab"

///|
let collab_notes_ref : String = "refs/notes/" + collab_notes_ns

///|
pub fn collab_notes_ref_name() -> String {
  collab_notes_ref
}

///|
pub fn collab_notes_ns_name() -> String {
  collab_notes_ns
}

///|
pub fn pr_meta_key(pr_id : String) -> String {
  "collab/pr/" + pr_id + "/meta"
}

///|
pub fn pr_comment_prefix(pr_id : String) -> String {
  "collab/pr/" + pr_id + "/comment/"
}

///|
pub fn pr_comment_key(pr_id : String, comment_id : String) -> String {
  pr_comment_prefix(pr_id) + comment_id
}

///|
pub fn pr_review_prefix(pr_id : String) -> String {
  "collab/pr/" + pr_id + "/review/"
}

///|
pub fn pr_review_key(pr_id : String, review_id : String) -> String {
  pr_review_prefix(pr_id) + review_id
}

///|
pub fn issue_meta_key(issue_id : String) -> String {
  "collab/issue/" + issue_id + "/meta"
}

///|
pub fn issue_comment_prefix(issue_id : String) -> String {
  "collab/issue/" + issue_id + "/comment/"
}

///|
pub fn issue_comment_key(issue_id : String, comment_id : String) -> String {
  issue_comment_prefix(issue_id) + comment_id
}

///|
pub struct CollabRecord {
  key : String
  kind : String
  clock : Map[String, Int64]
  timestamp : Int64
  node : String
  deleted : Bool
  payload : String
}

///|
pub fn CollabRecord::new(
  key : String,
  kind : String,
  payload : String,
  node : String,
  timestamp : Int64,
  clock? : Map[String, Int64] = {},
  deleted? : Bool = false,
) -> CollabRecord {
  { key, kind, clock, timestamp, node, deleted, payload }
}

///|
pub fn CollabRecord::serialize(self : CollabRecord) -> String {
  let sb = StringBuilder::new()
  sb.write_string("key ")
  sb.write_string(self.key)
  sb.write_char('\n')
  sb.write_string("kind ")
  sb.write_string(self.kind)
  sb.write_char('\n')
  sb.write_string("clock ")
  sb.write_string(clock_to_string(self.clock))
  sb.write_char('\n')
  sb.write_string("timestamp ")
  sb.write_string(self.timestamp.to_string())
  sb.write_char('\n')
  sb.write_string("node ")
  sb.write_string(self.node)
  sb.write_char('\n')
  sb.write_string("deleted ")
  sb.write_string(if self.deleted { "1" } else { "0" })
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(self.payload)
  sb.to_string()
}

///|
pub fn parse_collab_record(text : String) -> CollabRecord {
  let mut key = ""
  let mut kind = ""
  let mut clock = {}
  let mut timestamp : Int64 = 0
  let mut node = ""
  let mut deleted = false
  let payload_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      payload_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let k = String::unsafe_substring(line, start=0, end=idx)
        let v = String::unsafe_substring(line, start=idx + 1, end=line.length())
        match k {
          "key" => key = v
          "kind" => kind = v
          "clock" => clock = parse_clock(v)
          "timestamp" => timestamp = parse_int64(v)
          "node" => node = v
          "deleted" => deleted = v == "1" || v == "true" || v == "yes"
          _ => ()
        }
      }
    }
  }
  CollabRecord::new(
    key,
    kind,
    payload_lines.join("\n"),
    node,
    timestamp,
    clock~,
    deleted~,
  )
}

///|
fn parse_clock(s : String) -> Map[String, Int64] {
  let result : Map[String, Int64] = {}
  if s.length() == 0 {
    return result
  }
  for part_view in s.split(",") {
    let part = part_view.to_string()
    if part.length() == 0 {
      continue
    }
    let eq = part.find("=")
    match eq {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(part, start=0, end=idx)
        let value = String::unsafe_substring(
          part,
          start=idx + 1,
          end=part.length(),
        )
        let parsed = parse_int64(value)
        result[key] = parsed
      }
    }
  }
  result
}

///|
fn clock_to_string(clock : Map[String, Int64]) -> String {
  if clock.length() == 0 {
    return ""
  }
  let items = clock.to_array()
  items.sort_by(fn(a, b) { String::compare(a.0, b.0) })
  let parts : Array[String] = []
  for item in items {
    let (key, value) = item
    parts.push(key + "=" + value.to_string())
  }
  parts.join(",")
}

///|
fn compare_clock(a : Map[String, Int64], b : Map[String, Int64]) -> Int {
  let keys : Map[String, Bool] = {}
  for item in a.to_array() {
    let (key, _) = item
    keys[key] = true
  }
  for item in b.to_array() {
    let (key, _) = item
    keys[key] = true
  }
  let mut a_gt = false
  let mut b_gt = false
  for item in keys.to_array() {
    let (key, _) = item
    let va = match a.get(key) {
      Some(v) => v
      None => 0
    }
    let vb = match b.get(key) {
      Some(v) => v
      None => 0
    }
    if va > vb {
      a_gt = true
    } else if vb > va {
      b_gt = true
    }
  }
  if a_gt && not(b_gt) {
    1
  } else if b_gt && not(a_gt) {
    -1
  } else {
    0
  }
}

///|
fn record_is_newer(a : CollabRecord, b : CollabRecord) -> Bool {
  let cmp = compare_clock(a.clock, b.clock)
  if cmp > 0 {
    return true
  }
  if cmp < 0 {
    return false
  }
  if a.timestamp != b.timestamp {
    return a.timestamp > b.timestamp
  }
  String::compare(a.node, b.node) >= 0
}

///|
fn is_valid_record(record : CollabRecord) -> Bool {
  record.key.length() > 0 && record.kind.length() > 0
}

///|
pub fn merge_record_bytes(ours : Bytes, theirs : Bytes) -> Bytes {
  let ours_text = @utf8.decode_lossy(ours[:])
  let theirs_text = @utf8.decode_lossy(theirs[:])
  let ours_record = parse_collab_record(ours_text)
  let theirs_record = parse_collab_record(theirs_text)
  if not(is_valid_record(ours_record)) && is_valid_record(theirs_record) {
    return theirs
  }
  if not(is_valid_record(theirs_record)) {
    return ours
  }
  let winner = if record_is_newer(theirs_record, ours_record) {
    theirs_record
  } else {
    ours_record
  }
  @utf8.encode(winner.serialize())
}

///|
pub struct CollabStore {
  git_dir : String
  node_id : String
  kv : @kv.Kv
}

///|
pub fn CollabStore::load(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  node_id? : String = "local",
) -> CollabStore raise @git.GitError {
  let node = node_id
  let kv_node = @kv.NodeId::new(node)
  let commit = @lib.resolve_ref(backing_fs, git_dir, collab_notes_ref)
  let kv = match commit {
    Some(cid) => {
      let bitfs = @fs.Fs::from_commit(backing_fs, git_dir, cid)
      @kv.Kv::new(kv_node, bitfs, cid)
    }
    None => @kv.Kv::empty(kv_node, git_dir)
  }
  { git_dir, node_id: node, kv }
}

///|
pub fn CollabStore::node_id(self : CollabStore) -> String {
  self.node_id
}

///|
pub fn CollabStore::get_record(
  self : CollabStore,
  backing_fs : &@git.RepoFileSystem,
  key : String,
) -> CollabRecord? {
  let target_id = key_to_target_id(key)
  let value = self.kv.get(backing_fs, target_id.to_hex())
  match value {
    None => None
    Some(bytes) => {
      let text = @utf8.decode_lossy(bytes[:])
      let record = parse_collab_record(text)
      if record.deleted {
        None
      } else {
        Some(record)
      }
    }
  }
}

///|
pub fn CollabStore::put_record(
  self : CollabStore,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  key : String,
  kind : String,
  payload : String,
  node : String,
  timestamp : Int64,
) -> CollabRecord raise @git.GitError {
  let existing = self.get_record(backing_fs, key)
  let base_clock = match existing {
    Some(r) => r.clock
    None => {}
  }
  let next_clock = increment_clock(base_clock, node)
  let record = CollabRecord::new(
    key,
    kind,
    payload,
    node,
    timestamp,
    clock=next_clock,
    deleted=false,
  )
  let target_id = ensure_key_object(fs, self.git_dir, key)
  let record_text = record.serialize()
  self.kv.set(target_id.to_hex(), @utf8.encode(record_text))
  let _ = commit_notes(self, fs, backing_fs, "Update " + kind, timestamp)
  record
}

///|
pub fn CollabStore::delete_record(
  self : CollabStore,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  key : String,
  kind : String,
  node : String,
  timestamp : Int64,
) -> CollabRecord raise @git.GitError {
  let existing = self.get_record(backing_fs, key)
  let base_clock = match existing {
    Some(r) => r.clock
    None => {}
  }
  let next_clock = increment_clock(base_clock, node)
  let record = CollabRecord::new(
    key,
    kind,
    "",
    node,
    timestamp,
    clock=next_clock,
    deleted=true,
  )
  let target_id = ensure_key_object(fs, self.git_dir, key)
  let record_text = record.serialize()
  self.kv.set(target_id.to_hex(), @utf8.encode(record_text))
  let _ = commit_notes(self, fs, backing_fs, "Delete " + kind, timestamp)
  record
}

///|
pub fn CollabStore::list_records(
  self : CollabStore,
  backing_fs : &@git.RepoFileSystem,
  prefix : String,
  include_deleted? : Bool = false,
) -> Array[CollabRecord] {
  let keys = self.kv.list(backing_fs, "")
  let result : Array[CollabRecord] = []
  let include_deleted_val = include_deleted
  for key in keys {
    let value = self.kv.get(backing_fs, key)
    match value {
      None => ()
      Some(bytes) => {
        let text = @utf8.decode_lossy(bytes[:])
        let record = parse_collab_record(text)
        if not(record.key.has_prefix(prefix)) {
          continue
        }
        if not(include_deleted_val) && record.deleted {
          continue
        }
        result.push(record)
      }
    }
  }
  result
}

///|
fn increment_clock(
  clock : Map[String, Int64],
  node : String,
) -> Map[String, Int64] {
  let next = clock
  let current = match next.get(node) {
    Some(v) => v
    None => 0
  }
  next[node] = current + 1
  next
}

///|
fn key_to_target_id(key : String) -> @git.ObjectId {
  let (id, _compressed) = @git.create_blob_string(key)
  id
}

///|
fn ensure_key_object(
  fs : &@git.FileSystem,
  git_dir : String,
  key : String,
) -> @git.ObjectId raise @git.GitError {
  let (id, compressed) = @git.create_blob_string(key)
  write_object_bytes(fs, git_dir, id, compressed)
  id
}

///|
fn commit_notes(
  store : CollabStore,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  message : String,
  timestamp : Int64,
) -> @git.ObjectId raise @git.GitError {
  let commit_id = store.kv.commit(fs, backing_fs, message, timestamp)
  let notes_dir = join_path(store.git_dir, "refs/notes")
  fs.mkdir_p(notes_dir)
  fs.write_string(
    join_path(store.git_dir, collab_notes_ref),
    commit_id.to_hex() + "\n",
  )
  commit_id
}
