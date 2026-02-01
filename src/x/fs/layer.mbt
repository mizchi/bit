///| Layer management (overlayfs-style)

///|
pub fn Fs::add_layer(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  name : String,
  commit_id? : @git.ObjectId? = None,
) -> Unit raise @git.GitError {
  let db = self.get_db(backing_fs)
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Tree not found: \{tree_id}")
  }
  if o.obj_type != @git.ObjectType::Tree {
    raise @git.GitError::InvalidObject("Not a tree: \{tree_id}")
  }
  self.layers.insert(0, { tree_id, commit_id, name })
  self.cache.clear()
}

///|
pub fn Fs::add_layer_from_commit(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  name : String,
) -> Unit raise @git.GitError {
  let db = self.get_db(backing_fs)
  let obj = db.get(backing_fs, commit_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Commit not found: \{commit_id}")
  }
  if o.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Not a commit: \{commit_id}")
  }
  let info = @git.parse_commit(o.data)
  self.add_layer(backing_fs, info.tree, name, commit_id=Some(commit_id))
}

///|
pub fn Fs::remove_layer(self : Fs, name : String) -> Bool {
  let mut i = 0
  while i < self.layers.length() {
    if self.layers[i].name == name {
      let _ = self.layers.remove(i)
      self.cache.clear()
      return true
    }
    i += 1
  }
  false
}

///|
pub fn Fs::list_layers(self : Fs) -> Array[Layer] {
  self.layers.copy()
}

///|
pub fn Fs::flatten_layers(
  self : Fs,
  backing_fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
) -> @git.ObjectId raise @git.GitError {
  if self.layers.length() == 0 && not(self.working.is_dirty()) {
    return self.base_tree
  }
  let root = TreeNode::new_dir()
  let db = self.get_db(rfs)
  if self.base_tree != @git.ObjectId::zero() {
    load_tree_recursive(db, rfs, self.base_tree, root)
  }
  let mut i = self.layers.length() - 1
  while i >= 0 {
    let layer = self.layers[i]
    merge_tree_into(db, rfs, layer.tree_id, root)
    i -= 1
  }
  for item in self.working.deleted.to_array() {
    let (path, _) = item
    delete_from_tree(root, path)
  }
  for item in self.working.files.to_array() {
    let (path, content) = item
    let blob_id = @lib.write_loose_object(
      backing_fs,
      self.git_dir,
      @git.ObjectType::Blob,
      content,
    )
    insert_into_tree(root, path, blob_id, 0o100644)
  }
  write_tree_recursive(backing_fs, self.git_dir, root)
}

///|
fn merge_tree_into(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  target : TreeNode,
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
      // Check if target has existing directory to merge into
      if target.children.get(entry.name) is Some(existing) &&
        existing.blob_id is None {
        merge_tree_into(db, rfs, entry.id, existing)
      } else {
        let child = TreeNode::new_dir()
        load_tree_recursive(db, rfs, entry.id, child)
        target.children[entry.name] = child
      }
    } else {
      let mode = parse_octal(entry.mode)
      target.children[entry.name] = TreeNode::new_file(entry.id, mode)
    }
  }
}

///|
pub fn Fs::clear_layers(self : Fs) -> Unit {
  self.layers.clear()
  self.cache.clear()
}

///|
pub fn Fs::has_layer(self : Fs, name : String) -> Bool {
  self.layers.iter().any(fn(layer) { layer.name == name })
}
