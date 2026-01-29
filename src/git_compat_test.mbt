///| Tests verifying compatibility with real Git

///|
/// All expected values were generated using git command-line tools

// =============================================================================
// Blob Hash Tests
// =============================================================================

test "git compat: blob hash 'hello' (no newline)" {
  // echo -n "hello" | git hash-object --stdin
  let id = hash_blob_string("hello")
  inspect(id.to_hex(), content="b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
}

///|
test "git compat: blob hash 'hello\\n'" {
  // echo "hello" | git hash-object --stdin
  let id = hash_blob_string("hello\n")
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

///|
test "git compat: blob hash 'world\\n'" {
  // echo "world" | git hash-object --stdin
  let id = hash_blob_string("world\n")
  inspect(id.to_hex(), content="cc628ccd10742baea8241c5924df992b5c019f71")
}

///|
test "git compat: blob hash single newline" {
  // echo "" | git hash-object --stdin
  let id = hash_blob_string("\n")
  inspect(id.to_hex(), content="8b137891791fe96927ad78e64b0aad7bded08bdc")
}

///|
test "git compat: blob hash multiline" {
  // printf "line1\nline2\nline3\n" | git hash-object --stdin
  let id = hash_blob_string("line1\nline2\nline3\n")
  inspect(id.to_hex(), content="83db48f84ec878fbfb30b46d16630e944e34f205")
}

///|
test "git compat: blob hash empty" {
  // git hash-object -t blob /dev/null
  let id = hash_blob_string("")
  inspect(id.to_hex(), content="e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
}

// =============================================================================
// Tree Hash Tests
// =============================================================================

///|
test "git compat: tree with single file" {
  // Tree containing: hello.txt -> "hello\n"
  // git write-tree after: echo "hello" > hello.txt && git add hello.txt
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let entry = @git.TreeEntry::new("100644", "hello.txt", blob_id)
  let (tree_id, _) = create_tree([entry])
  inspect(tree_id.to_hex(), content="aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7")
}

///|
test "git compat: tree with two files" {
  // Tree containing:
  //   hello.txt -> "hello\n"
  //   world.txt -> "world\n"
  // Entries must be sorted by name
  let hello_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let world_id = @git.ObjectId::from_hex(
    "cc628ccd10742baea8241c5924df992b5c019f71",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", hello_id),
    @git.TreeEntry::new("100644", "world.txt", world_id),
  ]
  let (tree_id, _) = create_tree(entries)
  inspect(tree_id.to_hex(), content="88e38705fdbd3608cddbe904b67c731f3234c45b")
}

// =============================================================================
// Commit Hash Tests
// =============================================================================

///|
test "git compat: initial commit" {
  // Commit with:
  //   tree: 88e38705fdbd3608cddbe904b67c731f3234c45b
  //   author: Test <test@example.com> 1700000000 +0000
  //   committer: Test <test@example.com> 1700000000 +0000
  //   message: Initial commit
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let commit = @git.Commit::new(
    tree_id,
    [], // no parents
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Initial commit\n",
  )
  let (commit_id, _) = create_commit(commit)
  inspect(
    commit_id.to_hex(),
    content="681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
}

// =============================================================================
// Zlib Tests
// =============================================================================

///|
test "git compat: zlib roundtrip" {
  let original = "Hello, Git!\n"
  let data : Array[Byte] = []
  for c in original {
    data.push(c.to_int().to_byte())
  }
  let bytes = Bytes::from_array(
    FixedArray::makei(data.length(), fn(i) { data[i] }),
  )
  let compressed = @zlib.zlib_compress_stored(bytes)
  let decompressed = @zlib.zlib_decompress_stored(compressed)
  assert_true(decompressed.length() == bytes.length())
  for i = 0; i < bytes.length(); i = i + 1 {
    assert_true(decompressed[i] == bytes[i])
  }
}

///|
test "git compat: zlib header" {
  let data = Bytes::from_array([b'x'])
  let compressed = @zlib.zlib_compress_stored(data)

  // Zlib header: 0x78 0x01 (deflate, fastest)
  inspect(compressed[0], content="b'\\x78'")
  inspect(compressed[1], content="b'\\x01'")
}

// =============================================================================
// Packfile Tests
// =============================================================================

///|
test "git compat: packfile header" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let packfile = create_blob_packfile(content)

  // Magic: "PACK"
  inspect(packfile[0], content="b'\\x50'") // 'P'
  inspect(packfile[1], content="b'\\x41'") // 'A'
  inspect(packfile[2], content="b'\\x43'") // 'C'
  inspect(packfile[3], content="b'\\x4B'") // 'K'

  // Version: 2 (big-endian)
  inspect(packfile[4], content="b'\\x00'")
  inspect(packfile[5], content="b'\\x00'")
  inspect(packfile[6], content="b'\\x00'")
  inspect(packfile[7], content="b'\\x02'")

  // Object count: 1 (big-endian)
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x01'")
}

///|
test "git compat: packfile with 3 objects" {
  let blob_content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o', b'\n'])
  let commit = @git.Commit::new(
    @git.ObjectId::zero(),
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test\n",
  )
  let (_, packfile) = create_commit_packfile(blob_content, "hello.txt", commit)

  // Object count should be 3 (blob, tree, commit)
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x03'")
}

// =============================================================================
// pkt-line Tests
// =============================================================================

///|
test "git compat: pktline encode" {
  // "hello\n" with 4-byte length prefix
  // Length = 6 + 4 = 10 = 0x000a
  let encoded = pktline_encode("hello\n")
  inspect(encoded[0], content="b'\\x30'") // '0'
  inspect(encoded[1], content="b'\\x30'") // '0'
  inspect(encoded[2], content="b'\\x30'") // '0'
  inspect(encoded[3], content="b'\\x61'") // 'a'
  inspect(encoded[4], content="b'\\x68'") // 'h'
}

///|
test "git compat: pktline flush" {
  // Flush packet: 0000
  let flush = pktline_flush()
  inspect(flush.length(), content="4")
  inspect(flush[0], content="b'\\x30'")
  inspect(flush[1], content="b'\\x30'")
  inspect(flush[2], content="b'\\x30'")
  inspect(flush[3], content="b'\\x30'")
}

///|
test "git compat: pktline delim" {
  // Delimiter packet: 0001
  let delim = pktline_delim()
  inspect(delim.length(), content="4")
  inspect(delim[0], content="b'\\x30'")
  inspect(delim[1], content="b'\\x30'")
  inspect(delim[2], content="b'\\x30'")
  inspect(delim[3], content="b'\\x31'")
}

// =============================================================================
// ObjectId Tests
// =============================================================================

///|
test "git compat: ObjectId zero" {
  let id = @git.ObjectId::zero()
  inspect(id.to_hex(), content="0000000000000000000000000000000000000000")
}

///|
test "git compat: ObjectId from_hex roundtrip" {
  let hex = "ce013625030ba8dba906f756967f9e9ca394464a"
  let id = @git.ObjectId::from_hex(hex)
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

// =============================================================================
// SHA-1 Known Values Tests
// =============================================================================

///|
test "git compat: SHA-1 empty string" {
  // SHA-1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
  let hash = sha1(Bytes::from_array([]))
  inspect(hash.to_hex(), content="da39a3ee5e6b4b0d3255bfef95601890afd80709")
}

///|
test "git compat: SHA-1 'abc'" {
  // SHA-1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
  let hash = sha1(Bytes::from_array([b'a', b'b', b'c']))
  inspect(hash.to_hex(), content="a9993e364706816aba3e25717850c26c9cd0d89d")
}

///|
test "git compat: SHA-1 quick brown fox" {
  // SHA-1("The quick brown fox jumps over the lazy dog")
  // = 2fd4e1c67a2d28fced849ee1bb76e7391b93eb12
  let msg = "The quick brown fox jumps over the lazy dog"
  let data : Array[Byte] = []
  for c in msg {
    data.push(c.to_int().to_byte())
  }
  let hash = sha1(
    Bytes::from_array(FixedArray::makei(data.length(), fn(i) { data[i] })),
  )
  inspect(hash.to_hex(), content="2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
}

// =============================================================================
// Nested Tree Tests
// =============================================================================

///|
test "git compat: subtree with single file" {
  // Tree containing: world.txt -> "world\n"
  // This is the "subdir" tree in a nested structure
  let world_id = @git.ObjectId::from_hex(
    "cc628ccd10742baea8241c5924df992b5c019f71",
  )
  let entry = @git.TreeEntry::new("100644", "world.txt", world_id)
  let (tree_id, _) = create_tree([entry])
  inspect(tree_id.to_hex(), content="b032d4b998c65562e088abaa88fdd859476c089e")
}

///|
test "git compat: nested tree with subdirectory" {
  // Tree containing:
  //   hello.txt -> "hello\n"
  //   subdir/   -> tree(world.txt -> "world\n")
  // Structure:
  //   .
  //   ├── hello.txt
  //   └── subdir/
  //       └── world.txt
  let hello_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let subdir_id = @git.ObjectId::from_hex(
    "b032d4b998c65562e088abaa88fdd859476c089e",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", hello_id),
    @git.TreeEntry::new("40000", "subdir", subdir_id),
  ]
  let (tree_id, _) = create_tree(entries)
  inspect(tree_id.to_hex(), content="117040856e0066e76d38c559f9d2127fd6a10858")
}

// =============================================================================
// Commit with Parent Tests
// =============================================================================

///|
test "git compat: commit with parent" {
  // Second commit with parent
  // tree: 88e38705fdbd3608cddbe904b67c731f3234c45b (hello.txt + world.txt)
  // parent: 681226a87c4a64f59b7b47bd497af25e16ac4635 (initial commit)
  // author/committer: Test <test@example.com> 1700000100 +0000
  // message: Second commit
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let parent_id = @git.ObjectId::from_hex(
    "681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
  let commit = @git.Commit::new(
    tree_id,
    [parent_id],
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Second commit\n",
  )
  let (commit_id, _) = create_commit(commit)
  // Verified against git hash-object -t commit
  inspect(
    commit_id.to_hex(),
    content="2fe96b04b8c1f081765898435f0d2497cfef21ea",
  )
}
