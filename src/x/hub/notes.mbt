///| Git Notes operations (Git compatible + Hub integration)

///|

///| Notes are stored in refs/notes/<ns> (Git standard)

///| Default ns is "commits"

///|
/// The notes ref prefix
let notes_ref_prefix : String = "refs/notes/"

///|
/// Add a note to a commit (Git compatible)
pub fn Hub::add_note(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  commit_id : @git.ObjectId,
  body : String,
  author : String,
  timestamp : Int64,
  ns? : String = "commits",
) -> Note raise @git.GitError {
  ignore(self)
  let note = Note::new(commit_id, body, author, timestamp, ns~)
  let note_text = note.serialize()
  let note_bytes = @utf8.encode(note_text)
  let blob_id = objects.put(@git.ObjectType::Blob, note_bytes)
  update_notes_tree(objects, refs, commit_id, blob_id, ns, clock)
  note
}

///|
/// Add a plain note (Git standard, no metadata)
pub fn Hub::add_note_plain(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  commit_id : @git.ObjectId,
  body : String,
  ns? : String = "commits",
) -> Unit raise @git.GitError {
  ignore(self)
  let body_bytes = @utf8.encode(body)
  let blob_id = objects.put(@git.ObjectType::Blob, body_bytes)
  update_notes_tree(objects, refs, commit_id, blob_id, ns, clock)
}

///|
/// Get a note for a commit
pub fn Hub::get_note(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  commit_id : @git.ObjectId,
  ns? : String = "commits",
) -> Note? raise @git.GitError {
  ignore(self)
  let text = read_note_blob(objects, refs, commit_id, ns)
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
pub fn Hub::list_notes(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  ns? : String = "commits",
) -> Array[Note] raise @git.GitError {
  ignore(self)
  let result : Array[Note] = []
  let tree_id = get_notes_tree(objects, refs, ns)
  match tree_id {
    None => ()
    Some(tid) => {
      let obj = objects.get(tid)
      match obj {
        Some(tree_obj) => {
          let entries = @git.parse_tree(tree_obj.data)
          for entry in entries {
            let blob = objects.get(entry.id)
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
pub fn Hub::remove_note(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  commit_id : @git.ObjectId,
  ns? : String = "commits",
) -> Unit raise @git.GitError {
  ignore(self)
  remove_notes_tree_entry(objects, refs, commit_id, ns, clock)
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
  refs : &@lib.RefStore,
  ns : String,
) -> @git.ObjectId? raise @git.GitError {
  let ref_name = notes_ref_prefix + ns
  refs.resolve(ref_name)
}

///|
fn get_notes_tree(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  ns : String,
) -> @git.ObjectId? raise @git.GitError {
  let commit_id = get_notes_commit(refs, ns)
  guard commit_id is Some(cid) else { return None }
  let obj = objects.get(cid)
  guard obj is Some(commit_obj) else { return None }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|
fn read_note_blob(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  commit_id : @git.ObjectId,
  ns : String,
) -> String? raise @git.GitError {
  let tree_id = get_notes_tree(objects, refs, ns)
  guard tree_id is Some(tid) else { return None }
  let tree_obj = objects.get(tid)
  guard tree_obj is Some(tree) else { return None }
  let entries = @git.parse_tree(tree.data)
  let commit_hex = commit_id.to_hex()
  for entry in entries {
    if entry.name == commit_hex {
      let blob = objects.get(entry.id)
      match blob {
        Some(blob_obj) => return blob_obj.data[:] |> @utf8.decode_lossy |> Some
        None => return None
      }
    }
  }
  None
}

///|
fn update_notes_tree(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  commit_id : @git.ObjectId,
  blob_id : @git.ObjectId,
  ns : String,
  clock : &@lib.Clock,
) -> Unit raise @git.GitError {
  let commit_hex = commit_id.to_hex()
  // Get existing tree or create empty
  let existing_tree_id = get_notes_tree(objects, refs, ns)
  let entries : Array[@git.TreeEntry] = match existing_tree_id {
    Some(tid) => {
      let obj = objects.get(tid)
      match obj {
        Some(tree_obj) => @git.parse_tree(tree_obj.data)
        None => []
      }
    }
    None => []
  }
  // Add or update entry
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
  new_entries.sort_by((a, b) => String::compare(a.name, b.name))
  let tree_bytes = @git.serialize_tree(new_entries)
  let new_tree_id = objects.put(@git.ObjectType::Tree, tree_bytes)
  // Create commit
  let parents = match get_notes_commit(refs, ns) {
    Some(p) => [p]
    None => []
  }
  let now = clock.now()
  let commit = @git.Commit::new(
    new_tree_id,
    parents,
    "Hub <hub@local>",
    now,
    "+0000",
    "Hub <hub@local>",
    now,
    "+0000",
    "Add note for \{short_hex_note(commit_hex, 8)}...\n",
  )
  let commit_bytes = @git.serialize_commit_content(commit)
  let new_commit_id = objects.put(@git.ObjectType::Commit, commit_bytes)
  // Update ref
  let ref_name = notes_ref_prefix + ns
  refs.update(ref_name, Some(new_commit_id))
}

///|
fn remove_notes_tree_entry(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  commit_id : @git.ObjectId,
  ns : String,
  clock : &@lib.Clock,
) -> Unit raise @git.GitError {
  let commit_hex = commit_id.to_hex()
  let existing_tree_id = get_notes_tree(objects, refs, ns)
  guard existing_tree_id is Some(tid) else { return () }
  let obj = objects.get(tid)
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
  new_entries.sort_by((a, b) => String::compare(a.name, b.name))
  let tree_bytes = @git.serialize_tree(new_entries)
  let new_tree_id = objects.put(@git.ObjectType::Tree, tree_bytes)
  let parents = match get_notes_commit(refs, ns) {
    Some(p) => [p]
    None => []
  }
  let now = clock.now()
  let commit = @git.Commit::new(
    new_tree_id,
    parents,
    "Hub <hub@local>",
    now,
    "+0000",
    "Hub <hub@local>",
    now,
    "+0000",
    "Remove note for \{short_hex_note(commit_hex, 8)}...\n",
  )
  let commit_bytes = @git.serialize_commit_content(commit)
  let new_commit_id = objects.put(@git.ObjectType::Commit, commit_bytes)
  let ref_name = notes_ref_prefix + ns
  refs.update(ref_name, Some(new_commit_id))
}
