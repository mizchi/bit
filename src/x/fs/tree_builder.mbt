///| Differential tree construction for snapshots

///|
priv struct TreeNode {
  blob_id : @git.ObjectId?
  mode : Int
  children : Map[String, TreeNode]
}

///|
fn TreeNode::new_file(id : @git.ObjectId, mode : Int) -> TreeNode {
  { blob_id: Some(id), mode, children: {} }
}

///|
fn TreeNode::new_dir() -> TreeNode {
  { blob_id: None, mode: 0o040000, children: {} }
}

///|
pub fn build_tree_from_working(
  backing_fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  base_tree : @git.ObjectId,
  working : WorkingLayer,
) -> @git.ObjectId raise @git.GitError {
  let root = load_tree_structure(rfs, git_dir, base_tree)
  for item in working.deleted.to_array() {
    let (path, _) = item
    delete_from_tree(root, path)
  }
  for item in working.files.to_array() {
    let (path, content) = item
    let blob_id = @lib.write_loose_object(
      backing_fs,
      git_dir,
      @git.ObjectType::Blob,
      content,
    )
    insert_into_tree(root, path, blob_id, 0o100644)
  }
  write_tree_recursive(backing_fs, git_dir, root)
}

///|
fn load_tree_structure(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  tree_id : @git.ObjectId,
) -> TreeNode raise @git.GitError {
  let root = TreeNode::new_dir()
  if tree_id == @git.ObjectId::zero() {
    return root
  }
  let db = @lib.ObjectDb::load(rfs, git_dir)
  load_tree_recursive(db, rfs, tree_id, root)
  root
}

///|
fn load_tree_recursive(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  node : TreeNode,
) -> Unit raise @git.GitError {
  let obj = db.get(rfs, tree_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Tree not found: \{tree_id}")
  }
  if o.obj_type != @git.ObjectType::Tree {
    raise @git.GitError::InvalidObject("Not a tree: \{tree_id}")
  }
  let entries = @git.parse_tree(o.data)
  for entry in entries {
    if is_tree_mode(entry.mode) {
      let child = TreeNode::new_dir()
      load_tree_recursive(db, rfs, entry.id, child)
      node.children[entry.name] = child
    } else {
      let mode = parse_octal(entry.mode)
      node.children[entry.name] = TreeNode::new_file(entry.id, mode)
    }
  }
}

///|
fn delete_from_tree(root : TreeNode, path : String) -> Unit {
  let parts = split_path(path)
  guard parts.length() > 0 else { return }
  let _ = delete_recursive(root, parts, 0)

}

///|
fn delete_recursive(node : TreeNode, parts : Array[String], idx : Int) -> Bool {
  if idx >= parts.length() {
    return false
  }
  let name = parts[idx]
  if idx == parts.length() - 1 {
    node.children.remove(name)
    return true
  }
  match node.children.get(name) {
    Some(child) => {
      let deleted = delete_recursive(child, parts, idx + 1)
      if deleted && child.children.length() == 0 && child.blob_id is None {
        node.children.remove(name)
      }
      deleted
    }
    None => false
  }
}

///|
fn insert_into_tree(
  root : TreeNode,
  path : String,
  blob_id : @git.ObjectId,
  mode : Int,
) -> Unit {
  let parts = split_path(path)
  guard parts.length() > 0 else { return }
  let mut current = root
  for i = 0; i < parts.length() - 1; i = i + 1 {
    let name = parts[i]
    if current.children.get(name) is Some(child) {
      current = child
    } else {
      let child = TreeNode::new_dir()
      current.children[name] = child
      current = child
    }
  }
  let file_name = parts[parts.length() - 1]
  current.children[file_name] = TreeNode::new_file(blob_id, mode)
}

///|
fn write_tree_recursive(
  fs : &@git.FileSystem,
  git_dir : String,
  node : TreeNode,
) -> @git.ObjectId raise @git.GitError {
  let entries : Array[@git.TreeEntry] = []
  for item in node.children.to_array() {
    let (name, child) = item
    let (id, mode_str) = match child.blob_id {
      Some(blob_id) => (blob_id, mode_to_string(child.mode))
      None => {
        let subtree_id = write_tree_recursive(fs, git_dir, child)
        (subtree_id, "40000")
      }
    }
    entries.push(@git.TreeEntry::new(mode_str, name, id))
  }
  entries.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    compare_strings(a_key, b_key)
  })
  let (tree_id, compressed) = @git.create_tree(entries)
  @lib.write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn parse_octal(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
fn mode_to_string(mode : Int) -> String {
  if mode == 0o100644 {
    "100644"
  } else if mode == 0o100755 {
    "100755"
  } else if mode == 0o120000 {
    "120000"
  } else {
    to_octal_string(mode)
  }
}

///|
fn to_octal_string(value : Int) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = []
  let mut v = value
  while v > 0 {
    let d = v % 8
    digits.push((d + '0'.to_int()).unsafe_to_char())
    v = v / 8
  }
  let rev = digits.rev()
  let sb = StringBuilder::new()
  for c in rev {
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn compare_strings(a : String, b : String) -> Int {
  let a_len = a.length()
  let b_len = b.length()
  let min_len = if a_len < b_len { a_len } else { b_len }
  for i in 0..<min_len {
    let a_char = a.unsafe_get(i).to_int()
    let b_char = b.unsafe_get(i).to_int()
    if a_char < b_char {
      return -1
    } else if a_char > b_char {
      return 1
    }
  }
  if a_len < b_len {
    -1
  } else if a_len > b_len {
    1
  } else {
    0
  }
}
