///|
/// Fs whitebox tests
test "path: normalize_path removes leading and trailing slashes" {
  assert_eq(normalize_path("/foo/bar/"), "foo/bar")
  assert_eq(normalize_path("./foo"), "foo")
  assert_eq(normalize_path("foo"), "foo")
  assert_eq(normalize_path("/"), "")
}

///|
test "path: split_path splits into components" {
  assert_eq(split_path("a/b/c"), ["a", "b", "c"])
  assert_eq(split_path("/a/b/"), ["a", "b"])
  assert_eq(split_path(""), [])
}

///|
test "path: parent_dir returns parent directory" {
  assert_eq(parent_dir("/a/b/c"), "/a/b")
  assert_eq(parent_dir("/a"), "/")
  assert_eq(parent_dir("a"), "")
}

///|
test "path: basename returns file name" {
  assert_eq(basename("/a/b/c"), "c")
  assert_eq(basename("foo"), "foo")
}

///|
test "path: split_first splits at first slash" {
  assert_eq(split_first("a/b/c"), ("a", Some("b/c")))
  assert_eq(split_first("foo"), ("foo", None))
}

///|
test "cache: blob cache with LRU eviction" {
  let cache = ObjectCache::new(100)
  let data1 = Bytes::from_array([b'a', b'b', b'c'])
  let data2 = Bytes::from_array([b'd', b'e', b'f'])
  cache.set_blob("file1", data1)
  cache.set_blob("file2", data2)
  assert_eq(cache.get_blob("file1").unwrap(), data1)
  assert_eq(cache.get_blob("file2").unwrap(), data2)
  assert_eq(cache.blob_cache.total_bytes(), 6)
}

///|
test "cache: blob eviction when over limit" {
  let cache = ObjectCache::new(10)
  let data1 = Bytes::from_array([b'a', b'b', b'c', b'd', b'e'])
  let data2 = Bytes::from_array([b'1', b'2', b'3', b'4', b'5'])
  let data3 = Bytes::from_array([b'x', b'y', b'z'])
  cache.set_blob("file1", data1)
  cache.set_blob("file2", data2)
  assert_eq(cache.blob_cache.total_bytes(), 10)
  cache.set_blob("file3", data3)
  // Two-generation LRU evicts entire cold generation at once
  // file1 and file2 were moved to cold, then evicted
  assert_true(cache.get_blob("file1") is None)
  assert_true(cache.get_blob("file2") is None)
  assert_eq(cache.get_blob("file3").unwrap(), data3)
}

///|
test "cache: path cache invalidation" {
  let cache = ObjectCache::new(1000)
  let id = @git.ObjectId::zero()
  cache.set_path("a/b/c", Some(id))
  cache.set_path("a/b/d", Some(id))
  cache.set_path("a/x", Some(id))
  assert_true(cache.get_path("a/b/c") is Some(_))
  cache.invalidate_path("a/b")
  assert_true(cache.get_path("a/b/c") is None)
  assert_true(cache.get_path("a/b/d") is None)
  assert_true(cache.get_path("a/x") is Some(_))
}

///|
test "cache: tree cache" {
  let cache = ObjectCache::new(1000)
  let id = @git.ObjectId::zero()
  let entries = [@git.TreeEntry::new("100644", "file.txt", id)]
  cache.set_tree(id, entries)
  assert_true(cache.get_tree(id) is Some(_))
}

///|
test "working_layer: clear resets state" {
  let layer = WorkingLayer::new()
  layer.files["test.txt"] = Bytes::from_array([b'a'])
  layer.deleted["old.txt"] = true
  layer.dirs["dir"] = true
  layer.dirty = true
  layer.clear()
  assert_eq(layer.files.length(), 0)
  assert_eq(layer.deleted.length(), 0)
  assert_eq(layer.dirs.length(), 0)
  assert_eq(layer.dirty, false)
}

///|
test "ensure_parent_dirs creates parent directories" {
  let layer = WorkingLayer::new()
  ensure_parent_dirs(layer, "a/b/c/file.txt")
  assert_true(layer.dirs.contains("a"))
  assert_true(layer.dirs.contains("a/b"))
  assert_true(layer.dirs.contains("a/b/c"))
  assert_false(layer.dirs.contains("a/b/c/file.txt"))
}
