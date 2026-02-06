///| Git branch listing (refs/heads + packed-refs)

///|
pub enum HeadRef {
  Branch(String)
  Detached(@git.ObjectId)
}

///|
pub struct BranchInfo {
  name : String
  id : @git.ObjectId
  current : Bool
}

///|
fn resolve_worktree_git_dir(fs : &@git.RepoFileSystem, root : String) -> String {
  let git_path = join_path(root, ".git")
  if fs.is_file(git_path) {
    resolve_gitdir(fs, git_path)
  } else {
    git_path
  }
}

///|
/// Read HEAD and return its reference.
pub fn read_head_ref(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> HeadRef raise @git.GitError {
  let head_path = join_path(git_dir, "HEAD")
  let line = read_ref_line(fs, head_path)
  if line.has_prefix("ref: ") {
    let refname = String::unsafe_substring(line, start=5, end=line.length())
    let name = if refname.has_prefix("refs/heads/") {
      String::unsafe_substring(refname, start=11, end=refname.length())
    } else {
      refname
    }
    HeadRef::Branch(name)
  } else {
    let id = @git.ObjectId::from_hex(line)
    HeadRef::Detached(id)
  }
}

///|
/// List local branches with current flag.
pub fn list_branches(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> (HeadRef, Array[BranchInfo]) raise @git.GitError {
  let head = read_head_ref(fs, git_dir)
  let map : Map[String, @git.ObjectId] = {}
  let heads_dir = join_path(git_dir, "refs/heads")
  if fs.is_dir(heads_dir) {
    collect_loose_heads(fs, heads_dir, "", map)
  }
  let packed_path = join_path(git_dir, "packed-refs")
  if fs.is_file(packed_path) {
    collect_packed_heads(fs, packed_path, map)
  }
  let branches : Array[BranchInfo] = []
  for item in map.to_array() {
    let (name, id) = item
    let current = match head {
      Branch(n) => n == name
      Detached(_) => false
    }
    branches.push({ name, id, current })
  }
  branches.sort_by((a, b) => String::compare(a.name, b.name))
  (head, branches)
}

///|
/// Format like `git branch` output.
pub fn list_branches_text(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @git.GitError {
  let (head, branches) = list_branches(fs, git_dir)
  let lines : Array[String] = []
  match head {
    Detached(id) => {
      let short = shorten_hex(id.to_hex(), 7)
      lines.push("* (HEAD detached at \{short})")
    }
    Branch(_) => ()
  }
  for b in branches {
    let mark = if b.current { "*" } else { " " }
    lines.push("\{mark} \{b.name}")
  }
  lines
}

///|
/// List branches with commit hash (verbose mode).
pub fn list_branches_verbose(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @git.GitError {
  let lines : Array[String] = []
  let (head, branches) = list_branches(fs, git_dir)
  for b in branches {
    let marker = match head {
      Branch(name) => if name == b.name { "* " } else { "  " }
      Detached(_) => "  "
    }
    let short_hash = (try! b.id.to_hex()[:7]).to_string()
    lines.push("\{marker}\{b.name} \{short_hash}")
  }
  lines
}

///|
/// List remote tracking branches.
pub fn list_remote_branches(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] {
  let lines : Array[String] = []
  let refs_dir = join_path(git_dir, "refs/remotes")
  if not(fs.is_dir(refs_dir)) {
    return lines
  }
  // Walk refs/remotes directory
  collect_remote_refs(fs, refs_dir, "", lines)
  lines.sort()
  lines
}

///|
fn collect_remote_refs(
  fs : &@git.RepoFileSystem,
  base_dir : String,
  prefix : String,
  out : Array[String],
) -> Unit {
  let entries = fs.readdir(base_dir) catch { _ => return () }
  for entry in entries {
    let path = join_path(base_dir, entry)
    let name = if prefix.length() > 0 { prefix + "/" + entry } else { entry }
    if fs.is_dir(path) {
      collect_remote_refs(fs, path, name, out)
    } else if fs.is_file(path) {
      out.push("  remotes/" + name)
    }
  }
}

///|
/// Create a local branch pointing at current HEAD.
pub fn create_branch(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  name : String,
) -> Unit raise @git.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  let dir = parent_dir(ref_path)
  fs.mkdir_p(dir)
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => fs.write_string(ref_path, "")
    Some(id) => fs.write_string(ref_path, id.to_hex() + "\n")
  }
}

///|
/// Create a local branch pointing at a specific commit.
pub fn create_branch_at(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  name : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  let dir = parent_dir(ref_path)
  fs.mkdir_p(dir)
  ignore(rfs)
  fs.write_string(ref_path, commit_id.to_hex() + "\n")
}

///|
/// Delete a local branch. Fails if it's the current branch.
pub fn delete_branch(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  name : String,
  force? : Bool = false,
) -> Unit raise @git.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let head = read_head_ref(rfs, git_dir)
  match head {
    Branch(current) =>
      if current == name {
        raise @git.GitError::InvalidObject(
          "Cannot delete branch '\{name}' checked out at '\{root}'",
        )
      }
    Detached(_) => ()
  }
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  // Check if branch exists
  let exists = rfs.is_file(ref_path) ||
    resolve_packed_ref(rfs, join_path(git_dir, "packed-refs"), refname)
    is Some(_)
  if not(exists) {
    raise @git.GitError::InvalidObject("branch '\{name}' not found")
  }
  // Check if branch is fully merged (unless force)
  if not(force) {
    let head_commit = resolve_head_commit(rfs, git_dir)
    let branch_id = match resolve_ref(rfs, git_dir, refname) {
      Some(id) => id
      None => raise @git.GitError::InvalidObject("branch '\{name}' not found")
    }
    match head_commit {
      Some(head_id) =>
        if not(is_ancestor_of(rfs, git_dir, branch_id, head_id)) {
          raise @git.GitError::InvalidObject(
            "The branch '\{name}' is not fully merged.\nIf you are sure you want to delete it, run 'git branch -D \{name}'.",
          )
        }
      None => ()
    }
  }
  // Delete loose ref if it exists
  if rfs.is_file(ref_path) {
    fs.remove_file(ref_path)
  }
  // Remove from packed-refs if present
  let packed_path = join_path(git_dir, "packed-refs")
  if rfs.is_file(packed_path) {
    remove_from_packed_refs(fs, rfs, packed_path, refname)
  }
}

///|
/// Rename a local branch.
pub fn rename_branch(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  old_name : String,
  new_name : String,
  force? : Bool = false,
) -> Unit raise @git.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let old_ref = branch_ref_name(old_name)
  let new_ref = branch_ref_name(new_name)
  let old_path = join_path(git_dir, old_ref)
  let new_path = join_path(git_dir, new_ref)
  let old_id = match resolve_ref(rfs, git_dir, old_ref) {
    Some(id) => id
    None => raise @git.GitError::InvalidObject("branch '\{old_name}' not found")
  }
  let packed_path = join_path(git_dir, "packed-refs")
  let new_exists = rfs.is_file(new_path) ||
    resolve_packed_ref(rfs, packed_path, new_ref) is Some(_)
  if new_exists {
    if not(force) {
      raise @git.GitError::InvalidObject("branch '\{new_name}' already exists")
    }
    if rfs.is_file(new_path) {
      fs.remove_file(new_path)
    }
    if rfs.is_file(packed_path) {
      remove_from_packed_refs(fs, rfs, packed_path, new_ref)
    }
  }
  let dir = parent_dir(new_path)
  fs.mkdir_p(dir)
  fs.write_string(new_path, old_id.to_hex() + "\n")
  if rfs.is_file(old_path) {
    fs.remove_file(old_path)
  }
  if rfs.is_file(packed_path) {
    remove_from_packed_refs(fs, rfs, packed_path, old_ref)
  }
  let head = read_head_ref(rfs, git_dir)
  match head {
    Branch(name) =>
      if name == old_name {
        let head_path = join_path(git_dir, "HEAD")
        fs.write_string(head_path, "ref: \{new_ref}\n")
      }
    Detached(_) => ()
  }
  let old_log = join_path(git_dir, "logs/" + old_ref)
  if rfs.is_file(old_log) {
    let new_log = join_path(git_dir, "logs/" + new_ref)
    let parent = parent_dir(new_log)
    fs.mkdir_p(parent)
    let data = rfs.read_file(old_log)
    fs.write_file(new_log, data)
    fs.remove_file(old_log)
  }
}

