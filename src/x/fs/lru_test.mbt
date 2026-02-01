///|
/// Tests for LruCache
test "lru: basic get/set" {
  let cache : LruCache[Int] = LruCache::new(100, fn(x) { x })
  cache.set("a", 10)
  cache.set("b", 20)
  assert_eq(cache.get("a"), Some(10))
  assert_eq(cache.get("b"), Some(20))
  assert_eq(cache.get("c"), None)
}

///|
test "lru: eviction" {
  let cache : LruCache[Int] = LruCache::new(50, fn(x) { x })
  // Fill cache
  cache.set("a", 20)
  cache.set("b", 20)
  assert_eq(cache.total_bytes(), 40)
  // This should trigger eviction
  cache.set("c", 20)
  // Old items should be evicted
  assert_eq(cache.get("c"), Some(20))
  assert_true(cache.total_bytes() <= 50)
}

///|
test "lru: promotion from cold to hot" {
  let cache : LruCache[Int] = LruCache::new(100, fn(x) { x })
  cache.set("a", 10)
  cache.set("b", 10)
  // Force a to cold by evicting
  cache.set("c", 90) // This triggers eviction
  // Now access a - it should be None (was evicted)
  assert_eq(cache.get("a"), None)
  // c should still exist
  assert_eq(cache.get("c"), Some(90))
}

///|
test "lru: remove" {
  let cache : LruCache[Int] = LruCache::new(100, fn(x) { x })
  cache.set("a", 10)
  cache.set("b", 20)
  cache.remove("a")
  assert_eq(cache.get("a"), None)
  assert_eq(cache.get("b"), Some(20))
  assert_eq(cache.total_bytes(), 20)
}

///|
test "lru: clear" {
  let cache : LruCache[Int] = LruCache::new(100, fn(x) { x })
  cache.set("a", 10)
  cache.set("b", 20)
  cache.clear()
  assert_eq(cache.get("a"), None)
  assert_eq(cache.get("b"), None)
  assert_eq(cache.total_bytes(), 0)
}

///|
test "lru: oversized item rejected" {
  let cache : LruCache[Int] = LruCache::new(10, fn(x) { x })
  cache.set("a", 20) // Too large
  assert_eq(cache.get("a"), None)
  assert_eq(cache.total_bytes(), 0)
}

///|
test "lru: update existing key" {
  let cache : LruCache[Int] = LruCache::new(100, fn(x) { x })
  cache.set("a", 10)
  cache.set("a", 30)
  assert_eq(cache.get("a"), Some(30))
  assert_eq(cache.total_bytes(), 30)
}

///|
test "lru: contains" {
  let cache : LruCache[Int] = LruCache::new(100, fn(x) { x })
  cache.set("a", 10)
  assert_true(cache.contains("a"))
  assert_false(cache.contains("b"))
}

///|
test "lru: length" {
  let cache : LruCache[Int] = LruCache::new(100, fn(x) { x })
  assert_eq(cache.length(), 0)
  cache.set("a", 10)
  cache.set("b", 20)
  assert_eq(cache.length(), 2)
}
