///| PR Merge operations

///|
pub(all) enum PrMergeStrategy {
  Merge // Create merge commit
  Squash // Squash all commits
  FastForward // Fast-forward if possible
}

///|
pub struct PrMergeResult {
  success : Bool
  commit_id : @git.ObjectId?
  conflicts : Array[String]
  message : String
}

///|
pub fn PrMergeResult::success(self : PrMergeResult) -> Bool {
  self.success
}

///|
pub fn PrMergeResult::commit_id(self : PrMergeResult) -> @git.ObjectId? {
  self.commit_id
}

///|
pub fn PrMergeResult::conflicts(self : PrMergeResult) -> Array[String] {
  self.conflicts
}

///|
pub fn PrMergeResult::message(self : PrMergeResult) -> String {
  self.message
}

///|
/// Check if a PR can be merged (no conflicts, PR is open)
pub fn Collab::can_merge(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
) -> Bool raise @git.GitError {
  let pr = self.get_pr(backing_fs, pr_id)
  guard pr is Some(existing) else { return false }
  if existing.state != PrState::Open {
    return false
  }
  // Check if source commit is reachable and target exists
  let source_commit = @lib.resolve_ref(
    backing_fs,
    self.git_dir,
    existing.source_branch,
  )
  let target_commit = @lib.resolve_ref(
    backing_fs,
    self.git_dir,
    existing.target_branch,
  )
  guard source_commit is Some(_) else { return false }
  guard target_commit is Some(_) else { return false }
  true
}