///|
fn remove_from_packed_refs(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  packed_path : String,
  refname : String,
) -> Unit raise @git.GitError {
  let text = @utf8.decode_lossy(rfs.read_file(packed_path)[:])
  let lines : Array[String] = []
  let mut found = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      continue
    }
    // Check if this line is for the ref we want to remove
    let space = line.find(" ")
    match space {
      None => lines.push(line)
      Some(idx) => {
        if idx + 1 >= line.length() {
          lines.push(line)
          continue
        }
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if name == refname {
          found = true
        } else {
          lines.push(line)
        }
      }
    }
  }
  if found {
    let new_content = lines.join("\n") + "\n"
    fs.write_string(packed_path, new_content)
  }
}

///|
/// Switch HEAD to a branch, optionally creating it and checking out files.
pub fn switch_branch(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  name : String,
  create? : Bool = false,
  checkout_files? : Bool = true,
) -> Unit raise @git.GitError {
  let git_dir = resolve_worktree_git_dir(rfs, root)
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  if create {
    create_branch(fs, rfs, root, name)
  } else if not(rfs.is_file(ref_path)) {
    match resolve_ref(rfs, git_dir, refname) {
      None => raise @git.GitError::InvalidObject("Invalid ref: \{name}")
      Some(_) => ()
    }
  }
  if checkout_files {
    ignore(checkout(fs, rfs, root, name))
  } else {
    let head_path = join_path(git_dir, "HEAD")
    fs.write_string(head_path, "ref: \{refname}\n")
  }
}

