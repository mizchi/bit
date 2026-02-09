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
pub fn Hub::import_prs(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  prs : Array[PullRequest],
) -> ImportStats raise @git.GitError {
  if prs.length() == 0 {
    return ImportStats::new(0, 0)
  }
  let mut created = 0
  let mut updated = 0
  for pr in prs {
    let existing = self.store.get_record(objects, pr_meta_key(pr.id()))
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
        objects,
        refs,
        clock,
        pr_meta_key(pr.id()),
        "pr",
        pr.serialize(),
        pr.author(),
      ),
    )
  }
  ImportStats::new(created, updated)
}

///|
pub fn Hub::import_pr_proposals(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  prs : Array[PullRequest],
) -> ImportStats raise @git.GitError {
  if prs.length() == 0 {
    return ImportStats::new(0, 0)
  }
  let mut created = 0
  let mut updated = 0
  for pr in prs {
    let key = pr_proposal_meta_key(pr.id())
    let existing = self.store.get_record(objects, key)
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
        objects,
        refs,
        clock,
        key,
        "pr-proposal",
        pr.serialize(),
        pr.author(),
      ),
    )
  }
  ImportStats::new(created, updated)
}

///|
pub fn Hub::import_issues(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  issues : Array[Issue],
) -> ImportStats raise @git.GitError {
  if issues.length() == 0 {
    return ImportStats::new(0, 0)
  }
  let mut created = 0
  let mut updated = 0
  for issue in issues {
    let existing = self.store.get_record(objects, issue_meta_key(issue.id()))
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
        objects,
        refs,
        clock,
        issue_meta_key(issue.id()),
        "issue",
        issue.serialize(),
        issue.author(),
      ),
    )
  }
  ImportStats::new(created, updated)
}
