///| Gossip protocol implementation

///|

///| Gossip protocol flow:

///| 1. Each node periodically broadcasts its state (Announce)

///| 2. When receiving an Announce, compare HEADs

///| 3. If different, initiate sync (SyncRequest/SyncResponse)

///| 4. Merge received objects and update local state

///|
/// Get current gossip state
pub fn Kv::get_gossip_state(self : Kv, timestamp : Int64) -> GossipState {
  { node_id: self.node_id, head: self.head, clock: self.clock, timestamp }
}

///|
/// Add or update a peer
pub fn Kv::add_peer(self : Kv, peer : PeerInfo) -> Unit {
  self.peers[peer.node_id.id] = peer
}

///|
/// Remove a peer
pub fn Kv::remove_peer(self : Kv, node_id : NodeId) -> Bool {
  if self.peers.contains(node_id.id) {
    self.peers.remove(node_id.id)
    true
  } else {
    false
  }
}

///|
/// Get all peers
pub fn Kv::get_peers(self : Kv) -> Array[PeerInfo] {
  let result : Array[PeerInfo] = []
  for entry in self.peers {
    result.push(entry.1)
  }
  result
}

///|
/// Select random peers for gossip (anti-entropy)
pub fn Kv::select_gossip_peers(
  self : Kv,
  count : Int,
  seed : Int64,
) -> Array[PeerInfo] {
  let peers = self.get_peers()
  if peers.length() <= count {
    return peers
  }
  // Simple deterministic selection based on seed
  let selected : Array[PeerInfo] = []
  let mut current_seed = seed
  let used : Map[Int, Bool] = {}
  while selected.length() < count && used.length() < peers.length() {
    current_seed = (current_seed * 1103515245L + 12345L) % 2147483648L
    let idx = (current_seed % peers.length().to_int64()).to_int()
    if not(used.contains(idx)) {
      used[idx] = true
      selected.push(peers[idx])
    }
  }
  selected
}

///|
/// Handle incoming gossip message
/// Returns optional response message
pub fn Kv::handle_gossip(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  msg : GossipMessage,
  timestamp : Int64,
) -> GossipMessage? {
  match msg {
    Announce(state) => self.handle_announce(state, timestamp)
    WantObjects(ids) => self.handle_want_objects(backing_fs, ids)
    HaveObjects(objects) => {
      self.handle_have_objects(objects)
      None
    }
    SyncRequest(from, their_head) =>
      self.handle_sync_request(backing_fs, from, their_head)
    SyncResponse(objects, new_head) => {
      self.handle_sync_response(objects, new_head)
      None
    }
  }
}

///|
fn Kv::handle_announce(
  self : Kv,
  state : GossipState,
  timestamp : Int64,
) -> GossipMessage? {
  // Update peer info
  let peer : PeerInfo = {
    node_id: state.node_id,
    last_seen: timestamp,
    head: state.head,
    endpoint: "", // Will be set by transport layer
  }
  self.add_peer(peer)
  // If their head is different, request sync
  if state.head != self.head && state.head != @git.ObjectId::zero() {
    // Compare vector clocks
    let cmp = self.clock.compare(state.clock)
    if cmp < 0 {
      // We're behind, request sync
      Some(SyncRequest(self.node_id, self.head))
    } else if cmp == 0 && state.head.to_hex() > self.head.to_hex() {
      // Concurrent, use hash as tie-breaker
      Some(SyncRequest(self.node_id, self.head))
    } else {
      None
    }
  } else {
    None
  }
}

///|
fn Kv::handle_want_objects(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  ids : Array[@git.ObjectId],
) -> GossipMessage? {
  let objects : Array[GitObject] = []
  let db = self.bitfs.get_db(backing_fs) catch { _ => return None }
  for id in ids {
    let obj = db.get(backing_fs, id) catch { _ => continue }
    guard obj is Some(o) else { continue }
    objects.push({ id, obj_type: o.obj_type, data: o.data })
  }
  if objects.length() > 0 {
    Some(HaveObjects(objects))
  } else {
    None
  }
}

