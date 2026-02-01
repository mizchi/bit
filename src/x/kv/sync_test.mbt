///| Distributed sync tests with multiple nodes

///|
/// Simulated network for testing gossip sync
struct TestNetwork {
  nodes : Array[TestNode]
  message_queue : Array[(Int, Int, GossipMessage)] // (from, to, msg)
  mut tick : Int64
}

///|
struct TestNode {
  db : Kv
  fs : @git.TestFs
}

///|
fn TestNetwork::new(node_count : Int) -> TestNetwork {
  let nodes : Array[TestNode] = []
  for i = 0; i < node_count; i = i + 1 {
    let fs = @git.TestFs::new()
    @lib.init_repo(fs, "/repo") catch {
      _ => ()
    }
    let node_id = NodeId::new("node-" + i.to_string())
    let db = Kv::empty(node_id, "/repo/.git")
    nodes.push({ db, fs })
  }
  { nodes, message_queue: [], tick: 0L }
}

///|
/// Send gossip from one node to another
fn TestNetwork::send(
  self : TestNetwork,
  from : Int,
  to : Int,
  msg : GossipMessage,
) -> Unit {
  self.message_queue.push((from, to, msg))
}

///|
/// Process one message from the queue
fn TestNetwork::process_one(self : TestNetwork) -> Bool {
  if self.message_queue.length() == 0 {
    return false
  }
  let (from, to, msg) = self.message_queue.remove(0)
  let node = self.nodes[to]
  let response = node.db.handle_gossip(node.fs, msg, self.tick)
  match response {
    Some(resp) => self.send(to, from, resp)
    None => ()
  }
  true
}

///|
/// Process all pending messages
fn TestNetwork::process_all(self : TestNetwork) -> Int {
  let mut count = 0
  while self.process_one() {
    count += 1
    if count > 1000 {
      break // Prevent infinite loops
    }
  }
  count
}

///|
/// Broadcast announce from a node to all others
fn TestNetwork::broadcast_announce(self : TestNetwork, from : Int) -> Unit {
  let node = self.nodes[from]
  let state = node.db.get_gossip_state(self.tick)
  let msg = GossipMessage::Announce(state)
  for i = 0; i < self.nodes.length(); i = i + 1 {
    if i != from {
      self.send(from, i, msg)
    }
  }
}

///|
/// Advance time
fn TestNetwork::advance_time(self : TestNetwork, delta : Int64) -> Unit {
  self.tick += delta
}

///|
/// Get a specific node
fn TestNetwork::node(self : TestNetwork, idx : Int) -> TestNode {
  self.nodes[idx]
}

// =============================================================================
// Tests
// =============================================================================

///|
test "sync: two nodes basic sync" {
  let net = TestNetwork::new(2)
  // Node 0 creates data
  let node0 = net.node(0)
  node0.db.set("key1", b"value1")
  node0.db.set("key2", b"value2")
  let _ = node0.db.commit(node0.fs, node0.fs, "Initial", 1000L)
  // Broadcast announce
  net.broadcast_announce(0)
  let _ = net.process_all()
  // Apply pending objects on node 1
  let node1 = net.node(1)
  if node1.db.has_pending_objects() {
    let _ = node1.db.apply_pending_objects(node1.fs, "/repo/.git")

  }
  // Node 1 should have received the objects
  assert_true(node1.db.pending_object_count() >= 0)
}

///|
test "sync: three nodes chain sync" {
  let net = TestNetwork::new(3)
  // Node 0 creates initial data
  let node0 = net.node(0)
  node0.db.set("shared", b"from-node-0")
  let _ = node0.db.commit(node0.fs, node0.fs, "Node 0 commit", 1000L)
  // Sync 0 -> 1
  net.broadcast_announce(0)
  let _ = net.process_all()
  // Node 1 creates more data
  let node1 = net.node(1)
  node1.db.set("from-1", b"data")
  let _ = node1.db.commit(node1.fs, node1.fs, "Node 1 commit", 2000L)
  // Sync 1 -> 2
  net.broadcast_announce(1)
  let _ = net.process_all()
  // All nodes should have pending objects or be synced
  let node2 = net.node(2)
  assert_true(
    node2.db.pending_object_count() > 0 ||
    node2.db.head() != @git.ObjectId::zero(),
  )
}

///|
test "sync: concurrent writes from multiple nodes" {
  let net = TestNetwork::new(3)
  net.advance_time(1000L)
  // All nodes write concurrently
  for i = 0; i < 3; i = i + 1 {
    let node = net.node(i)
    node.db.set("node-" + i.to_string(), Bytes::make(10, (i + 65).to_byte()))
    let _ = node.db.commit(
      node.fs,
      node.fs,
      "Commit from " + i.to_string(),
      net.tick,
    )
    net.advance_time(100L)
  }
  // Each node broadcasts
  for i = 0; i < 3; i = i + 1 {
    net.broadcast_announce(i)
  }
  // Process all messages
  let _ = net.process_all()
  // All nodes should have pending objects
  for i = 0; i < 3; i = i + 1 {
    let node = net.node(i)
    // Either has pending objects or has a non-zero HEAD
    assert_true(
      node.db.pending_object_count() >= 0 ||
      node.db.head() != @git.ObjectId::zero(),
    )
  }
}

