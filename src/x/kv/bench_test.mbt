///| Benchmarks for hot/cold serialization

///|
/// Create test data with specified size
fn create_test_db(
  fs : @git.TestFs,
  file_count : Int,
  file_size : Int,
) -> Kv raise @git.GitError {
  @lib.init_repo(fs, "/repo")
  let db = Kv::empty(NodeId::new("bench-node"), "/repo/.git")
  // Create files with different content to avoid dedup
  for i = 0; i < file_count; i = i + 1 {
    let path = "dir" +
      (i / 10).to_string() +
      "/file" +
      (i % 10).to_string() +
      ".txt"
    let content = Bytes::make(file_size, (i % 256).to_byte())
    db.set(path, content)
  }
  // Commit
  let _ = db.commit(fs, fs, "Initial commit", 1000L)
  db
}

///|
/// Benchmark: Serialize small snapshot (10 files, 1KB each)
test "bench: serialize small snapshot (10 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 10, 1024)
  b.bench(fn() { b.keep(db.serialize_snapshot(fs)) })
}

///|
/// Benchmark: Serialize medium snapshot (100 files, 1KB each)
test "bench: serialize medium snapshot (100 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 100, 1024)
  b.bench(fn() { b.keep(db.serialize_snapshot(fs)) })
}

///|
/// Benchmark: Serialize large snapshot (100 files, 10KB each)
test "bench: serialize large snapshot (100 files x 10KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 100, 10240)
  b.bench(fn() { b.keep(db.serialize_snapshot(fs)) })
}

///|
/// Benchmark: Snapshot to bytes (full pipeline)
test "bench: snapshot to bytes (10 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 10, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot(fs)
    b.keep(snapshot.to_bytes())
  })
}

///|
/// Benchmark: Snapshot to bytes (100 files)
test "bench: snapshot to bytes (100 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 100, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot(fs)
    b.keep(snapshot.to_bytes())
  })
}

///|
/// Benchmark: Bytes to snapshot (deserialization)
test "bench: bytes to snapshot (10 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 10, 1024)
  let snapshot = db.serialize_snapshot(fs)
  let bytes = snapshot.to_bytes()
  b.bench(fn() { b.keep(SerializedSnapshot::from_bytes(bytes)) })
}

///|
/// Benchmark: Bytes to snapshot (100 files)
test "bench: bytes to snapshot (100 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 100, 1024)
  let snapshot = db.serialize_snapshot(fs)
  let bytes = snapshot.to_bytes()
  b.bench(fn() { b.keep(SerializedSnapshot::from_bytes(bytes)) })
}

///|
/// Benchmark: Round-trip (serialize + deserialize)
test "bench: round-trip (10 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 10, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot(fs)
    let bytes = snapshot.to_bytes()
    b.keep(SerializedSnapshot::from_bytes(bytes))
  })
}

///|
/// Benchmark: Round-trip (100 files)
test "bench: round-trip (100 files x 1KB)" (b : @bench.T) {
  let fs = @git.TestFs::new()
  let db = try! create_test_db(fs, 100, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot(fs)
    let bytes = snapshot.to_bytes()
    b.keep(SerializedSnapshot::from_bytes(bytes))
  })
}

///|
/// Test: Verify serialization correctness
test "serialization: round-trip preserves data" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  let db = Kv::empty(NodeId::new("test-node"), "/repo/.git")
  // Add some data
  db.set("users/alice", b"Alice")
  db.set("users/bob", b"Bob")
  db.set("config/version", b"1.0.0")
  let _ = db.commit(fs, fs, "Test commit", 12345L)
  // Serialize
  let snapshot = db.serialize_snapshot(fs)
  let bytes = snapshot.to_bytes()
  // Deserialize
  let restored = SerializedSnapshot::from_bytes(bytes)
  // Verify
  assert_eq(restored.version, 1)
  assert_eq(restored.node_id, "test-node")
  assert_eq(restored.objects.length(), snapshot.objects.length())
  // Verify clock
  assert_eq(restored.clock.length(), snapshot.clock.length())
}

///|
/// Test: Statistics calculation
test "serialization: stats" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  let db = Kv::empty(NodeId::new("test-node"), "/repo/.git")
  db.set("file1.txt", Bytes::make(100, b'a'))
  db.set("file2.txt", Bytes::make(200, b'b'))
  let _ = db.commit(fs, fs, "Test", 1000L)
  let snapshot = db.serialize_snapshot(fs)
  let stats = snapshot.stats()
  assert_eq(stats.commit_count, 1)
  assert_true(stats.tree_count >= 1)
  assert_eq(stats.blob_count, 2)
  assert_eq(stats.blob_bytes, 300)
  println("Stats: \{stats.total_bytes} bytes, \{stats.object_count} objects")
}

///|
/// Demo: Show serialization overhead
test "demo: serialization overhead" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  let db = Kv::empty(NodeId::new("demo-node"), "/repo/.git")
  // Create 50 files of 2KB each = 100KB raw data
  for i = 0; i < 50; i = i + 1 {
    // Use different content for each file to avoid dedup
    let file_content = Bytes::make(2048, (i % 256).to_byte())
    db.set("file\{i}.txt", file_content)
  }
  let _ = db.commit(fs, fs, "50 files", 1000L)
  let snapshot = db.serialize_snapshot(fs)
  let bytes = snapshot.to_bytes()
  let stats = snapshot.stats()
  let raw_size = 50 * 2048
  let overhead = (bytes.length() - raw_size) * 100 / raw_size
  println("Raw data: \{raw_size} bytes")
  println("Serialized: \{bytes.length()} bytes")
  println("Overhead: \{overhead}%")
  println(
    "Objects: \{stats.object_count} (commits: \{stats.commit_count}, trees: \{stats.tree_count}, blobs: \{stats.blob_count})",
  )
}
