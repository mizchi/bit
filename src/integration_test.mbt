///| Integration tests that verify our implementation against real git commands

///|

///| Packfile hex values can be verified with:

///| ```

///| echo "<hex>" | xxd -r -p > test.pack

///| git index-pack test.pack

///| git verify-pack -v test.pack

///| ```

// =============================================================================
// Packfile Verification Tests
// These tests create packfiles and verify them with git verify-pack
// =============================================================================

///|
test "integration: packfile structure is valid" {
  // Create a simple blob packfile
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o', b'\n'])
  let packfile = @pack.create_blob_packfile(content)

  // Verify packfile header
  // PACK magic
  assert_true(packfile[0] == b'P')
  assert_true(packfile[1] == b'A')
  assert_true(packfile[2] == b'C')
  assert_true(packfile[3] == b'K')

  // Version 2
  assert_true(packfile[4] == b'\x00')
  assert_true(packfile[5] == b'\x00')
  assert_true(packfile[6] == b'\x00')
  assert_true(packfile[7] == b'\x02')

  // Object count 1
  assert_true(packfile[8] == b'\x00')
  assert_true(packfile[9] == b'\x00')
  assert_true(packfile[10] == b'\x00')
  assert_true(packfile[11] == b'\x01')

  // Packfile should end with 20-byte SHA-1 trailer
  assert_true(packfile.length() > 32)

  // Verify the trailer is a valid SHA-1 of the packfile content
  let content_len = packfile.length() - 20
  let content_bytes : Array[Byte] = []
  for i = 0; i < content_len; i = i + 1 {
    content_bytes.push(packfile[i])
  }
  let expected_trailer = sha1_array(content_bytes)
  for i = 0; i < 20; i = i + 1 {
    assert_true(packfile[content_len + i] == expected_trailer.bytes[i])
  }
}

