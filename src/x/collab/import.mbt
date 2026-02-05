///| Import/upsert helpers for external PRs and Issues

///|
pub struct ImportStats {
  created : Int
  updated : Int
}

///|
pub fn ImportStats::new(created : Int, updated : Int) -> ImportStats {
  { created, updated }
}

///|
pub fn ImportStats::created(self : ImportStats) -> Int {
  self.created
}

///|
pub fn ImportStats::updated(self : ImportStats) -> Int {
  self.updated
}

///|
pub fn Collab::import_prs(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  prs : Array[PullRequest],
) -> ImportStats raise @git.GitError {
  if prs.length() == 0 {
    return ImportStats::new(0, 0)
  }
  let mut created = 0
  let mut updated = 0
  for pr in prs {
    let existing = self.store.get_record(backing_fs, pr_meta_key(pr.id()))
    match existing {
      Some(r) =>
        if r.timestamp >= pr.updated_at {
          continue
        } else {
          updated += 1
        }
      None => created += 1
    }
    ignore(
      self.store.put_record(
        fs,
        backing_fs,
        pr_meta_key(pr.id()),
        "pr",
        pr.serialize(),
        pr.author(),
        pr.updated_at,
      ),
    )
  }
  ImportStats::new(created, updated)
}

///|
pub fn Collab::import_issues(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issues : Array[Issue],
) -> ImportStats raise @git.GitError {
  if issues.length() == 0 {
    return ImportStats::new(0, 0)
  }
  let mut created = 0
  let mut updated = 0
  for issue in issues {
    let existing = self.store.get_record(backing_fs, issue_meta_key(issue.id()))
    match existing {
      Some(r) =>
        if r.timestamp >= issue.updated_at {
          continue
        } else {
          updated += 1
        }
      None => created += 1
    }
    ignore(
      self.store.put_record(
        fs,
        backing_fs,
        issue_meta_key(issue.id()),
        "issue",
        issue.serialize(),
        issue.author(),
        issue.updated_at,
      ),
    )
  }
  ImportStats::new(created, updated)
}
