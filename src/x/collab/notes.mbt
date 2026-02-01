///| Git Notes operations (Git compatible + Collab integration)

///|

///| Notes are stored in refs/notes/<ns> (Git standard)

///| Default ns is "commits"

///|
/// The notes ref prefix
let notes_ref_prefix : String = "refs/notes/"

///|
/// Add a note to a commit (Git compatible)
pub fn Collab::add_note(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  body : String,
  author : String,
  timestamp : Int64,
  ns? : String = "commits",
) -> Note raise @git.GitError {
  let note = Note::new(commit_id, body, author, timestamp, ns~)
  // Create note blob with Collab metadata
  let note_data = note.serialize()
  let (blob_id, compressed) = @git.create_blob_string(note_data)
  write_object_bytes(fs, self.git_dir, blob_id, compressed)
  // Update notes ref tree
  update_notes_tree(fs, backing_fs, self.git_dir, commit_id, blob_id, ns)
  note
}

///|
/// Add a plain note (Git standard, no metadata)
pub fn Collab::add_note_plain(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  body : String,
  ns? : String = "commits",
) -> Unit raise @git.GitError {
  let (blob_id, compressed) = @git.create_blob_string(body)
  write_object_bytes(fs, self.git_dir, blob_id, compressed)
  update_notes_tree(fs, backing_fs, self.git_dir, commit_id, blob_id, ns)
}

///|
/// Get a note for a commit
pub fn Collab::get_note(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  ns? : String = "commits",
) -> Note? raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let notes_tree_id = get_notes_tree(backing_fs, self.git_dir, ns)
  guard notes_tree_id is Some(tree_id) else { return None }
  // Find note by commit SHA
  let commit_hex = commit_id.to_hex()
  let note_id = find_note_in_tree(db, backing_fs, tree_id, commit_hex)
  guard note_id is Some(blob_id) else { return None }
  // Read note blob
  let obj = db.get(backing_fs, blob_id)
  guard obj is Some(blob_obj) else { return None }
  let text = @utf8.decode_lossy(blob_obj.data[:])
  // Try to parse as Collab note (with metadata), fall back to plain
  let note = parse_note(text)
  Some(note)
}

///|
/// List all notes in a ns
pub fn Collab::list_notes(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  ns? : String = "commits",
) -> Array[Note] raise @git.GitError {
  let result : Array[Note] = []
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let notes_tree_id = get_notes_tree(backing_fs, self.git_dir, ns)
  guard notes_tree_id is Some(tree_id) else { return result }
  // Traverse notes tree
  collect_notes_from_tree(db, backing_fs, tree_id, "", result)
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
/// Remove a note from a commit
pub fn Collab::remove_note(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  ns? : String = "commits",
) -> Unit raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
  let notes_tree_id = get_notes_tree(backing_fs, self.git_dir, ns)
  guard notes_tree_id is Some(tree_id) else { return }
  let commit_hex = commit_id.to_hex()
  // Rebuild tree without this note
  let new_tree_id = remove_note_from_tree(
    fs,
    db,
    backing_fs,
    self.git_dir,
    tree_id,
    commit_hex,
  )
  // Update ref
  let ref_path = join_path(self.git_dir, notes_ref_prefix + ns)
  // Create commit for the notes tree
  let parents = match get_notes_commit(backing_fs, self.git_dir, ns) {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    new_tree_id,
    parents,
    "Collab <den@local>",
    0L,
    "+0000",
    "Collab <den@local>",
    0L,
    "+0000",
    "Remove note for \{short_hex_note(commit_hex, 8)}...\n",
  )
  let (commit_id_new, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, self.git_dir, commit_id_new, commit_compressed)
  fs.write_string(ref_path, commit_id_new.to_hex() + "\n")
}

///|
fn short_hex_note(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
}

///|
fn get_notes_commit(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  ns : String,
) -> @git.ObjectId? raise @git.GitError {
  let ref_name = notes_ref_prefix + ns
  @lib.resolve_ref(backing_fs, git_dir, ref_name)
}

