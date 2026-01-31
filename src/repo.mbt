///| Minimal object store + checkout helpers

///|
pub struct ObjectStore {
  objects : Map[String, PackObject]
}

///|
pub fn ObjectStore::new() -> ObjectStore {
  { objects: {} }
}

///|
pub fn ObjectStore::from_pack(objects : Array[PackObject]) -> ObjectStore {
  let store = ObjectStore::new()
  store.add_objects(objects)
  store
}

///|
pub fn ObjectStore::add_objects(
  self : ObjectStore,
  objects : Array[PackObject],
) -> Unit {
  for obj in objects {
    // Use cached id if available (offset >= 0 means it was parsed from pack)
    let id = if obj.offset >= 0 {
      obj.id
    } else {
      hash_object_content(obj.obj_type, obj.data)
    }
    self.objects[id.to_hex()] = obj
  }
}

///|
pub fn ObjectStore::get(self : ObjectStore, id : ObjectId) -> PackObject? {
  self.objects.get(id.to_hex())
}

///|
pub fn ObjectStore::contains(self : ObjectStore, id : ObjectId) -> Bool {
  match self.objects.get(id.to_hex()) {
    Some(_) => true
    None => false
  }
}

///|
pub struct CommitInfo {
  tree : ObjectId
  parents : Array[ObjectId]
}

///|
pub fn parse_commit(content : Bytes) -> CommitInfo raise GitError {
  let text = @utf8.decode_lossy(content[:])
  let mut tree_id : ObjectId? = None
  let parents : Array[ObjectId] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("tree ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      tree_id = Some(ObjectId::from_hex(hex))
    } else if line.has_prefix("parent ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      parents.push(ObjectId::from_hex(hex))
    }
  }
  match tree_id {
    Some(tree) => { tree, parents }
    None => raise GitError::InvalidObject("Missing tree in commit")
  }
}

///|
pub fn parse_tree(content : Bytes) -> Array[TreeEntry] raise GitError {
  let entries : Array[TreeEntry] = []
  let mut i = 0
  while i < content.length() {
    // Parse mode (ASCII only, so byte-by-byte is fine)
    let mode_buf = StringBuilder::new()
    while i < content.length() && content[i] != b' ' {
      mode_buf.write_char(content[i].to_int().unsafe_to_char())
      i += 1
    }
    if i >= content.length() {
      raise GitError::InvalidObject("Truncated tree entry mode")
    }
    i += 1 // skip space
    // Parse name - collect bytes and decode as UTF-8
    let name_start = i
    while i < content.length() && content[i] != b'\x00' {
      i += 1
    }
    if i >= content.length() {
      raise GitError::InvalidObject("Truncated tree entry name")
    }
    let name_len = i - name_start
    let name_bytes = FixedArray::makei(name_len, fn(j) {
      content[name_start + j]
    })
    let name = @utf8.decode_lossy(Bytes::from_array(name_bytes)[:])
    i += 1 // skip NUL
    if i + 20 > content.length() {
      raise GitError::InvalidObject("Truncated tree entry id")
    }
    let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
    for j = 0; j < 20; j = j + 1 {
      bytes[j] = content[i + j]
    }
    i += 20
    let id = ObjectId::new(bytes)
    entries.push(TreeEntry::new(mode_buf.to_string(), name, id))
  }
  entries
}

///|
pub fn checkout_commit(
  store : ObjectStore,
  commit_id : ObjectId,
) -> Map[String, Bytes] raise GitError {
  let commit_obj = store.get(commit_id)
  match commit_obj {
    None => raise GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != ObjectType::Commit {
        raise GitError::InvalidObject("Object is not a commit")
      }
      let info = parse_commit(obj.data)
      let files : Map[String, Bytes] = {}
      walk_tree(store, info.tree, "", files)
      files
    }
  }
}

///|
/// Materialize commit files into a filesystem under `root`.
pub fn checkout_commit_to_fs(
  store : ObjectStore,
  commit_id : ObjectId,
  fs : &FileSystem,
  root : String,
) -> Unit raise GitError {
  let files = checkout_commit(store, commit_id)
  for item in files.to_array() {
    let (path, data) = item
    let full_path = join_path(root, path)
    let dir = parent_dir(full_path)
    fs.mkdir_p(dir)
    fs.write_file(full_path, data)
  }
}

///|
fn walk_tree(
  store : ObjectStore,
  tree_id : ObjectId,
  prefix : String,
  files : Map[String, Bytes],
) -> Unit raise GitError {
  let tree_obj = store.get(tree_id)
  match tree_obj {
    None => raise GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != ObjectType::Tree {
        raise GitError::InvalidObject("Object is not a tree")
      }
      let entries = parse_tree(obj.data)
      for entry in entries {
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if is_tree_mode(entry.mode) {
          walk_tree(store, entry.id, path, files)
        } else {
          let blob_obj = store.get(entry.id)
          match blob_obj {
            None => raise GitError::InvalidObject("Missing blob object")
            Some(b) => {
              if b.obj_type != ObjectType::Blob {
                raise GitError::InvalidObject("Object is not a blob")
              }
              files[path] = b.data
            }
          }
        }
      }
    }
  }
}

///|
fn is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}

///|
fn join_path(root : String, path : String) -> String {
  if root.length() == 0 || root == "/" {
    if path.has_prefix("/") {
      path
    } else {
      "/" + path
    }
  } else if root.has_suffix("/") {
    root + path
  } else {
    root + "/" + path
  }
}

///|
fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}
