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
pub fn Hub::can_merge(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  pr_id : String,
) -> Bool raise @git.GitError {
  let pr = self.get_pr(objects, pr_id)
  guard pr is Some(existing) else { return false }
  if existing.state != PrState::Open {
    return false
  }
  let source_commit = refs.resolve(existing.source_branch)
  let target_commit = refs.resolve(existing.target_branch)
  guard source_commit is Some(_) else { return false }
  guard target_commit is Some(_) else { return false }
  true
}

///|
/// Merge a Pull Request
pub fn Hub::merge_pr(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  pr_id : String,
  merger : String,
  strategy? : PrMergeStrategy = PrMergeStrategy::Merge,
) -> PrMergeResult raise @git.GitError {
  let timestamp = clock.now()
  // Get and validate PR
  let pr = self.get_pr(objects, pr_id)
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
  // Resolve source commit from source_ref/source_branch, then fallback to stored source_commit
  let source_id = match resolve_pr_source_commit(objects, refs, existing) {
    Ok(id) => id
    Err(message) =>
      return { success: false, commit_id: None, conflicts: [], message }
  }
  let target_commit = refs.resolve(existing.target_branch)
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
  // Check for fast-forward possibility
  if is_ancestor(objects, target_id, source_id) {
    // Fast-forward is possible
    match strategy {
      FastForward => {
        update_branch_ref(refs, existing.target_branch, source_id)
        mark_pr_merged(self, objects, refs, clock, pr_id, existing, source_id)
        return {
          success: true,
          commit_id: Some(source_id),
          conflicts: [],
          message: "Fast-forward merge completed",
        }
      }
      Merge => {
        let source_tree = get_commit_tree_id(objects, source_id)
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
        let commit_bytes = @git.serialize_commit_content(commit)
        let commit_id = objects.put(@git.ObjectType::Commit, commit_bytes)
        update_branch_ref(refs, existing.target_branch, commit_id)
        mark_pr_merged(self, objects, refs, clock, pr_id, existing, commit_id)
        return {
          success: true,
          commit_id: Some(commit_id),
          conflicts: [],
          message: "Merge commit created",
        }
      }
      Squash => {
        let source_tree = get_commit_tree_id(objects, source_id)
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
          [target_id],
          merger,
          timestamp,
          "+0000",
          merger,
          timestamp,
          "+0000",
          squash_message,
        )
        let commit_bytes = @git.serialize_commit_content(commit)
        let commit_id = objects.put(@git.ObjectType::Commit, commit_bytes)
        update_branch_ref(refs, existing.target_branch, commit_id)
        mark_pr_merged(self, objects, refs, clock, pr_id, existing, commit_id)
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
  if is_ancestor(objects, source_id, target_id) {
    return {
      success: false,
      commit_id: None,
      conflicts: [],
      message: "Already up to date",
    }
  }
  // Find merge base
  let base = find_merge_base(objects, target_id, source_id)
  // Collect files from each tree
  let base_files = match base {
    None => {}
    Some(id) => collect_files_from_commit(objects, id)
  }
  let target_files = collect_files_from_commit(objects, target_id)
  let source_files = collect_files_from_commit(objects, source_id)
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
  let tree_id = create_tree_from_files(objects, merged_files)
  // Create merge commit
  let parents = match strategy {
    Squash => [target_id]
    _ => [target_id, source_id]
  }
  let commit = @git.Commit::new(
    tree_id, parents, merger, timestamp, "+0000", merger, timestamp, "+0000", merge_message,
  )
  let commit_bytes = @git.serialize_commit_content(commit)
  let commit_id = objects.put(@git.ObjectType::Commit, commit_bytes)
  // Update target branch
  update_branch_ref(refs, existing.target_branch, commit_id)
  // Mark PR as merged
  mark_pr_merged(self, objects, refs, clock, pr_id, existing, commit_id)
  {
    success: true,
    commit_id: Some(commit_id),
    conflicts: [],
    message: "Merge completed",
  }
}

///|
fn get_commit_tree_id(
  objects : &@lib.ObjectStore,
  commit_id : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let obj = objects.get(commit_id)
  guard obj is Some(commit_obj) else { return None }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return None
  }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|
fn is_ancestor(
  objects : &@lib.ObjectStore,
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
    let obj = objects.get(current)
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
  objects : &@lib.ObjectStore,
  a : @git.ObjectId,
  b : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
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
    let obj = objects.get(current)
    guard obj is Some(commit_obj) else { continue }
    if commit_obj.obj_type != @git.ObjectType::Commit {
      continue
    }
    let info = @git.parse_commit(commit_obj.data)
    for parent in info.parents {
      stack_a.push(parent)
    }
  }
  let stack_b : Array[@git.ObjectId] = [b]
  while stack_b.length() > 0 {
    let id = stack_b.pop()
    guard id is Some(current) else { break }
    let hex = current.to_hex()
    if seen_a.contains(hex) {
      return Some(current)
    }
    let obj = objects.get(current)
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
  objects : &@lib.ObjectStore,
  commit_id : @git.ObjectId,
) -> Map[String, FileEntry] raise @git.GitError {
  let result : Map[String, FileEntry] = {}
  let obj = objects.get(commit_id)
  guard obj is Some(commit_obj) else { return result }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return result
  }
  let info = @git.parse_commit(commit_obj.data)
  collect_tree_files(objects, info.tree, "", result)
  result
}

///|
fn collect_tree_files(
  objects : &@lib.ObjectStore,
  tree_id : @git.ObjectId,
  prefix : String,
  out : Map[String, FileEntry],
) -> Unit raise @git.GitError {
  let obj = objects.get(tree_id)
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
      collect_tree_files(objects, entry.id, path, out)
    } else {
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
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if entry_eq(o, b) {
      match t {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if entry_eq(t, b) {
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else {
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
  objects : &@lib.ObjectStore,
  files : Map[String, FileEntry],
) -> @git.ObjectId raise @git.GitError {
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
  let tree_ids : Map[String, @git.ObjectId] = {}
  let dirs = tree_map.keys().to_array()
  dirs.sort_by(fn(a, b) {
    let a_depth = count_slashes(a)
    let b_depth = count_slashes(b)
    b_depth - a_depth
  })
  for dir in dirs {
    let entries_arr = tree_map.get(dir)
    guard entries_arr is Some(file_entries) else { continue }
    let tree_entries : Array[@git.TreeEntry] = []
    for item in file_entries {
      let (name, entry) = item
      tree_entries.push(@git.TreeEntry::new(entry.mode, name, entry.id))
    }
    for item in tree_ids.to_array() {
      let (subdir, id) = item
      let parent_dir = get_parent_dir(subdir)
      if parent_dir == dir {
        let name = get_base_name(subdir)
        tree_entries.push(@git.TreeEntry::new("040000", name, id))
      }
    }
    tree_entries.sort_by((a, b) => String::compare(a.name, b.name))
    let tree_bytes = @git.serialize_tree(tree_entries)
    let tree_id = objects.put(@git.ObjectType::Tree, tree_bytes)
    tree_ids[dir] = tree_id
  }
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
fn normalize_head_ref(ref_name : String) -> String {
  if ref_name.has_prefix("refs/") {
    ref_name
  } else {
    "refs/heads/" + ref_name
  }
}

///|
fn resolve_ref_with_head_fallback(
  refs : &@lib.RefStore,
  ref_name : String,
) -> @git.ObjectId? raise @git.GitError {
  let direct = refs.resolve(ref_name)
  match direct {
    Some(id) => Some(id)
    None =>
      if ref_name.has_prefix("refs/") {
        None
      } else {
        refs.resolve("refs/heads/" + ref_name)
      }
  }
}

///|
fn source_missing_hint(pr : PullRequest) -> String {
  let source_ref = match pr.source_ref {
    Some(ref_name) => normalize_head_ref(ref_name)
    None => normalize_head_ref(pr.source_branch)
  }
  let commit_hex = pr.source_commit.to_hex()
  match pr.source_repo {
    Some(repo) =>
      "Source commit \{commit_hex} is not available locally. Fetch \{repo} \{source_ref} and retry."
    None =>
      "Source commit \{commit_hex} is not available locally. Fetch \{source_ref} and retry."
  }
}

///|
fn resolve_pr_source_commit(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  pr : PullRequest,
) -> Result[@git.ObjectId, String] raise @git.GitError {
  match pr.source_ref {
    Some(ref_name) => {
      let from_source_ref = resolve_ref_with_head_fallback(refs, ref_name)
      if from_source_ref is Some(id) {
        return Ok(id)
      }
    }
    None => ()
  }
  let from_source_branch = resolve_ref_with_head_fallback(
    refs,
    pr.source_branch,
  )
  if from_source_branch is Some(id) {
    return Ok(id)
  }
  if objects.has(pr.source_commit) {
    return Ok(pr.source_commit)
  }
  Err(source_missing_hint(pr))
}

///|
fn update_branch_ref(
  refs : &@lib.RefStore,
  branch : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let ref_name = if branch.has_prefix("refs/") {
    branch
  } else {
    "refs/heads/" + branch
  }
  refs.update(ref_name, Some(commit_id))
}

///|
fn mark_pr_merged(
  prs : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  pr_id : String,
  existing : PullRequest,
  merge_commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
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
    clock.now(),
    PrState::Merged,
    existing.labels,
    merge_commit=Some(merge_commit_id),
    source_repo=existing.source_repo,
    source_ref=existing.source_ref,
  )
  ignore(
    prs.store.put_record(
      objects,
      refs,
      clock,
      pr_meta_key(pr_id),
      "pr",
      updated.serialize(),
      existing.author,
    ),
  )
}