///|
fn get_notes_tree(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  ns : String,
) -> @git.ObjectId? raise @git.GitError {
  let commit_id = get_notes_commit(backing_fs, git_dir, ns)
  guard commit_id is Some(cid) else { return None }
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let obj = db.get(backing_fs, cid)
  guard obj is Some(commit_obj) else { return None }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|
fn find_note_in_tree(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  commit_hex : String,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(tree_obj) else { return None }
  let entries = @git.parse_tree(tree_obj.data)
  // Git notes can store as:
  // 1. Direct: <full-sha> -> blob
  // 2. Fanout: <2-char>/<38-char> -> blob
  for entry in entries {
    if entry.name == commit_hex {
      // Direct match
      return Some(entry.id)
    }
    if entry.name.length() == 2 && commit_hex.has_prefix(entry.name) {
      // Fanout directory, recurse
      let sub_name = String::unsafe_substring(
        commit_hex,
        start=2,
        end=commit_hex.length(),
      )
      let sub_obj = db.get(backing_fs, entry.id)
      guard sub_obj is Some(sub_tree) else { continue }
      let sub_entries = @git.parse_tree(sub_tree.data)
      for sub_entry in sub_entries {
        if sub_entry.name == sub_name {
          return Some(sub_entry.id)
        }
      }
    }
  }
  None
}

///|
fn collect_notes_from_tree(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  result : Array[Note],
) -> Unit raise @git.GitError {
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(tree_obj) else { return }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    if entry.name.length() == 2 && prefix.length() == 0 {
      // Fanout directory
      collect_notes_from_tree(db, backing_fs, entry.id, entry.name, result)
    } else {
      // Note blob
      let commit_hex = prefix + entry.name
      let blob_obj = db.get(backing_fs, entry.id)
      guard blob_obj is Some(blob) else { continue }
      let text = @utf8.decode_lossy(blob.data[:])
      let _commit_id = @git.ObjectId::from_hex(commit_hex) catch {
        _ => continue
      }
      let note = parse_note(text)
      result.push(note)
    }
  }
}

///|
fn update_notes_tree(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  blob_id : @git.ObjectId,
  ns : String,
) -> Unit raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let commit_hex = commit_id.to_hex()
  // Get existing tree or create empty
  let existing_tree_id = get_notes_tree(backing_fs, git_dir, ns)
  let entries : Array[@git.TreeEntry] = match existing_tree_id {
    Some(tid) => {
      let obj = db.get(backing_fs, tid)
      match obj {
        Some(tree_obj) => @git.parse_tree(tree_obj.data)
        None => []
      }
    }
    None => []
  }
  // Add or update entry (direct mode, no fanout for simplicity)
  let new_entries : Array[@git.TreeEntry] = []
  let mut found = false
  for entry in entries {
    if entry.name == commit_hex {
      new_entries.push(@git.TreeEntry::new("100644", commit_hex, blob_id))
      found = true
    } else {
      new_entries.push(entry)
    }
  }
  if not(found) {
    new_entries.push(@git.TreeEntry::new("100644", commit_hex, blob_id))
  }
  new_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_tree_id, tree_compressed) = @git.create_tree(new_entries)
  write_object_bytes(fs, git_dir, new_tree_id, tree_compressed)
  // Create commit
  let parents = match get_notes_commit(backing_fs, git_dir, ns) {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    new_tree_id,
    parents,
    "Collab <den@local>",
    0L,
    "+0000",
    "Collab <den@local>",
    0L,
    "+0000",
    "Add note for \{short_hex_note(commit_hex, 8)}...\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, notes_ref_prefix + ns)
  let refs_dir = join_path(git_dir, "refs/notes")
  fs.mkdir_p(refs_dir)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}

///|
fn remove_note_from_tree(
  fs : &@git.FileSystem,
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  tree_id : @git.ObjectId,
  commit_hex : String,
) -> @git.ObjectId raise @git.GitError {
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read notes tree")
  }
  let entries = @git.parse_tree(tree_obj.data)
  let new_entries : Array[@git.TreeEntry] = []
  for entry in entries {
    if entry.name != commit_hex {
      new_entries.push(entry)
    }
  }
  new_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_tree_id, tree_compressed) = @git.create_tree(new_entries)
  write_object_bytes(fs, git_dir, new_tree_id, tree_compressed)
  new_tree_id
}
