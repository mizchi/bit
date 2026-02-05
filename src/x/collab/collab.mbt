///| Collab - Git-native collaboration system (Pull Requests, Issues)

///|
/// Collab manages Pull Requests and Issues stored in git notes
pub struct Collab {
  git_dir : String
  mut store : CollabStore
}

///|
/// Load an existing Collab from git notes
pub fn Collab::load(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  node_id? : String = "local",
) -> Collab raise @git.GitError {
  let store = CollabStore::load(backing_fs, git_dir, node_id~)
  { git_dir, store }
}

///|
/// Initialize a new Collab
pub fn Collab::init(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  node_id? : String = "local",
) -> Collab raise @git.GitError {
  ignore(fs)
  Collab::load(backing_fs, git_dir, node_id~)
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
  // Generate PR ID (stable, content-derived)
  let pr_id = generate_entity_id(
    "pr",
    author,
    timestamp,
    source_branch + "\n" + target_branch + "\n" + title + "\n" + body,
  )
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
  ignore(
    self.store.put_record(
      fs,
      backing_fs,
      pr_meta_key(pr_id),
      "pr",
      pr.serialize(),
      author,
      timestamp,
    ),
  )
  pr
}

///|
/// Get a Pull Request by ID
pub fn Collab::get_pr(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
) -> PullRequest? {
  let record = self.store.get_record(backing_fs, pr_meta_key(pr_id))
  match record {
    None => None
    Some(r) => {
      let result : Result[PullRequest, PrError] = try? parse_pull_request(
        r.payload,
      )
      match result {
        Ok(pr) => Some(pr)
        Err(_) => None
      }
    }
  }
}

///|
/// List Pull Requests, optionally filtered by state
pub fn Collab::list_prs(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  state? : PrState? = None,
) -> Array[PullRequest] {
  let result : Array[PullRequest] = []
  let records = self.store.list_records(backing_fs, "collab/pr/")
  for record in records {
    if not(record.key.has_suffix("/meta")) || record.kind != "pr" {
      continue
    }
    let pr = parse_pull_request(record.payload) catch { _ => continue }
    match state {
      None => result.push(pr)
      Some(s) => if pr.state == s { result.push(pr) }
    }
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
  ignore(
    self.store.put_record(
      fs,
      backing_fs,
      pr_meta_key(pr_id),
      "pr",
      updated.serialize(),
      existing.author,
      timestamp,
    ),
  )
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
  ignore(
    self.store.put_record(
      fs,
      backing_fs,
      pr_meta_key(pr_id),
      "pr",
      updated.serialize(),
      existing.author,
      timestamp,
    ),
  )
}

///|
fn generate_entity_id(
  kind : String,
  author : String,
  timestamp : Int64,
  seed : String,
) -> String {
  let base = kind + "\n" + author + "\n" + timestamp.to_string() + "\n" + seed
  let (id, _compressed) = @git.create_blob_string(base)
  short_hex_id(id.to_hex(), 8)
}

///|
fn short_hex_id(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
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