///|
/// Resolve a ref to an object id.
pub fn resolve_ref(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @git.ObjectId? raise @git.GitError {
  let path = join_path(git_dir, refname)
  if fs.is_file(path) {
    let line = read_ref_line(fs, path)
    return line |> @git.ObjectId::from_hex |> Some
  }
  let packed = join_path(git_dir, "packed-refs")
  if fs.is_file(packed) {
    return resolve_packed_ref(fs, packed, refname)
  }
  None
}

///|
fn collect_loose_heads(
  fs : &@git.RepoFileSystem,
  dir : String,
  prefix : String,
  out : Map[String, @git.ObjectId],
) -> Unit raise @git.GitError {
  let entries = fs.readdir(dir)
  for name in entries {
    let path = join_path(dir, name)
    let rel = if prefix == "" { name } else { prefix + "/" + name }
    if fs.is_dir(path) {
      collect_loose_heads(fs, path, rel, out)
    } else if fs.is_file(path) {
      let line = read_ref_line(fs, path)
      let id = @git.ObjectId::from_hex(line)
      out[rel] = id
    }
  }
}

///|
fn collect_packed_heads(
  fs : &@git.RepoFileSystem,
  packed_path : String,
  out : Map[String, @git.ObjectId],
) -> Unit raise @git.GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if not(refname.has_prefix("refs/heads/")) {
          continue
        }
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        if not(out.contains(name)) {
          out[name] = @git.ObjectId::from_hex(id_hex)
        }
      }
    }
  }
}

///|
fn branch_ref_name(name : String) -> String {
  if name.has_prefix("refs/heads/") {
    name
  } else {
    "refs/heads/" + name
  }
}

///|
fn resolve_packed_ref(
  fs : &@git.RepoFileSystem,
  packed_path : String,
  refname : String,
) -> @git.ObjectId? raise @git.GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if name == refname {
          return id_hex |> @git.ObjectId::from_hex |> Some
        }
      }
    }
  }
  None
}