///|
fn Kv::handle_have_objects(self : Kv, objects : Array[GitObject]) -> Unit {
  for obj in objects {
    self.pending_objects[obj.id.to_hex()] = obj
  }
}

///|
fn Kv::handle_sync_request(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  _from : NodeId,
  their_head : @git.ObjectId,
) -> GossipMessage? {
  // Find objects they don't have
  let missing = self.find_missing_objects(backing_fs, their_head)
  if missing.length() > 0 || self.head != their_head {
    Some(SyncResponse(missing, self.head))
  } else {
    None
  }
}

///|
fn Kv::handle_sync_response(
  self : Kv,
  objects : Array[GitObject],
  _new_head : @git.ObjectId,
) -> Unit {
  // Store received objects for later processing
  for obj in objects {
    self.pending_objects[obj.id.to_hex()] = obj
  }
  // Note: actual merge is done by apply_pending_sync
}

///|
/// Find objects that the peer is missing
/// This does a simple walk from our HEAD to their HEAD
fn Kv::find_missing_objects(
  self : Kv,
  backing_fs : &@git.RepoFileSystem,
  their_head : @git.ObjectId,
) -> Array[GitObject] {
  let result : Array[GitObject] = []
  if self.head == their_head || self.head == @git.ObjectId::zero() {
    return result
  }
  let db = self.bitfs.get_db(backing_fs) catch { _ => return result }
  // Collect objects reachable from our HEAD
  let our_objects : Map[String, Bool] = {}
  collect_reachable_objects(db, backing_fs, self.head, our_objects)
  // Collect objects reachable from their HEAD
  let their_objects : Map[String, Bool] = {}
  if their_head != @git.ObjectId::zero() {
    collect_reachable_objects(db, backing_fs, their_head, their_objects)
  }
  // Find objects we have that they don't
  for entry in our_objects {
    if not(their_objects.contains(entry.0)) {
      let id = @git.ObjectId::from_hex(entry.0) catch { _ => continue }
      let obj = db.get(backing_fs, id) catch { _ => continue }
      guard obj is Some(o) else { continue }
      result.push({ id, obj_type: o.obj_type, data: o.data })
    }
  }
  result
}

///|
fn collect_reachable_objects(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  start : @git.ObjectId,
  result : Map[String, Bool],
) -> Unit {
  if start == @git.ObjectId::zero() {
    return
  }
  let hex = start.to_hex()
  if result.contains(hex) {
    return
  }
  result[hex] = true
  let obj = db.get(backing_fs, start) catch { _ => return }
  guard obj is Some(o) else { return }
  match o.obj_type {
    Commit => {
      let commit = @git.parse_commit(o.data) catch { _ => return }
      collect_reachable_objects(db, backing_fs, commit.tree, result)
      for parent in commit.parents {
        collect_reachable_objects(db, backing_fs, parent, result)
      }
    }
    Tree => {
      let entries = @git.parse_tree(o.data) catch { _ => return }
      for entry in entries {
        collect_reachable_objects(db, backing_fs, entry.id, result)
      }
    }
    Blob | Tag => ()
  }
}

///|
/// Apply pending objects from sync
/// Returns number of objects applied
pub fn Kv::apply_pending_objects(
  self : Kv,
  write_fs : &@git.FileSystem,
  git_dir : String,
) -> Int raise @git.GitError {
  let mut count = 0
  for entry in self.pending_objects {
    let obj = entry.1
    let _ = @lib.write_loose_object(write_fs, git_dir, obj.obj_type, obj.data)
    count = count + 1
  }
  self.pending_objects.clear()
  count
}

///|
/// Check if we have pending objects to apply
pub fn Kv::has_pending_objects(self : Kv) -> Bool {
  self.pending_objects.length() > 0
}

///|
/// Get count of pending objects
pub fn Kv::pending_object_count(self : Kv) -> Int {
  self.pending_objects.length()
}
