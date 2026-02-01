///|
/// Subdir-clone command handler - clone subdirectory as independent repository

///|
fn print_subdir_clone_usage() -> Unit {
  println("Usage: bit subdir-clone <url> <path> [<dest>]")
  println("")
  println("Clone a subdirectory from a remote repository as an independent git repo.")
  println("")
  println("Arguments:")
  println("  <url>         Remote repository URL")
  println("  <path>        Path within the remote repo (e.g., src/lib)")
  println("  <dest>        Local directory name (default: last component of path)")
  println("")
  println("Examples:")
  println("  bit subdir-clone https://github.com/user/repo src")
  println("    → Creates src/ with contents of repo's src/")
  println("")
  println("  bit subdir-clone https://github.com/user/repo src/lib mylib")
  println("    → Creates mylib/ with contents of repo's src/lib/")
  println("")
  println("After cloning, standard git/bit commands work from the directory:")
  println("  cd mylib")
  println("  bit status     # detects subdir-clone automatically")
  println("  bit rebase origin/main  # rebases only subdir changes")
}

///|
/// Clone a subdirectory from remote repository
async fn handle_subdir_clone(args : Array[String]) -> Unit raise Error {
  let mut url : String? = None
  let mut subdir : String? = None
  let mut dest : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("-") {
      i += 1
      continue
    }
    if url is None {
      url = Some(arg)
    } else if subdir is None {
      subdir = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
    i += 1
  }
  guard url is Some(remote_url) else {
    print_subdir_clone_usage()
    return
  }
  guard subdir is Some(subdir_path) else {
    raise @git.GitError::InvalidObject("subdirectory path required")
  }
  // Derive destination from subdir or explicit dest
  let relative_target = match dest {
    Some(d) => d
    None => {
      match subdir_path.rev_find("/") {
        Some(idx) =>
          String::unsafe_substring(subdir_path, start=idx + 1, end=subdir_path.length())
        None => subdir_path
      }
    }
  }
  let root = get_work_root()
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  let git_dir = target + "/.git"
  print_line(
    "Cloning '\{subdir_path}' from '\{remote_url}' into '\{relative_target}'...",
  )
  let fs = OsFs::new()
  // Step 1: Create target directory
  fs.mkdir_p(target) catch {
    _ => raise @git.GitError::IoError("Failed to create directory: " + target)
  }
  // Step 2: Clone with blob:none filter to a temp location
  print_line("  Fetching repository metadata...")
  let temp_clone = target + "/.git-temp"
  let refs = @git.clone_http_to_fs(
    remote_url,
    true,
    fs,
    temp_clone,
    filter=@git.FilterSpec::BlobNone,
  )
  if refs.length() == 0 {
    raise @git.GitError::InvalidObject("Clone failed: no refs found")
  }
  // Step 3: Read HEAD commit from temp
  let temp_git_dir = temp_clone + "/.git"
  let head_ref = fs.read_file(temp_git_dir + "/HEAD") catch {
    _ => raise @git.GitError::IoError("Failed to read HEAD")
  }
  let head_text = @utf8.decode_lossy(head_ref[:]).trim(chars=" \n\r\t").to_string()
  let commit_id = if head_text.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(head_text, start=5, end=head_text.length())
    let ref_path = temp_git_dir + "/" + ref_name
    let ref_content = fs.read_file(ref_path) catch {
      _ => raise @git.GitError::IoError("Failed to read ref: " + ref_name)
    }
    let ref_text = @utf8.decode_lossy(ref_content[:]).trim(chars=" \n\r\t").to_string()
    @git.ObjectId::from_hex(ref_text) catch {
      _ => raise @git.GitError::InvalidObject("Invalid commit ID in ref")
    }
  } else {
    @git.ObjectId::from_hex(head_text) catch {
      _ => raise @git.GitError::InvalidObject("Invalid HEAD")
    }
  }
  // Load object database and get tree
  let db = @gitlib.ObjectDb::load_lazy(fs, temp_git_dir)
  let commit_obj = db.get(fs, commit_id)
  guard commit_obj is Some(obj) else {
    raise @git.GitError::InvalidObject("Commit not found")
  }
  let commit_info = @git.parse_commit(obj.data)
  // Navigate to subdirectory tree
  print_line("  Finding subdirectory '\{subdir_path}'...")
  let subdir_tree_id = find_subtree(db, fs, commit_info.tree, subdir_path)
  guard subdir_tree_id is Some(tree_id) else {
    subdir_remove_dir(fs, temp_clone)
    raise @git.GitError::InvalidObject(
      "Subdirectory not found: " + subdir_path,
    )
  }
  // Fetch blobs for the subdirectory
  print_line("  Fetching files...")
  let needed_blobs = collect_tree_blobs(db, fs, tree_id)
  if needed_blobs.length() > 0 {
    let missing : Array[@git.ObjectId] = []
    for blob_id in needed_blobs {
      let exists = db.get(fs, blob_id)
      if exists is None {
        missing.push(blob_id)
      }
    }
    if missing.length() > 0 {
      let pack = @git.fetch_pack_http(remote_url, missing, true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, temp_git_dir, pack, objects)
    }
  }
  // Reload object database
  let db2 = @gitlib.ObjectDb::load_lazy(fs, temp_git_dir)
  // Step 4: Write files directly to target
  print_line("  Writing files...")
  write_tree_to_worktree(db2, fs, tree_id, target)
  // Step 5: Move .git to target
  print_line("  Setting up git repository...")
  move_directory(fs, temp_git_dir, git_dir)
  subdir_remove_dir(fs, temp_clone)
  // Step 6: Create orphan commit with subdirectory as root
  print_line("  Creating initial commit...")
  let timestamp = get_current_timestamp()
  let author = "subdir-clone <subdir-clone@bit>"
  let message = "Initial commit (cloned from " + subdir_path + ")\n"
  let parents : Array[@git.ObjectId] = []
  let commit = @git.Commit::new(
    tree_id,
    parents,
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  let (new_commit_id, commit_bytes) = @git.create_commit(commit)
  @gitlib.write_object_bytes(fs, git_dir, new_commit_id, commit_bytes) catch {
    _ => raise @git.GitError::IoError("Failed to write commit object")
  }
  // Update HEAD
  let head_path = git_dir + "/HEAD"
  fs.write_file(head_path, string_to_bytes("ref: refs/heads/main\n")) catch {
    _ => ()
  }
  let ref_path = git_dir + "/refs/heads/main"
  fs.mkdir_p(git_dir + "/refs/heads") catch { _ => () }
  fs.write_file(ref_path, string_to_bytes(new_commit_id.to_hex() + "\n")) catch {
    _ => ()
  }
  // Step 7: Write subdir-clone metadata to .git/info/attributes
  write_subdir_attributes(fs, git_dir, remote_url, subdir_path, commit_id)
  // Step 8: Reset index
  let _ = @process.run("git", ["-C", target, "reset", "HEAD"])
  print_line("done.")
  print_line("")
  print_line("Cloned '\{subdir_path}' to '\{relative_target}/'")
  print_line("")
  print_line("Standard git/bit commands work from this directory:")
  print_line("  cd \{relative_target}")
  print_line("  bit status")
  print_line("  bit rebase origin/main  # rebases only subdir changes")
}

