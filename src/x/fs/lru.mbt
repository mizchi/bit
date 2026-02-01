///| Efficient LRU cache using two-generation approach

///|

///| Instead of tracking exact order (O(n) operations), we use two maps:

///| - "hot": recently accessed items

///| - "cold": older items

///|

///| On access: move from cold to hot if needed

///| On eviction: clear cold, swap hot->cold

///|

///| This gives O(1) operations with approximate LRU semantics.

///|
pub struct LruCache[V] {
  mut hot : Map[String, V]
  mut cold : Map[String, V]
  mut hot_bytes : Int
  mut cold_bytes : Int
  max_bytes : Int
  size_fn : (V) -> Int
}

///|
pub fn[V] LruCache::new(max_bytes : Int, size_fn : (V) -> Int) -> LruCache[V] {
  { hot: {}, cold: {}, hot_bytes: 0, cold_bytes: 0, max_bytes, size_fn }
}

///|
pub fn[V] LruCache::get(self : LruCache[V], key : String) -> V? {
  // Check hot first
  match self.hot.get(key) {
    Some(v) => Some(v)
    None =>
      // Check cold, promote to hot if found
      match self.cold.get(key) {
        Some(v) => {
          // Promote to hot
          let size = (self.size_fn)(v)
          self.cold.remove(key)
          self.cold_bytes -= size
          self.hot[key] = v
          self.hot_bytes += size
          Some(v)
        }
        None => None
      }
  }
}

///|
pub fn[V] LruCache::set(self : LruCache[V], key : String, value : V) -> Unit {
  let size = (self.size_fn)(value)
  // Don't cache items larger than max
  if size > self.max_bytes {
    return
  }
  // Remove from cold if exists
  if self.cold.get(key) is Some(old) {
    self.cold_bytes -= (self.size_fn)(old)
    self.cold.remove(key)
  }
  // Remove from hot if exists
  if self.hot.get(key) is Some(old) {
    self.hot_bytes -= (self.size_fn)(old)
    self.hot.remove(key)
  }
  // Ensure space
  while self.hot_bytes + self.cold_bytes + size > self.max_bytes {
    self.evict()
  }
  // Add to hot
  self.hot[key] = value
  self.hot_bytes += size
}

///|
fn[V] LruCache::evict(self : LruCache[V]) -> Unit {
  if self.cold.length() > 0 {
    // Clear cold generation
    self.cold.clear()
    self.cold_bytes = 0
  } else if self.hot.length() > 0 {
    // Swap hot to cold
    let old_hot = self.hot
    let old_hot_bytes = self.hot_bytes
    self.hot = {}
    self.hot_bytes = 0
    self.cold = old_hot
    self.cold_bytes = old_hot_bytes
  }
}

///|
pub fn[V] LruCache::remove(self : LruCache[V], key : String) -> Unit {
  if self.hot.get(key) is Some(v) {
    self.hot_bytes -= (self.size_fn)(v)
    self.hot.remove(key)
  }
  if self.cold.get(key) is Some(v) {
    self.cold_bytes -= (self.size_fn)(v)
    self.cold.remove(key)
  }
}

///|
pub fn[V] LruCache::clear(self : LruCache[V]) -> Unit {
  self.hot.clear()
  self.cold.clear()
  self.hot_bytes = 0
  self.cold_bytes = 0
}

///|
pub fn[V] LruCache::total_bytes(self : LruCache[V]) -> Int {
  self.hot_bytes + self.cold_bytes
}

///|
pub fn[V] LruCache::length(self : LruCache[V]) -> Int {
  self.hot.length() + self.cold.length()
}

///|
pub fn[V] LruCache::contains(self : LruCache[V], key : String) -> Bool {
  self.hot.contains(key) || self.cold.contains(key)
}