///|
/// Merge a Pull Request
pub fn Collab::merge_pr(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  merger : String,
  timestamp : Int64,
  strategy? : PrMergeStrategy = PrMergeStrategy::Merge,
) -> PrMergeResult raise @git.GitError {
  // Get and validate PR
  let pr = self.get_pr(backing_fs, pr_id)
  guard pr is Some(existing) else {
    return {
      success: false,
      commit_id: None,
      conflicts: [],
      message: "PR not found: \{pr_id}",
    }
  }
  if existing.state != PrState::Open {
    return {
      success: false,
      commit_id: None,
      conflicts: [],
      message: "PR is not open: \{pr_id}",
    }
  }
  // Resolve current commits
  let source_commit = @lib.resolve_ref(
    backing_fs,
    self.git_dir,
    existing.source_branch,
  )
  guard source_commit is Some(source_id) else {
    return {
      success: false,
      commit_id: None,
      conflicts: [],
      message: "Source branch not found: \{existing.source_branch}",
    }
  }
  let target_commit = @lib.resolve_ref(
    backing_fs,
    self.git_dir,
    existing.target_branch,
  )
  guard target_commit is Some(target_id) else {
    return {
      success: false,
      commit_id: None,
      conflicts: [],
      message: "Target branch not found: \{existing.target_branch}",
    }
  }
  // Create merge message
  let merge_message = "Merge PR #\{pr_id}: \{existing.title}\n\nMerged-by: \{merger}\n"
  // Use lib.merge to perform the actual merge
  let db = @lib.ObjectDb::load(backing_fs, self.git_dir)
  // Check for fast-forward possibility
  if is_ancestor(db, backing_fs, target_id, source_id) {
    // Fast-forward is possible
    match strategy {
      FastForward => {
        // Update target branch to point to source
        update_branch_ref(fs, self.git_dir, existing.target_branch, source_id)
        // Mark PR as merged
        mark_pr_merged(
          self, fs, backing_fs, pr_id, existing, source_id, timestamp,
        )
        return {
          success: true,
          commit_id: Some(source_id),
          conflicts: [],
          message: "Fast-forward merge completed",
        }
      }
      Merge => {
        // Create merge commit even if fast-forward is possible
        let source_tree = get_commit_tree_id(db, backing_fs, source_id)
        guard source_tree is Some(tree_id) else {
          return {
            success: false,
            commit_id: None,
            conflicts: [],
            message: "Cannot read source tree",
          }
        }
        let commit = @git.Commit::new(
          tree_id,
          [target_id, source_id],
          merger,
          timestamp,
          "+0000",
          merger,
          timestamp,
          "+0000",
          merge_message,
        )
        let (commit_id, commit_compressed) = @git.create_commit(commit)
        write_object_bytes(fs, self.git_dir, commit_id, commit_compressed)
        update_branch_ref(fs, self.git_dir, existing.target_branch, commit_id)
        mark_pr_merged(
          self, fs, backing_fs, pr_id, existing, commit_id, timestamp,
        )
        return {
          success: true,
          commit_id: Some(commit_id),
          conflicts: [],
          message: "Merge commit created",
        }
      }
      Squash => {
        // Create squash commit (single parent, all changes combined)
        let source_tree = get_commit_tree_id(db, backing_fs, source_id)
        guard source_tree is Some(tree_id) else {
          return {
            success: false,
            commit_id: None,
            conflicts: [],
            message: "Cannot read source tree",
          }
        }
        let squash_message = "Squash PR #\{pr_id}: \{existing.title}\n\nSquashed-by: \{merger}\n"
        let commit = @git.Commit::new(
          tree_id,
          [target_id], // Single parent for squash
          merger,
          timestamp,
          "+0000",
          merger,
          timestamp,
          "+0000",
          squash_message,
        )
        let (commit_id, commit_compressed) = @git.create_commit(commit)
        write_object_bytes(fs, self.git_dir, commit_id, commit_compressed)
        update_branch_ref(fs, self.git_dir, existing.target_branch, commit_id)
        mark_pr_merged(
          self, fs, backing_fs, pr_id, existing, commit_id, timestamp,
        )
        return {
          success: true,
          commit_id: Some(commit_id),
          conflicts: [],
          message: "Squash merge completed",
        }
      }
    }
  }
  // Check if already up to date
  if is_ancestor(db, backing_fs, source_id, target_id) {
    return {
      success: false,
      commit_id: None,
      conflicts: [],
      message: "Already up to date",
    }
  }
  // Find merge base
  let base = find_merge_base(db, backing_fs, target_id, source_id)
  // Collect files from each tree
  let base_files = match base {
    None => {}
    Some(id) => collect_files_from_commit(db, backing_fs, id)
  }
  let target_files = collect_files_from_commit(db, backing_fs, target_id)
  let source_files = collect_files_from_commit(db, backing_fs, source_id)
  // Perform three-way merge
  let (merged_files, conflicts) = three_way_merge(
    base_files, target_files, source_files,
  )
  if conflicts.length() > 0 {
    return {
      success: false,
      commit_id: None,
      conflicts,
      message: "Merge conflicts detected",
    }
  }
  // Create merged tree
  let tree_id = create_tree_from_files(fs, self.git_dir, merged_files)
  // Create merge commit
  let parents = match strategy {
    Squash => [target_id]
    _ => [target_id, source_id]
  }
  let commit = @git.Commit::new(
    tree_id, parents, merger, timestamp, "+0000", merger, timestamp, "+0000", merge_message,
  )
  let (commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, self.git_dir, commit_id, commit_compressed)
  // Update target branch
  update_branch_ref(fs, self.git_dir, existing.target_branch, commit_id)
  // Mark PR as merged
  mark_pr_merged(self, fs, backing_fs, pr_id, existing, commit_id, timestamp)
  {
    success: true,
    commit_id: Some(commit_id),
    conflicts: [],
    message: "Merge completed",
  }
}

///|
fn get_commit_tree_id(
  db : @lib.ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(fs, commit_id)
  guard obj is Some(commit_obj) else { return None }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return None
  }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|