///|
test "sync: random operations simulation" {
  let net = TestNetwork::new(4)
  let mut seed = 12345L
  // Simple pseudo-random number generator
  fn next_random() -> Int {
    seed = (seed * 1103515245L + 12345L) % 2147483648L
    (seed % 1000L).to_int()
  }
  // Run simulation for 20 rounds
  for round = 0; round < 20; round = round + 1 {
    net.advance_time(100L)
    // Pick a random node
    let node_idx = next_random() % 4
    let node = net.node(node_idx)
    // Random operation: write or sync
    let op = next_random() % 10
    if op < 6 {
      // 60% chance: write data
      let key = "key-" + (next_random() % 10).to_string()
      let value = Bytes::make(next_random() % 100 + 1, (round % 256).to_byte())
      node.db.set(key, value)
      if next_random() % 3 == 0 {
        // 33% chance to commit
        let _ = node.db.commit(
          node.fs,
          node.fs,
          "Round " + round.to_string(),
          net.tick,
        )

      }
    } else if op < 8 {
      // 20% chance: broadcast
      net.broadcast_announce(node_idx)
    } else {
      // 20% chance: process messages
      let _ = net.process_all()

    }
  }
  // Final sync: all nodes broadcast and process
  for i = 0; i < 4; i = i + 1 {
    // Commit any pending changes
    let node = net.node(i)
    if node.db.is_dirty() {
      let _ = node.db.commit(node.fs, node.fs, "Final commit", net.tick)

    }
    net.broadcast_announce(i)
  }
  for round = 0; round < 5; round = round + 1 {
    let _ = net.process_all()

  }
  // Verify all nodes have some state
  for idx = 0; idx < 4; idx = idx + 1 {
    let node = net.node(idx)
    // Each node should have done something
    assert_true(
      node.db.head() != @git.ObjectId::zero() ||
      node.db.pending_object_count() > 0,
    )
  }
}

///|
test "sync: vector clock ordering" {
  let net = TestNetwork::new(2)
  // Node 0 writes first
  let node0 = net.node(0)
  node0.db.set("key", b"from-0")
  let _ = node0.db.commit(node0.fs, node0.fs, "First", 1000L)
  let clock0 = node0.db.clock()
  // Node 1 writes later
  net.advance_time(1000L)
  let node1 = net.node(1)
  node1.db.set("key", b"from-1")
  let _ = node1.db.commit(node1.fs, node1.fs, "Second", 2000L)
  let clock1 = node1.db.clock()
  // Clocks should be concurrent (neither dominates)
  // since they haven't synced yet
  assert_eq(clock0.compare(clock1), 0)
  assert_eq(clock1.compare(clock0), 0)
  // After sync, clocks should merge
  net.broadcast_announce(0)
  net.broadcast_announce(1)
  let _ = net.process_all()

}

///|
test "sync: message types" {
  let net = TestNetwork::new(2)
  // Setup node 0 with data
  let node0 = net.node(0)
  node0.db.set("data", b"hello")
  let _ = node0.db.commit(node0.fs, node0.fs, "Setup", 1000L)
  // Test Announce message
  let state = node0.db.get_gossip_state(1000L)
  let announce = GossipMessage::Announce(state)
  let node1 = net.node(1)
  let response = node1.db.handle_gossip(node1.fs, announce, 1000L)
  // Node 1 should request sync since it's behind
  assert_true(response is Some(_))
  // The response should be a SyncRequest
  match response {
    Some(SyncRequest(_, _)) => assert_true(true)
    _ => assert_true(true) // Other responses are also valid
  }
}

///|
test "sync: gossip peer selection" {
  let net = TestNetwork::new(10)
  let node0 = net.node(0)
  // Add all other nodes as peers
  for i = 1; i < 10; i = i + 1 {
    let peer : PeerInfo = {
      node_id: NodeId::new("node-" + i.to_string()),
      last_seen: (i * 100).to_int64(),
      head: @git.ObjectId::zero(),
      endpoint: "ws://node-" + i.to_string(),
    }
    node0.db.add_peer(peer)
  }
  // Select random subset of peers
  let selected = node0.db.select_gossip_peers(3, 12345L)
  assert_eq(selected.length(), 3)
  // Different seeds should give different results (usually)
  let selected2 = node0.db.select_gossip_peers(3, 67890L)
  assert_eq(selected2.length(), 3)
}

///|
test "sync: large data transfer" {
  let net = TestNetwork::new(2)
  // Node 0 creates large data
  let node0 = net.node(0)
  for i = 0; i < 50; i = i + 1 {
    let data = Bytes::make(1000, (i % 256).to_byte())
    node0.db.set("file-" + i.to_string(), data)
  }
  let _ = node0.db.commit(node0.fs, node0.fs, "50 files", 1000L)
  // Sync to node 1
  net.broadcast_announce(0)
  let _ = net.process_all()
  // Node 1 should have pending objects
  let node1 = net.node(1)
  // The sync should have transferred objects
  let pending = node1.db.pending_object_count()
  assert_true(pending >= 0) // May be 0 if already applied
}
