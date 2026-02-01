///| Kv - Git-based distributed KV store with Gossip sync

///|

///| Architecture:

///| - Hierarchical keys mapped to Git tree structure

///| - Values stored as Git blobs

///| - Gossip protocol for P2P sync (Cloudflare Workers compatible)

///| - CRDT-style merge for conflict resolution

///|
/// Node identifier in the gossip network
pub(all) struct NodeId {
  id : String
}

///|
pub fn NodeId::new(id : String) -> NodeId {
  { id, }
}

///|
pub impl Show for NodeId with output(self, logger) {
  logger.write_string(self.id)
}

///|
pub impl Eq for NodeId with equal(self, other) {
  self.id == other.id
}

///|
pub impl Hash for NodeId with hash_combine(self, hasher) {
  self.id.hash_combine(hasher)
}

///|
/// Vector clock for causal ordering
pub(all) struct VectorClock {
  clocks : Map[String, Int64] // node_id -> logical time
}

///|
pub fn VectorClock::new() -> VectorClock {
  { clocks: {} }
}

///|
pub fn VectorClock::increment(self : VectorClock, node : NodeId) -> VectorClock {
  let clocks = self.clocks.copy()
  let current = clocks.get(node.id).unwrap_or(0L)
  clocks[node.id] = current + 1L
  { clocks, }
}

///|
pub fn VectorClock::merge(
  self : VectorClock,
  other : VectorClock,
) -> VectorClock {
  let clocks : Map[String, Int64] = {}
  for entry in self.clocks {
    clocks[entry.0] = entry.1
  }
  for entry in other.clocks {
    let current = clocks.get(entry.0).unwrap_or(0L)
    if entry.1 > current {
      clocks[entry.0] = entry.1
    }
  }
  { clocks, }
}

///|
/// Compare vector clocks: -1 = before, 0 = concurrent, 1 = after
pub fn VectorClock::compare(self : VectorClock, other : VectorClock) -> Int {
  let mut dominated = false
  let mut dominates = false
  // Check all keys from both clocks
  let all_keys : Map[String, Bool] = {}
  for entry in self.clocks {
    all_keys[entry.0] = true
  }
  for entry in other.clocks {
    all_keys[entry.0] = true
  }
  for entry in all_keys {
    let key = entry.0
    let self_val = self.clocks.get(key).unwrap_or(0L)
    let other_val = other.clocks.get(key).unwrap_or(0L)
    if self_val < other_val {
      dominated = true
    }
    if self_val > other_val {
      dominates = true
    }
  }
  if dominated && dominates {
    0 // Concurrent
  } else if dominated {
    -1 // Self is before other
  } else if dominates {
    1 // Self is after other
  } else {
    0 // Equal
  }
}

///|
/// State of a node in the gossip network
pub(all) struct GossipState {
  node_id : NodeId
  head : @git.ObjectId // Current HEAD commit
  clock : VectorClock
  timestamp : Int64 // Wall clock (for tie-breaking)
}

///|
/// Message types for gossip protocol
pub(all) enum GossipMessage {
  /// Periodic state announcement
  Announce(GossipState)
  /// Request objects by hash
  WantObjects(Array[@git.ObjectId])
  /// Send objects
  HaveObjects(Array[GitObject])
  /// Request sync with specific node
  SyncRequest(NodeId, @git.ObjectId) // from, their_head
  /// Sync response with missing objects
  SyncResponse(Array[GitObject], @git.ObjectId) // objects, new_head
}

///|
/// Serialized git object for transfer
pub(all) struct GitObject {
  id : @git.ObjectId
  obj_type : @git.ObjectType
  data : Bytes
}

///|
/// Peer information
pub(all) struct PeerInfo {
  node_id : NodeId
  last_seen : Int64
  head : @git.ObjectId
  endpoint : String // e.g., "wss://worker.example.com/node/abc"
}

///|
/// Main Kv structure
pub struct Kv {
  node_id : NodeId
  bitfs : @fs.Fs
  mut clock : VectorClock
  mut head : @git.ObjectId
  peers : Map[String, PeerInfo] // node_id -> peer
  pending_objects : Map[String, GitObject] // object_id hex -> object
}

///|
/// Configuration for Kv
pub(all) struct KvConfig {
  node_id : NodeId
  bitfs_config : @fs.FsConfig
  max_peers : Int
  gossip_interval_ms : Int
  sync_batch_size : Int
}

///|
pub fn KvConfig::default(node_id : NodeId) -> KvConfig {
  {
    node_id,
    bitfs_config: @fs.FsConfig::default(),
    max_peers: 32,
    gossip_interval_ms: 5000,
    sync_batch_size: 100,
  }
}

///|
/// Merge strategy for conflicts
pub(all) enum MergeStrategy {
  /// Last-write-wins based on vector clock + timestamp
  LastWriteWins
  /// Keep both versions (creates conflict markers)
  KeepBoth
  /// Custom resolver function
  Custom((Bytes, Bytes) -> Bytes)
}

///|
/// Result of a sync operation
pub(all) struct SyncResult {
  objects_sent : Int
  objects_received : Int
  conflicts : Array[String] // paths with conflicts
  new_head : @git.ObjectId
}