fn is_ancestor(
  db : @lib.ObjectDb,
  fs : &@git.RepoFileSystem,
  ancestor : @git.ObjectId,
  commit_id : @git.ObjectId,
) -> Bool raise @git.GitError {
  if ancestor == commit_id {
    return true
  }
  let stack : Array[@git.ObjectId] = [commit_id]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = stack.pop()
    guard id is Some(current) else { break }
    let hex = current.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if current == ancestor {
      return true
    }
    let obj = db.get(fs, current)
    guard obj is Some(commit_obj) else { continue }
    if commit_obj.obj_type != @git.ObjectType::Commit {
      continue
    }
    let info = @git.parse_commit(commit_obj.data)
    for parent in info.parents {
      stack.push(parent)
    }
  }
  false
}

///|
fn find_merge_base(
  db : @lib.ObjectDb,
  fs : &@git.RepoFileSystem,
  a : @git.ObjectId,
  b : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  // Collect all ancestors of 'a'
  let seen_a : Map[String, Bool] = {}
  let stack_a : Array[@git.ObjectId] = [a]
  while stack_a.length() > 0 {
    let id = stack_a.pop()
    guard id is Some(current) else { break }
    let hex = current.to_hex()
    if seen_a.contains(hex) {
      continue
    }
    seen_a[hex] = true
    let obj = db.get(fs, current)
    guard obj is Some(commit_obj) else { continue }
    if commit_obj.obj_type != @git.ObjectType::Commit {
      continue
    }
    let info = @git.parse_commit(commit_obj.data)
    for parent in info.parents {
      stack_a.push(parent)
    }
  }
  // Find first ancestor of 'b' that's also an ancestor of 'a'
  let stack_b : Array[@git.ObjectId] = [b]
  while stack_b.length() > 0 {
    let id = stack_b.pop()
    guard id is Some(current) else { break }
    let hex = current.to_hex()
    if seen_a.contains(hex) {
      return Some(current)
    }
    let obj = db.get(fs, current)
    guard obj is Some(commit_obj) else { continue }
    if commit_obj.obj_type != @git.ObjectType::Commit {
      continue
    }
    let info = @git.parse_commit(commit_obj.data)
    for parent in info.parents {
      stack_b.push(parent)
    }
  }
  None
}

///|
priv struct FileEntry {
  id : @git.ObjectId
  mode : String
}

///|
fn collect_files_from_commit(
  db : @lib.ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> Map[String, FileEntry] raise @git.GitError {
  let result : Map[String, FileEntry] = {}
  let obj = db.get(fs, commit_id)
  guard obj is Some(commit_obj) else { return result }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return result
  }
  let info = @git.parse_commit(commit_obj.data)
  collect_tree_files(db, fs, info.tree, "", result)
  result
}

///|
fn collect_tree_files(
  db : @lib.ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  out : Map[String, FileEntry],
) -> Unit raise @git.GitError {
  let obj = db.get(fs, tree_id)
  guard obj is Some(tree_obj) else { return () }
  if tree_obj.obj_type != @git.ObjectType::Tree {
    return ()
  }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    let path = if prefix.length() == 0 {
      entry.name
    } else {
      prefix + "/" + entry.name
    }
    if entry.mode.has_prefix("04") {
      // Directory
      collect_tree_files(db, fs, entry.id, path, out)
    } else {
      // File
      out[path] = { id: entry.id, mode: entry.mode }
    }
  }
}

