///| Adapter: wraps @kv.Kv as a KvStore for agent coordination

///|
priv struct BitKvAdapter {
  kv : @kv.Kv
}

///|
impl @agent.KvStore for BitKvAdapter with get_string(self, key) {
  match self.kv.get(key) {
    Some(bytes) => @utf8.decode_lossy(bytes[:])
    None => ""
  }
}

///|
impl @agent.KvStore for BitKvAdapter with set_string(self, key, value) {
  self.kv.set_string(key, value)
}

///|
impl @agent.KvStore for BitKvAdapter with delete(self, key) {
  self.kv.delete(key)
}

///|
impl @agent.KvStore for BitKvAdapter with list(self, prefix) {
  self.kv.list(prefix)
}

///|
impl @agent.KvStore for BitKvAdapter with list_recursive(self, prefix) {
  self.kv.list_recursive(prefix)
}

///|
impl @agent.KvStore for BitKvAdapter with commit(self, message) {
  ignore(self.kv.commit(message, 0L) catch { _ => @git.ObjectId::zero() })
}

///|
/// Factory for creating a KvStore backed by @kv.Kv
pub fn bit_kv_store(
  node_id : String,
  tree : &@lib.WorkingTree,
  store : &@lib.ObjectStore,
) -> &@agent.KvStore {
  let kv = @kv.Kv::new(
    @kv.NodeId::new(node_id),
    tree,
    store,
    @git.ObjectId::zero(),
  )
  let adapter : BitKvAdapter = { kv, }
  adapter
}