///|
/// Write subdir-clone metadata to .git/info/attributes
fn write_subdir_attributes(
  fs : OsFs,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  base_commit : @git.ObjectId,
) -> Unit {
  let info_dir = git_dir + "/info"
  fs.mkdir_p(info_dir) catch { _ => () }
  let content = StringBuilder::new()
  content.write_string("# subdir-clone metadata\n")
  content.write_string("* subdir-remote=")
  content.write_string(remote_url)
  content.write_string("\n")
  content.write_string("* subdir-path=")
  content.write_string(subdir_path)
  content.write_string("\n")
  content.write_string("* subdir-base=")
  content.write_string(base_commit.to_hex())
  content.write_string("\n")
  let attr_path = info_dir + "/attributes"
  fs.write_file(attr_path, string_to_bytes(content.to_string())) catch { _ => () }
}

///|
/// Read subdir-clone metadata from .git/info/attributes
pub fn read_subdir_attributes(
  fs : OsFs,
  git_dir : String,
) -> (String, String, String)? {
  let attr_path = git_dir + "/info/attributes"
  let content = fs.read_file(attr_path) catch { _ => return None }
  let text = bytes_to_string(content)
  let mut remote = ""
  let mut path = ""
  let mut base = ""
  for line in text.split("\n") {
    let l = line.to_string()
    if l.has_prefix("* subdir-remote=") {
      remote = String::unsafe_substring(l, start=16, end=l.length())
    } else if l.has_prefix("* subdir-path=") {
      path = String::unsafe_substring(l, start=14, end=l.length())
    } else if l.has_prefix("* subdir-base=") {
      base = String::unsafe_substring(l, start=14, end=l.length())
    }
  }
  if remote.length() > 0 && path.length() > 0 {
    Some((remote, path, base))
  } else {
    None
  }
}

///|
/// Update subdir-base in .git/info/attributes
pub fn update_subdir_base(
  fs : OsFs,
  git_dir : String,
  new_base : String,
) -> Unit {
  match read_subdir_attributes(fs, git_dir) {
    Some((remote, path, _)) =>
      write_subdir_attributes(
        fs,
        git_dir,
        remote,
        path,
        @git.ObjectId::from_hex(new_base) catch { _ => return },
      )
    None => ()
  }
}