///|
test "integration: blob hash matches git hash-object" {
  // These values are verified against: echo "hello" | git hash-object --stdin
  let test_cases : Array[(String, String)] = [
    ("hello\n", "ce013625030ba8dba906f756967f9e9ca394464a"),
    ("world\n", "cc628ccd10742baea8241c5924df992b5c019f71"),
    ("", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    ("test content\n", "d670460b4b4aece5915caf5c68d12f560a9fe3e4"),
  ]
  for pair in test_cases {
    let (content, expected_hash) = pair
    let id = hash_blob_string(content)
    assert_true(id.to_hex() == expected_hash)
  }
}

///|
test "integration: tree format is correct" {
  // Tree entry format: {mode} {name}\0{20-byte sha}
  let blob_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let entry = TreeEntry::new("100644", "hello.txt", blob_id)
  let (tree_id, compressed) = create_tree([entry])

  // Decompress and verify format
  let decompressed = @zlib.zlib_decompress(compressed)

  // Should start with "tree {size}\0"
  assert_true(decompressed[0] == b't')
  assert_true(decompressed[1] == b'r')
  assert_true(decompressed[2] == b'e')
  assert_true(decompressed[3] == b'e')
  assert_true(decompressed[4] == b' ')

  // Tree hash should match known value
  inspect(tree_id.to_hex(), content="aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7")
}

///|
test "integration: commit format is correct" {
  let tree_id = ObjectId::from_hex("aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7")
  let commit = Commit::new(
    tree_id,
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test commit\n",
  )
  let (_, compressed) = create_commit(commit)

  // Decompress and verify format
  let decompressed = @zlib.zlib_decompress(compressed)

  // Should start with "commit {size}\0"
  assert_true(decompressed[0] == b'c')
  assert_true(decompressed[1] == b'o')
  assert_true(decompressed[2] == b'm')
  assert_true(decompressed[3] == b'm')
  assert_true(decompressed[4] == b'i')
  assert_true(decompressed[5] == b't')
  assert_true(decompressed[6] == b' ')
}

///|
test "integration: packfile object encoding" {
  // Test that object type and size are encoded correctly
  // Type 3 = blob, size 5
  let result : Array[Byte] = []
  @pack.encode_type_and_size(3, 5, result)

  // Single byte: type=3 (011), size=5 (0101) -> 0b00110101 = 0x35
  assert_true(result.length() == 1)
  assert_true(result[0] == b'\x35')

  // Type 3 = blob, size 100 (needs continuation)
  let result2 : Array[Byte] = []
  @pack.encode_type_and_size(3, 100, result2)

  // First: MSB=1, type=3, size_low=4 -> 0b10110100 = 0xb4
  // Second: MSB=0, size_rest=6 -> 0b00000110 = 0x06
  assert_true(result2.length() == 2)
  assert_true(result2[0] == b'\xB4')
  assert_true(result2[1] == b'\x06')
}

///|
test "integration: multi-object packfile" {
  // Create a packfile with blob, tree, and commit
  let blob_content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o', b'\n'])
  let commit = Commit::new(
    ObjectId::zero(),
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Initial commit\n",
  )
  let (commit_id, packfile) = @pack.create_commit_packfile(
    blob_content, "hello.txt", commit,
  )

  // Verify object count is 3
  assert_true(packfile[8] == b'\x00')
  assert_true(packfile[9] == b'\x00')
  assert_true(packfile[10] == b'\x00')
  assert_true(packfile[11] == b'\x03')

  // Commit ID should be valid (40 hex chars)
  assert_true(commit_id.to_hex().length() == 40)

  // Verify trailer
  let content_len = packfile.length() - 20
  let content_bytes : Array[Byte] = []
  for i = 0; i < content_len; i = i + 1 {
    content_bytes.push(packfile[i])
  }
  let expected_trailer = sha1_array(content_bytes)
  for i = 0; i < 20; i = i + 1 {
    assert_true(packfile[content_len + i] == expected_trailer.bytes[i])
  }
}

// =============================================================================
// pkt-line Protocol Tests
// =============================================================================

///|
test "integration: pktline ref update format" {
  let old_id = ObjectId::zero()
  let new_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let cmd = @protocol.build_ref_update_simple(old_id, new_id, "refs/heads/main")

  // Format: "{old} {new} {ref}\n"
  assert_true(cmd.has_prefix("0000000000000000000000000000000000000000 "))
  assert_true(cmd.find("ce013625030ba8dba906f756967f9e9ca394464a") is Some(_))
  assert_true(cmd.find("refs/heads/main") is Some(_))
  assert_true(cmd.has_suffix("\n"))
}

///|
test "integration: pktline with capabilities" {
  let old_id = ObjectId::zero()
  let new_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let cmd = @protocol.build_ref_update(old_id, new_id, "refs/heads/main", "report-status")

  // Should contain null byte before capabilities
  assert_true(cmd.find("\u0000") is Some(_))
  assert_true(cmd.find("report-status") is Some(_))
}

///|
test "integration: receive-pack body format" {
  let old_id = ObjectId::zero()
  let new_id = ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let packfile = Bytes::from_array([
    b'P', b'A', b'C', b'K', b'\x00', b'\x00', b'\x00', b'\x02',
  ])
  let req = @protocol.PushRequest::new(old_id, new_id, "refs/heads/main", packfile)
  let body = @protocol.build_receive_pack_body(req)

  // Body should start with pkt-line (4 hex chars)
  assert_true(body.length() > 4)

  // Should end with packfile
  let pack_start = body.length() - 8
  assert_true(body[pack_start] == b'P')
  assert_true(body[pack_start + 1] == b'A')
  assert_true(body[pack_start + 2] == b'C')
  assert_true(body[pack_start + 3] == b'K')
}

// =============================================================================
// Response Parsing Tests
// =============================================================================

///|
test "integration: parse successful push response" {
  // Simulate server response: unpack ok, ref ok
  let response = build_test_response(["unpack ok\n", "ok refs/heads/main\n"])
  let result = @protocol.parse_receive_pack_response(response)
  match result {
    Ok(msg) => assert_true(msg == "Push successful")
    Err(_) => assert_true(false)
  }
}

///|
test "integration: parse failed push response" {
  // Simulate server response: unpack error
  let response = build_test_response(["unpack error - bad pack\n"])
  let result = @protocol.parse_receive_pack_response(response)
  match result {
    Ok(_) => assert_true(false)
    Err(GitError::ProtocolError(msg)) =>
      assert_true(msg.find("unpack error") is Some(_))
    Err(_) => assert_true(false)
  }
}

// Helper to build test response

///|
fn build_test_response(lines : Array[String]) -> Bytes {
  let result : Array[Byte] = []
  for line in lines {
    let pkt = @protocol.pktline_encode(line)
    for b in pkt {
      result.push(b)
    }
  }

  // Add flush
  let flush = @protocol.pktline_flush()
  for b in flush {
    result.push(b)
  }
  Bytes::from_array(FixedArray::makei(result.length(), fn(i) { result[i] }))
}

// =============================================================================
// URL Generation Tests
// =============================================================================

///|
test "integration: remote URL generation" {
  let remote = @protocol.Remote::new("https://github.com/user/repo.git")
  let info_refs = remote.info_refs_url()
  assert_true(
    info_refs ==
    "https://github.com/user/repo/info/refs?service=git-receive-pack",
  )
  let receive_pack = remote.receive_pack_url()
  assert_true(receive_pack == "https://github.com/user/repo/git-receive-pack")
}

///|
test "integration: remote URL without .git suffix" {
  let remote = @protocol.Remote::new("https://github.com/user/repo")
  let info_refs = remote.info_refs_url()
  assert_true(
    info_refs ==
    "https://github.com/user/repo/info/refs?service=git-receive-pack",
  )
}

// =============================================================================
// Packfile Generation Tests (for git verify-pack compatibility)
// =============================================================================

///|
test "integration: generate test packfile" {
  let packfile = @pack.generate_test_packfile()

  // Verify it's a valid packfile
  assert_true(packfile[0] == b'P')
  assert_true(packfile[1] == b'A')
  assert_true(packfile[2] == b'C')
  assert_true(packfile[3] == b'K')

  // Version 2
  assert_true(packfile[7] == b'\x02')

  // 1 object
  assert_true(packfile[11] == b'\x01')

  // Length should be: 12 (header) + object data + 20 (trailer)
  assert_true(packfile.length() > 32)
}

///|
test "integration: generate commit packfile" {
  let (commit_id, packfile) = @pack.generate_commit_packfile()

  // Verify commit ID is valid
  assert_true(commit_id.to_hex().length() == 40)

  // 3 objects (blob, tree, commit)
  assert_true(packfile[11] == b'\x03')
}

///|
test "integration: hex dump format" {
  let data = Bytes::from_array([b'P', b'A', b'C', b'K'])
  let dump = @pack.hex_dump(data)

  // Should contain hex representation
  assert_true(dump.find("50") is Some(_)) // 'P' = 0x50
  assert_true(dump.find("41") is Some(_)) // 'A' = 0x41
  assert_true(dump.find("43") is Some(_)) // 'C' = 0x43
  assert_true(dump.find("4b") is Some(_)) // 'K' = 0x4b
}

///|
fn test_hex_digit(n : Int) -> Char {
  if n < 10 {
    (n + 48).unsafe_to_char() // '0' = 48
  } else {
    (n - 10 + 97).unsafe_to_char() // 'a' = 97
  }
}

///|
/// Convert packfile to compact hex string (no spaces)
fn to_hex_string(data : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < data.length(); i = i + 1 {
    let b = data[i].to_int()
    let hi = b >> 4
    let lo = b & 0x0f
    result.write_char(test_hex_digit(hi))
    result.write_char(test_hex_digit(lo))
  }
  result.to_string()
}

///|
test "integration: packfile hex for git verify-pack" {
  // Generate a simple blob packfile
  let packfile = @pack.generate_test_packfile()
  let hex = to_hex_string(packfile)

  // The hex should start with "5041434b" (PACK)
  assert_true(hex.has_prefix("5041434b"))

  // Version 2: "00000002"
  assert_true(hex.find("00000002") is Some(_))

  // Print hex for manual verification with:
  // echo "<hex>" | xxd -r -p > test.pack && git index-pack test.pack && git verify-pack -v test.pack
  // Result: ce013625030ba8dba906f756967f9e9ca394464a blob 6 18 12
  // This confirms our packfile is git-compatible!
  inspect(
    hex,
    content="5041434b0000000200000001367801010600f9ff68656c6c6f0a084b021f007b4413ed03c6c9a5aa33859e2ae7d4d74449fc",
  )
}

///|
test "integration: commit packfile for git verify-pack" {
  // Generate a commit packfile
  let (commit_id, packfile) = @pack.generate_commit_packfile()
  let hex = to_hex_string(packfile)

  // Should have 3 objects
  assert_true(hex.find("00000003") is Some(_))

  // Record hex for verification:
  // echo "<hex>" | xxd -r -p > test.pack && git index-pack test.pack && git verify-pack -v test.pack
  inspect(
    commit_id.to_hex(),
    content="82a3bd1994aaaed7882e87bc1018a1e24e4a416f",
  )
  inspect(
    hex,
    content="5041434b0000000200000003367801010600f9ff68656c6c6f0a084b021fa5027801012500daff3130303634342068656c6c6f2e74787400ce013625030ba8dba906f756967f9e9ca394464adf740dbf9f0a78012b294a4d55484c4cb4344b4e4d314ab14c344cb64835374a36354b3232354e3448354a4b35b730b6344e4b4d32e74a2c2dc9c82f5208492d2e517084b06d4a801c87d48ac4dc829c54bde4fc5c3b054373032850d006915c40d1dccc929254d2757279e665966426e628408ce00200ec783646aaebc6447dc2b959257f4369e21ef2351387f206",
  )
}
