///| Merge strategies for Kv

///|

///| When two nodes have concurrent changes, we need a merge strategy.

///| Default is Last-Write-Wins (LWW) based on vector clock + timestamp.

///|
/// Merge result
pub(all) enum MergeResult {
  /// No changes needed
  NoOp
  /// Fast-forward to their HEAD
  FastForward(@git.ObjectId)
  /// Merged with new commit
  Merged(@git.ObjectId, Array[String]) // new_head, conflict_paths
  /// Conflict that couldn't be auto-resolved
  Conflict(Array[String])
}

///|
/// Perform a three-way merge
pub fn Kv::merge(
  self : Kv,
  write_fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  their_head : @git.ObjectId,
  their_clock : VectorClock,
  strategy : MergeStrategy,
  timestamp : Int64,
) -> MergeResult raise @git.GitError {
  // Same head, no merge needed
  if self.head == their_head {
    return NoOp
  }
  // We have no commits, fast-forward to theirs
  if self.head == @git.ObjectId::zero() {
    self.head = their_head
    self.clock = self.clock.merge(their_clock)
    self.bitfs.checkout_snapshot(backing_fs, their_head)
    return FastForward(their_head)
  }
  // They have no commits
  if their_head == @git.ObjectId::zero() {
    return NoOp
  }
  // Find common ancestor
  let db = self.bitfs.get_db(backing_fs)
  let base = find_merge_base(db, backing_fs, self.head, their_head)
  // If their head is ancestor of ours, we're already up to date
  if base is Some(b) && b == their_head {
    return NoOp
  }
  // If our head is ancestor of theirs, fast-forward
  if base is Some(b) && b == self.head {
    self.head = their_head
    self.clock = self.clock.merge(their_clock)
    self.bitfs.checkout_snapshot(backing_fs, their_head)
    return FastForward(their_head)
  }
  // Need to do a real merge
  let conflicts = self.do_merge(
    write_fs,
    backing_fs,
    base.unwrap_or(@git.ObjectId::zero()),
    their_head,
    strategy,
  )
  if conflicts.length() > 0 {
    match strategy {
      LastWriteWins | Custom(_) => {
        // Auto-resolved, create merge commit
        let new_head = self.create_merge_commit(
          write_fs, backing_fs, their_head, timestamp,
        )
        self.clock = self.clock.merge(their_clock).increment(self.node_id)
        Merged(new_head, conflicts)
      }
      KeepBoth => Conflict(conflicts)
    }
  } else {
    // No conflicts, create merge commit
    let new_head = self.create_merge_commit(
      write_fs, backing_fs, their_head, timestamp,
    )
    self.clock = self.clock.merge(their_clock).increment(self.node_id)
    Merged(new_head, [])
  }
}

