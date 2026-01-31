///| Object cache with LRU eviction

///|
pub fn ObjectCache::get_blob(self : ObjectCache, path : String) -> Bytes? {
  self.blobs.get(path)
}

///|
pub fn ObjectCache::set_blob(
  self : ObjectCache,
  path : String,
  data : Bytes,
) -> Unit {
  let size = data.length()
  if size > self.max_blob_bytes {
    return
  }
  while self.blob_bytes + size > self.max_blob_bytes &&
        self.blob_order.length() > 0 {
    self.evict_oldest()
  }
  match self.blobs.get(path) {
    Some(old) => {
      self.blob_bytes -= old.length()
      self.remove_from_order(path)
    }
    None => ()
  }
  self.blobs[path] = data
  self.blob_bytes += size
  self.blob_order.push(path)
}

///|
fn ObjectCache::evict_oldest(self : ObjectCache) -> Unit {
  guard self.blob_order.length() > 0 else { return }
  let oldest = self.blob_order.remove(0)
  if self.blobs.get(oldest) is Some(data) {
    self.blob_bytes -= data.length()
    self.blobs.remove(oldest)
  }
}

///|
fn ObjectCache::remove_from_order(self : ObjectCache, path : String) -> Unit {
  let mut i = 0
  while i < self.blob_order.length() {
    if self.blob_order[i] == path {
      let _ = self.blob_order.remove(i)
      return
    }
    i += 1
  }
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
  self.blobs.clear()
  self.trees.clear()
  self.path_cache.clear()
  self.blob_bytes = 0
  self.blob_order.clear()
}