///|
fn read_ref_line(
  fs : &@git.RepoFileSystem,
  path : String,
) -> String raise @git.GitError {
  let text = @utf8.decode_lossy(fs.read_file(path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() > 0 {
      return line
    }
  }
  raise @git.GitError::InvalidObject("Empty ref: \{path}")
}

///|
fn trim_line(line : String) -> String {
  let mut s = line
  if s.has_suffix("\r") {
    s = String::unsafe_substring(s, start=0, end=s.length() - 1)
  }
  s
}

///|
fn shorten_hex(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
}

///|
/// List all tags.
pub fn list_tags(fs : &@git.RepoFileSystem, git_dir : String) -> Array[String] {
  let tags : Array[String] = []
  let refs_dir = join_path(git_dir, "refs/tags")
  if fs.is_dir(refs_dir) {
    collect_tag_names(fs, refs_dir, "", tags)
  }
  // Also check packed-refs
  let packed_path = join_path(git_dir, "packed-refs")
  if fs.is_file(packed_path) {
    collect_packed_tags(fs, packed_path, tags)
  }
  tags.sort()
  tags
}

///|
fn collect_tag_names(
  fs : &@git.RepoFileSystem,
  dir : String,
  prefix : String,
  out : Array[String],
) -> Unit {
  let entries = fs.readdir(dir) catch { _ => return () }
  for entry in entries {
    let path = join_path(dir, entry)
    let name = if prefix.length() > 0 { prefix + "/" + entry } else { entry }
    if fs.is_dir(path) {
      collect_tag_names(fs, path, name, out)
    } else if fs.is_file(path) {
      if not(out.contains(name)) {
        out.push(name)
      }
    }
  }
}

///|
fn collect_packed_tags(
  fs : &@git.RepoFileSystem,
  packed_path : String,
  out : Array[String],
) -> Unit {
  let text = @utf8.decode_lossy(
    (fs.read_file(packed_path) catch { _ => return () })[:],
  )
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if refname.has_prefix("refs/tags/") {
          let name = String::unsafe_substring(
            refname,
            start=10,
            end=refname.length(),
          )
          if not(out.contains(name)) {
            out.push(name)
          }
        }
      }
    }
  }
}

///|
/// Delete a tag.
pub fn delete_tag(
  fs : &@git.FileSystem,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
  let ref_path = join_path(git_dir, "refs/tags/" + name)
  fs.remove_file(ref_path)
}

///|
/// Create a lightweight tag.
pub fn create_lightweight_tag(
  fs : &@git.FileSystem,
  git_dir : String,
  name : String,
  target : @git.ObjectId,
) -> Unit raise @git.GitError {
  let tags_dir = join_path(git_dir, "refs/tags")
  fs.mkdir_p(tags_dir)
  let ref_path = join_path(git_dir, "refs/tags/" + name)
  fs.write_string(ref_path, target.to_hex() + "\n")
}

///|
/// Create an annotated tag.
pub fn create_annotated_tag(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  target : @git.ObjectId,
  message : String,
  tagger : String,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  // Create tag object
  let tag_content = "object \{target.to_hex()}\ntype commit\ntag \{name}\ntagger \{tagger} \{timestamp} +0000\n\n\{message}\n"
  let tag_bytes = @utf8.encode(tag_content)
  let (tag_id, compressed) = @git.create_object(@git.ObjectType::Tag, tag_bytes)
  write_object_bytes(fs, git_dir, tag_id, compressed)
  // Create ref pointing to tag object
  ignore(rfs)
  let tags_dir = join_path(git_dir, "refs/tags")
  fs.mkdir_p(tags_dir)
  let ref_path = join_path(git_dir, "refs/tags/" + name)
  fs.write_string(ref_path, tag_id.to_hex() + "\n")
}

///|
/// Check if `ancestor` is an ancestor of `descendant` via BFS.
pub fn is_ancestor_of(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  ancestor : @git.ObjectId,
  descendant : @git.ObjectId,
) -> Bool {
  if ancestor == descendant {
    return true
  }
  let db = ObjectDb::load(fs, git_dir) catch { _ => return false }
  let ancestor_hex = ancestor.to_hex()
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [descendant]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if hex == ancestor_hex {
      return true
    }
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    let obj = db.get(fs, cid) catch { _ => continue }
    match obj {
      Some(o) => {
        let info = @git.parse_commit(o.data) catch { _ => continue }
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
  false
}
