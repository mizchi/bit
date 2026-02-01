///|
/// Tests for Kv
test "VectorClock: increment and merge" {
  let node1 = NodeId::new("node1")
  let node2 = NodeId::new("node2")
  let clock1 = VectorClock::new().increment(node1).increment(node1)
  let clock2 = VectorClock::new().increment(node2)
  // clock1 has node1=2, clock2 has node2=1
  assert_eq(clock1.clocks.get("node1"), Some(2L))
  assert_eq(clock2.clocks.get("node2"), Some(1L))
  // Merge
  let merged = clock1.merge(clock2)
  assert_eq(merged.clocks.get("node1"), Some(2L))
  assert_eq(merged.clocks.get("node2"), Some(1L))
}

///|
test "VectorClock: compare" {
  let node1 = NodeId::new("node1")
  let node2 = NodeId::new("node2")
  // clock1: {node1: 2}
  let clock1 = VectorClock::new().increment(node1).increment(node1)
  // clock2: {node1: 1}
  let clock2 = VectorClock::new().increment(node1)
  // clock1 is after clock2
  assert_eq(clock1.compare(clock2), 1)
  assert_eq(clock2.compare(clock1), -1)
  // Concurrent clocks
  let clock3 = VectorClock::new().increment(node2)
  assert_eq(clock1.compare(clock3), 0) // Concurrent
}

///|
test "normalize_key" {
  // Test internal function via public API
  let db = Kv::empty(NodeId::new("test"), "/tmp/test")
  // Leading and trailing slashes should be removed
  db.set("/path/to/key/", b"value")
  // The key should be stored as "path/to/key"
  let files = db.bitfs.get_working_files()
  assert_true(files.contains("path/to/key"))
}

///|
test "Kv: basic KV operations" {
  let fs = @git.TestFs::new()
  let db = Kv::empty(NodeId::new("test"), "/repo/.git")
  // Set and get
  db.set("key1", b"value1")
  db.set("nested/path/key2", b"value2")
  let v1 = db.get(fs, "key1")
  assert_eq(v1, Some(b"value1"))
  let v2 = db.get(fs, "nested/path/key2")
  assert_eq(v2, Some(b"value2"))
  // Non-existent key
  let v3 = db.get(fs, "nonexistent")
  assert_eq(v3, None)
  // Delete
  db.delete("key1")
  let v4 = db.get(fs, "key1")
  assert_eq(v4, None)
}

///|
test "Kv: list keys" {
  let fs = @git.TestFs::new()
  let db = Kv::empty(NodeId::new("test"), "/repo/.git")
  db.set("users/alice/name", b"Alice")
  db.set("users/alice/email", b"alice@example.com")
  db.set("users/bob/name", b"Bob")
  db.set("config/version", b"1.0")
  // List users
  let users = db.list(fs, "users")
  assert_true(users.contains("alice"))
  assert_true(users.contains("bob"))
  // List alice's keys
  let alice_keys = db.list(fs, "users/alice")
  assert_true(alice_keys.contains("name"))
  assert_true(alice_keys.contains("email"))
}

///|
test "Kv: gossip state" {
  let db = Kv::empty(NodeId::new("node1"), "/repo/.git")
  let state = db.get_gossip_state(1000L)
  assert_eq(state.node_id.id, "node1")
  assert_eq(state.head, @git.ObjectId::zero())
  assert_eq(state.timestamp, 1000L)
}

///|
test "Kv: peer management" {
  let db = Kv::empty(NodeId::new("node1"), "/repo/.git")
  // Add peers
  let peer1 : PeerInfo = {
    node_id: NodeId::new("peer1"),
    last_seen: 1000L,
    head: @git.ObjectId::zero(),
    endpoint: "wss://peer1.example.com",
  }
  let peer2 : PeerInfo = {
    node_id: NodeId::new("peer2"),
    last_seen: 2000L,
    head: @git.ObjectId::zero(),
    endpoint: "wss://peer2.example.com",
  }
  db.add_peer(peer1)
  db.add_peer(peer2)
  let peers = db.get_peers()
  assert_eq(peers.length(), 2)
  // Remove peer
  let removed = db.remove_peer(NodeId::new("peer1"))
  assert_true(removed)
  let peers2 = db.get_peers()
  assert_eq(peers2.length(), 1)
}

///|
test "Kv: select gossip peers" {
  let db = Kv::empty(NodeId::new("node1"), "/repo/.git")
  // Add several peers
  for i = 0; i < 10; i = i + 1 {
    let peer : PeerInfo = {
      node_id: NodeId::new("peer" + i.to_string()),
      last_seen: i.to_int64() * 1000L,
      head: @git.ObjectId::zero(),
      endpoint: "wss://peer" + i.to_string() + ".example.com",
    }
    db.add_peer(peer)
  }
  // Select 3 random peers
  let selected = db.select_gossip_peers(3, 12345L)
  assert_eq(selected.length(), 3)
  // Select with different seed should give different result
  let selected2 = db.select_gossip_peers(3, 67890L)
  // At least one should be different (probabilistically)
  let same_count = {
    let mut count = 0
    for p1 in selected {
      for p2 in selected2 {
        if p1.node_id.id == p2.node_id.id {
          count = count + 1
        }
      }
    }
    count
  }
  // Not all should be the same
  assert_true(same_count < 3 || selected.length() < 3)
}

///|
test "Kv: commit and rollback" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  let db = Kv::empty(NodeId::new("test"), "/repo/.git")
  // Make some changes
  db.set("key1", b"value1")
  db.set("key2", b"value2")
  assert_true(db.is_dirty())
  // Commit
  let commit_id = db.commit(fs, fs, "Initial commit", 1000L)
  assert_false(db.is_dirty())
  assert_true(commit_id != @git.ObjectId::zero())
  // Make more changes
  db.set("key3", b"value3")
  assert_true(db.is_dirty())
  // Rollback
  db.rollback()
  assert_false(db.is_dirty())
  // key3 should not exist
  let v3 = db.get(fs, "key3")
  assert_eq(v3, None)
  // key1 and key2 should still exist (from commit)
  let v1 = db.get(fs, "key1")
  assert_eq(v1, Some(b"value1"))
}