///|
/// Check if current directory is a subdir-clone
pub fn is_subdir_clone(fs : OsFs, git_dir : String) -> Bool {
  read_subdir_attributes(fs, git_dir) is Some(_)
}

///|
/// Get effective remote URL - prefers subdir remote over config
pub fn get_effective_remote_url(fs : OsFs, git_dir : String) -> String? {
  // First check subdir-clone attributes
  match read_subdir_attributes(fs, git_dir) {
    Some((remote_url, _, _)) => Some(remote_url)
    None => read_remote_url_from_config(fs, git_dir)
  }
}

///|
/// Get subdir info for display (remote, path, base)
pub fn get_subdir_info(fs : OsFs, git_dir : String) -> (String, String, String)? {
  read_subdir_attributes(fs, git_dir)
}

///|
/// Get the subdir tree from a commit (for subdir-clone operations)
pub fn get_subdir_tree_from_commit(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commit_id : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(fs, commit_id)
  guard obj is Some(o) else { return None }
  let info = @git.parse_commit(o.data) catch { err => raise err }
  find_subtree(db, fs, info.tree, subdir_path) catch { err => raise err }
}

///|
/// Resolve a ref to commit ID, handling both local and remote refs
pub fn resolve_ref_for_subdir(
  fs : OsFs,
  git_dir : String,
  refspec : String,
) -> @git.ObjectId? raise Error {
  let rfs : &@git.RepoFileSystem = fs
  // Try direct rev_parse first
  match @gitlib.rev_parse(rfs, git_dir, refspec) {
    Some(id) => Some(id)
    None => {
      // Try as remote ref (e.g., origin/main -> refs/remotes/origin/main)
      let remote_path = git_dir + "/refs/remotes/" + refspec
      let bytes = fs.read_file(remote_path) catch { _ => return None }
      let hex = bytes_to_string(bytes).trim(chars=" \n\t").to_string()
      let id = @git.ObjectId::from_hex(hex) catch { _ => return None }
      Some(id)
    }
  }
}

///|
fn find_subtree(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? raise @git.GitError {
  let parts : Array[String] = []
  for p in path.split("/") {
    let s = p.to_string()
    if s.length() > 0 {
      parts.push(s)
    }
  }
  let mut current = tree_id
  for part in parts {
    let obj = db.get(rfs, current)
    guard obj is Some(tree_obj) else { return None }
    let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        current = entry.id
        found = true
        break
      }
    }
    if not(found) {
      return None
    }
  }
  Some(current)
}

///|
fn collect_tree_blobs(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let blobs : Array[@git.ObjectId] = []
  let obj = db.get(rfs, tree_id)
  guard obj is Some(tree_obj) else { return blobs }
  let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
  for entry in entries {
    if entry.mode == "40000" || entry.mode == "040000" {
      let sub_blobs = collect_tree_blobs(db, rfs, entry.id) catch { err => raise err }
      for b in sub_blobs {
        blobs.push(b)
      }
    } else {
      blobs.push(entry.id)
    }
  }
  blobs
}

///|
fn write_tree_to_worktree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  dir : String,
) -> Unit raise @git.GitError {
  let obj = db.get(fs, tree_id)
  guard obj is Some(tree_obj) else { return }
  let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
  for entry in entries {
    let path = dir + "/" + entry.name
    if entry.mode == "40000" || entry.mode == "040000" {
      fs.mkdir_p(path) catch { _ => () }
      write_tree_to_worktree(db, fs, entry.id, path) catch { err => raise err }
    } else {
      let blob_obj = db.get(fs, entry.id)
      guard blob_obj is Some(blob) else { continue }
      fs.write_file(path, blob.data) catch { _ => () }
    }
  }
}

///|
fn move_directory(fs : OsFs, src : String, dst : String) -> Unit {
  fs.mkdir_p(dst) catch { _ => () }
  let entries = fs.readdir(src) catch { _ => return }
  for entry in entries {
    let src_path = src + "/" + entry
    let dst_path = dst + "/" + entry
    if fs.is_dir(src_path) {
      move_directory(fs, src_path, dst_path)
    } else {
      let content = fs.read_file(src_path) catch { _ => continue }
      fs.write_file(dst_path, content) catch { _ => () }
    }
  }
}

///|
fn subdir_remove_dir(fs : OsFs, path : String) -> Unit {
  let entries = fs.readdir(path) catch { _ => return }
  for entry in entries {
    let child_path = path + "/" + entry
    if fs.is_dir(child_path) {
      subdir_remove_dir(fs, child_path)
    } else {
      fs.remove_file(child_path) catch { _ => () }
    }
  }
  fs.remove_dir(path) catch { _ => () }
}

///|
fn string_to_bytes(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
fn bytes_to_string(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < bytes.length(); i = i + 1 {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}
