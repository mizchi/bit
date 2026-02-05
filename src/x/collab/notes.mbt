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
  let note_text = note.serialize()
  let (blob_id, compressed) = @git.create_blob_string(note_text)
  write_object_bytes(fs, self.git_dir, blob_id, compressed)
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
  let text = read_note_blob(backing_fs, self.git_dir, commit_id, ns)
  match text {
    None => None
    Some(t) => {
      let note = parse_note(t)
      if note.ns != ns {
        None
      } else {
        Some(note)
      }
    }
  }
}

///|
/// List all notes in a ns
pub fn Collab::list_notes(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  ns? : String = "commits",
) -> Array[Note] raise @git.GitError {
  let result : Array[Note] = []
  let tree_id = get_notes_tree(backing_fs, self.git_dir, ns)
  match tree_id {
    None => ()
    Some(tid) => {
      let db = @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
      let obj = db.get(backing_fs, tid)
      match obj {
        Some(tree_obj) => {
          let entries = @git.parse_tree(tree_obj.data)
          for entry in entries {
            let blob = db.get(backing_fs, entry.id)
            match blob {
              Some(blob_obj) => {
                let text = @utf8.decode_lossy(blob_obj.data[:])
                let note = parse_note(text)
                if note.ns == ns {
                  result.push(note)
                }
              }
              None => ()
            }
          }
        }
        None => ()
      }
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
/// Remove a note from a commit
pub fn Collab::remove_note(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  timestamp : Int64,
  ns? : String = "commits",
) -> Unit raise @git.GitError {
  ignore(timestamp)
  remove_notes_tree_entry(fs, backing_fs, self.git_dir, commit_id, ns)
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
fn read_note_blob(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  ns : String,
) -> String? raise @git.GitError {
  let tree_id = get_notes_tree(backing_fs, git_dir, ns)
  guard tree_id is Some(tid) else { return None }
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let tree_obj = db.get(backing_fs, tid)
  guard tree_obj is Some(tree) else { return None }
  let entries = @git.parse_tree(tree.data)
  let commit_hex = commit_id.to_hex()
  for entry in entries {
    if entry.name == commit_hex {
      let blob = db.get(backing_fs, entry.id)
      match blob {
        Some(blob_obj) => return Some(@utf8.decode_lossy(blob_obj.data[:]))
        None => return None
      }
    }
  }
  None
}

///|

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
    "Collab <collab@local>",
    0L,
    "+0000",
    "Collab <collab@local>",
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
fn remove_notes_tree_entry(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  ns : String,
) -> Unit raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let commit_hex = commit_id.to_hex()
  let existing_tree_id = get_notes_tree(backing_fs, git_dir, ns)
  guard existing_tree_id is Some(tid) else { return () }
  let obj = db.get(backing_fs, tid)
  guard obj is Some(tree_obj) else { return () }
  let entries = @git.parse_tree(tree_obj.data)
  let new_entries : Array[@git.TreeEntry] = []
  let mut found = false
  for entry in entries {
    if entry.name == commit_hex {
      found = true
      continue
    }
    new_entries.push(entry)
  }
  if not(found) {
    return ()
  }
  new_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_tree_id, tree_compressed) = @git.create_tree(new_entries)
  write_object_bytes(fs, git_dir, new_tree_id, tree_compressed)
  let parents = match get_notes_commit(backing_fs, git_dir, ns) {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    new_tree_id,
    parents,
    "Collab <collab@local>",
    0L,
    "+0000",
    "Collab <collab@local>",
    0L,
    "+0000",
    "Remove note for \{short_hex_note(commit_hex, 8)}...\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  let ref_path = join_path(git_dir, notes_ref_prefix + ns)
  let refs_dir = join_path(git_dir, "refs/notes")
  fs.mkdir_p(refs_dir)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}