///|
fn three_way_merge(
  base : Map[String, FileEntry],
  ours : Map[String, FileEntry],
  theirs : Map[String, FileEntry],
) -> (Map[String, FileEntry], Array[String]) {
  let merged : Map[String, FileEntry] = {}
  let conflicts : Array[String] = []
  // Collect all paths
  let all_paths : Map[String, Bool] = {}
  for item in base.to_array() {
    let (path, _) = item
    all_paths[path] = true
  }
  for item in ours.to_array() {
    let (path, _) = item
    all_paths[path] = true
  }
  for item in theirs.to_array() {
    let (path, _) = item
    all_paths[path] = true
  }
  for item in all_paths.to_array() {
    let (path, _) = item
    let b = base.get(path)
    let o = ours.get(path)
    let t = theirs.get(path)
    if entry_eq(o, t) {
      // Both sides are the same
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if entry_eq(o, b) {
      // Ours unchanged, take theirs
      match t {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if entry_eq(t, b) {
      // Theirs unchanged, take ours
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else {
      // Conflict
      conflicts.push(path)
    }
  }
  (merged, conflicts)
}

///|
fn entry_eq(a : FileEntry?, b : FileEntry?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x.id == y.id && x.mode == y.mode
    _ => false
  }
}

///|
fn create_tree_from_files(
  fs : &@git.FileSystem,
  git_dir : String,
  files : Map[String, FileEntry],
) -> @git.ObjectId raise @git.GitError {
  // Build tree structure
  let tree_map : Map[String, Array[(String, FileEntry)]] = {}
  for item in files.to_array() {
    let (path, entry) = item
    let slash = path.rev_find("/")
    let (dir, name) = match slash {
      None => ("", path)
      Some(idx) =>
        (
          String::unsafe_substring(path, start=0, end=idx),
          String::unsafe_substring(path, start=idx + 1, end=path.length()),
        )
    }
    if not(tree_map.contains(dir)) {
      tree_map[dir] = []
    }
    let arr = tree_map.get(dir)
    match arr {
      Some(a) => a.push((name, entry))
      None => ()
    }
  }
  // Build trees bottom-up
  let tree_ids : Map[String, @git.ObjectId] = {}
  // Get all directories sorted by depth (deepest first)
  let dirs = tree_map.keys().to_array()
  dirs.sort_by(fn(a, b) {
    let a_depth = count_slashes(a)
    let b_depth = count_slashes(b)
    b_depth - a_depth // Deepest first
  })
  for dir in dirs {
    let entries_arr = tree_map.get(dir)
    guard entries_arr is Some(file_entries) else { continue }
    let tree_entries : Array[@git.TreeEntry] = []
    // Add file entries
    for item in file_entries {
      let (name, entry) = item
      tree_entries.push(@git.TreeEntry::new(entry.mode, name, entry.id))
    }
    // Add subdirectory entries
    for item in tree_ids.to_array() {
      let (subdir, id) = item
      let parent_dir = get_parent_dir(subdir)
      if parent_dir == dir {
        let name = get_base_name(subdir)
        tree_entries.push(@git.TreeEntry::new("040000", name, id))
      }
    }
    tree_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
    let (tree_id, compressed) = @git.create_tree(tree_entries)
    write_object_bytes(fs, git_dir, tree_id, compressed)
    tree_ids[dir] = tree_id
  }
  // Return root tree
  tree_ids.get("") |> Option::unwrap()
}

///|
fn count_slashes(s : String) -> Int {
  let mut count = 0
  for c in s {
    if c == '/' {
      count = count + 1
    }
  }
  count
}

///|
fn get_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => ""
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
  }
}

///|
fn get_base_name(path : String) -> String {
  match path.rev_find("/") {
    None => path
    Some(idx) =>
      String::unsafe_substring(path, start=idx + 1, end=path.length())
  }
}

///|
fn update_branch_ref(
  fs : &@git.FileSystem,
  git_dir : String,
  branch : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let ref_path = if branch.has_prefix("refs/") {
    join_path(git_dir, branch)
  } else {
    join_path(git_dir, "refs/heads/" + branch)
  }
  let dir = get_parent_dir(ref_path)
  fs.mkdir_p(dir)
  fs.write_string(ref_path, commit_id.to_hex() + "\n")
}

///|
fn mark_pr_merged(
  prs : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  existing : PullRequest,
  merge_commit : @git.ObjectId,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  // Create updated PR with Merged state
  let updated = PullRequest::new(
    existing.id,
    existing.title,
    existing.body,
    existing.source_branch,
    merge_commit, // Update source_commit to merge commit
    existing.target_branch,
    existing.target_commit,
    existing.author,
    existing.created_at,
    timestamp,
    PrState::Merged,
    existing.labels,
  )
  ignore(
    prs.store.put_record(
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