///|
fn Kv::do_merge(
  self : Kv,
  _write_fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  base : @git.ObjectId,
  their_head : @git.ObjectId,
  strategy : MergeStrategy,
) -> Array[String] {
  let conflicts : Array[String] = []
  let db = self.bitfs.get_db(backing_fs) catch { _ => return conflicts }
  // Get trees
  let base_tree = if base == @git.ObjectId::zero() {
    @git.ObjectId::zero()
  } else {
    let obj = db.get(backing_fs, base) catch { _ => return conflicts }
    match obj {
      Some(o) => {
        let commit = @git.parse_commit(o.data) catch { _ => return conflicts }
        commit.tree
      }
      None => @git.ObjectId::zero()
    }
  }
  let their_tree = {
    let obj = db.get(backing_fs, their_head) catch { _ => return conflicts }
    match obj {
      Some(o) => {
        let commit = @git.parse_commit(o.data) catch { _ => return conflicts }
        commit.tree
      }
      None => return conflicts
    }
  }
  // Collect files from each tree
  let base_files : Map[String, @git.ObjectId] = {}
  let their_files : Map[String, @git.ObjectId] = {}
  collect_tree_files_flat(db, backing_fs, base_tree, "", base_files)
  collect_tree_files_flat(db, backing_fs, their_tree, "", their_files)
  // Get our current files
  let our_files = self.bitfs.get_working_files()
  let our_file_set : Map[String, Bool] = {}
  for f in our_files {
    our_file_set[f] = true
  }
  // Find all paths
  let all_paths : Map[String, Bool] = {}
  for entry in base_files {
    all_paths[entry.0] = true
  }
  for entry in their_files {
    all_paths[entry.0] = true
  }
  for f in our_files {
    all_paths[f] = true
  }
  // Process each path
  for entry in all_paths {
    let path = entry.0
    let in_base = base_files.contains(path)
    let in_theirs = their_files.contains(path)
    let in_ours = our_file_set.contains(path) ||
      self.bitfs.is_file(backing_fs, path)
    let base_id = base_files.get(path)
    let their_id = their_files.get(path)
    // Determine if there's a conflict
    if in_theirs && in_ours {
      // Both have the file
      let our_content = self.bitfs.read_file(backing_fs, path) catch {
        _ => continue
      }
      let our_hash = @git.hash_blob(our_content)
      let their_hash = their_id.unwrap_or(@git.ObjectId::zero())
      if our_hash != their_hash {
        // Different content
        if in_base {
          let base_hash = base_id.unwrap_or(@git.ObjectId::zero())
          if base_hash == our_hash {
            // We didn't change, take theirs
            let their_content = get_blob_content(db, backing_fs, their_hash)
            match their_content {
              Some(c) => self.bitfs.write_file(path, c)
              None => ()
            }
          } else if base_hash == their_hash {
            // They didn't change, keep ours
            ()
          } else {
            // Both changed - conflict
            conflicts.push(path)
            resolve_conflict(
              self, db, backing_fs, path, our_content, their_hash, strategy,
            )
          }
        } else {
          // Both added - conflict
          conflicts.push(path)
          resolve_conflict(
            self, db, backing_fs, path, our_content, their_hash, strategy,
          )
        }
      }
    } else if in_theirs && not(in_ours) {
      // They added, we don't have
      if not(in_base) {
        // New file from them
        let their_hash = their_id.unwrap_or(@git.ObjectId::zero())
        let content = get_blob_content(db, backing_fs, their_hash)
        match content {
          Some(c) => self.bitfs.write_file(path, c)
          None => ()
        }
      }
      // If in base but not in ours, we deleted it - keep deleted
    } else if in_ours && not(in_theirs) {
      // We have, they don't
      if in_base {
        // They deleted, we still have
        // Conflict: delete vs modify
        conflicts.push(path)
        // Default: keep ours
      }
      // If not in base, we added it - keep ours
    }
  }
  conflicts
}

///|
fn resolve_conflict(
  db : Kv,
  obj_db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  path : String,
  our_content : Bytes,
  their_hash : @git.ObjectId,
  strategy : MergeStrategy,
) -> Unit {
  match strategy {
    LastWriteWins => {
      // Take theirs (they're "newer" in this context)
      let content = get_blob_content(obj_db, backing_fs, their_hash)
      match content {
        Some(c) => db.bitfs.write_file(path, c)
        None => ()
      }
    }
    KeepBoth => {
      // Create conflict markers
      let their_content = get_blob_content(obj_db, backing_fs, their_hash).unwrap_or(
        Bytes::new(0),
      )
      let merged = create_conflict_markers(our_content, their_content)
      db.bitfs.write_file(path, merged)
    }
    Custom(resolver) => {
      let their_content = get_blob_content(obj_db, backing_fs, their_hash).unwrap_or(
        Bytes::new(0),
      )
      let resolved = resolver(our_content, their_content)
      db.bitfs.write_file(path, resolved)
    }
  }
}

