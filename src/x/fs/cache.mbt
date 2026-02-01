///| Object cache with two-generation LRU

///|
pub fn ObjectCache::get_blob(self : ObjectCache, path : String) -> Bytes? {
  self.blob_cache.get(path)
}

///|
pub fn ObjectCache::set_blob(
  self : ObjectCache,
  path : String,
  data : Bytes,
) -> Unit {
  self.blob_cache.set(path, data)
}

///|
pub fn ObjectCache::get_tree(
  self : ObjectCache,
  tree_id : @git.ObjectId,
) -> Array[@git.TreeEntry]? {
  self.trees.get(tree_id) // Direct ObjectId lookup, no hex conversion
}

///|
pub fn ObjectCache::set_tree(
  self : ObjectCache,
  tree_id : @git.ObjectId,
  entries : Array[@git.TreeEntry],
) -> Unit {
  self.trees[tree_id] = entries // Direct ObjectId key
}

///|
pub fn ObjectCache::get_path(
  self : ObjectCache,
  path : String,
) -> @git.ObjectId?? {
  self.path_cache.get(path)
}

///|
pub fn ObjectCache::set_path(
  self : ObjectCache,
  path : String,
  id : @git.ObjectId?,
) -> Unit {
  self.path_cache[path] = id
}

///|
pub fn ObjectCache::invalidate_path(self : ObjectCache, path : String) -> Unit {
  self.path_cache.remove(path)
  let prefix = path + "/"
  let to_remove : Array[String] = []
  for item in self.path_cache.to_array() {
    let (k, _) = item
    if k.has_prefix(prefix) {
      to_remove.push(k)
    }
  }
  for k in to_remove {
    self.path_cache.remove(k)
  }
}

///|
pub fn ObjectCache::clear(self : ObjectCache) -> Unit {
  self.blob_cache.clear()
  self.trees.clear()
  self.path_cache.clear()
}