///|
fn get_blob_content(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> Bytes? {
  if id == @git.ObjectId::zero() {
    return None
  }
  let obj = db.get(backing_fs, id) catch { _ => return None }
  match obj {
    Some(o) => Some(o.data)
    None => None
  }
}

///|
fn create_conflict_markers(ours : Bytes, theirs : Bytes) -> Bytes {
  let result : Array[Byte] = []
  let header = b"<<<<<<< OURS\n"
  let separator = b"=======\n"
  let footer = b">>>>>>> THEIRS\n"
  for b in header {
    result.push(b)
  }
  for b in ours {
    result.push(b)
  }
  result.push(b'\n')
  for b in separator {
    result.push(b)
  }
  for b in theirs {
    result.push(b)
  }
  result.push(b'\n')
  for b in footer {
    result.push(b)
  }
  Bytes::from_array(result)
}

///|
fn Kv::create_merge_commit(
  self : Kv,
  write_fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  their_head : @git.ObjectId,
  timestamp : Int64,
) -> @git.ObjectId raise @git.GitError {
  let hex = their_head.to_hex()
  let short_hex = String::unsafe_substring(hex, start=0, end=8)
  let message = "Merge " + short_hex
  // First commit the current working state
  let snapshot = self.bitfs.snapshot(
    write_fs,
    backing_fs,
    message,
    self.node_id.id,
    timestamp,
  )
  // TODO: Create proper merge commit with two parents
  // For now, just use the snapshot commit
  self.head = snapshot.commit_id
  snapshot.commit_id
}

///|
/// Find the merge base (common ancestor) of two commits
fn find_merge_base(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  commit1 : @git.ObjectId,
  commit2 : @git.ObjectId,
) -> @git.ObjectId? {
  if commit1 == @git.ObjectId::zero() || commit2 == @git.ObjectId::zero() {
    return None
  }
  // Collect ancestors of commit1
  let ancestors1 : Map[String, Int] = {} // hex -> depth
  collect_ancestors(db, backing_fs, commit1, 0, ancestors1)
  // Find first common ancestor from commit2
  find_common_ancestor(db, backing_fs, commit2, 0, ancestors1)
}

///|
fn collect_ancestors(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  depth : Int,
  result : Map[String, Int],
) -> Unit {
  if commit_id == @git.ObjectId::zero() {
    return
  }
  let hex = commit_id.to_hex()
  if result.contains(hex) {
    return
  }
  result[hex] = depth
  let obj = db.get(backing_fs, commit_id) catch { _ => return }
  guard obj is Some(o) else { return }
  let commit = @git.parse_commit(o.data) catch { _ => return }
  for parent in commit.parents {
    collect_ancestors(db, backing_fs, parent, depth + 1, result)
  }
}

///|
fn find_common_ancestor(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  _depth : Int,
  ancestors1 : Map[String, Int],
) -> @git.ObjectId? {
  if commit_id == @git.ObjectId::zero() {
    return None
  }
  let hex = commit_id.to_hex()
  if ancestors1.contains(hex) {
    return Some(commit_id)
  }
  let obj = db.get(backing_fs, commit_id) catch { _ => return None }
  guard obj is Some(o) else { return None }
  let commit = @git.parse_commit(o.data) catch { _ => return None }
  for parent in commit.parents {
    let found = find_common_ancestor(
      db,
      backing_fs,
      parent,
      _depth + 1,
      ancestors1,
    )
    if found is Some(_) {
      return found
    }
  }
  None
}

///|
fn collect_tree_files_flat(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  result : Map[String, @git.ObjectId],
) -> Unit {
  if tree_id == @git.ObjectId::zero() {
    return
  }
  let obj = db.get(backing_fs, tree_id) catch { _ => return }
  guard obj is Some(o) else { return }
  let entries = @git.parse_tree(o.data) catch { _ => return }
  for entry in entries {
    let path = if prefix.length() == 0 {
      entry.name
    } else {
      prefix + "/" + entry.name
    }
    if entry.mode == "040000" || entry.mode == "40000" {
      collect_tree_files_flat(db, backing_fs, entry.id, path, result)
    } else {
      result[path] = entry.id
    }
  }
}
