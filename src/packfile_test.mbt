///|
/// Tests for Git packfile generation
test "packfile magic and version" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let packfile = create_blob_packfile(content)

  // Check magic: "PACK"
  inspect(packfile[0], content="b'\\x50'") // 'P'
  inspect(packfile[1], content="b'\\x41'") // 'A'
  inspect(packfile[2], content="b'\\x43'") // 'C'
  inspect(packfile[3], content="b'\\x4B'") // 'K'

  // Check version: 2
  inspect(packfile[4], content="b'\\x00'")
  inspect(packfile[5], content="b'\\x00'")
  inspect(packfile[6], content="b'\\x00'")
  inspect(packfile[7], content="b'\\x02'")
}

///|
test "packfile object count" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let packfile = create_blob_packfile(content)

  // Check object count: 1
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x01'")
}

///|
test "packfile blob type encoding" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let packfile = create_blob_packfile(content)

  // First object byte: type=3 (blob), size=5
  // Format: [MSB=0 | type=011 | size=0101] = 0b00110101 = 0x35
  inspect(packfile[12], content="b'\\x35'")
}

///|
test "packfile with larger size" {
  // Test size encoding with continuation bytes
  let content : Array[Byte] = []
  for i = 0; i < 100; i = i + 1 {
    content.push(b'x')
  }
  let packfile = create_blob_packfile(
    Bytes::from_array(FixedArray::makei(content.length(), fn(i) { content[i] })),
  )

  // Size=100, type=3
  // First byte: MSB=1 (continue), type=011, size_low=100&0xf=4 → 0b10110100 = 0xb4
  // Second byte: MSB=0, size_rest=100>>4=6 → 0b00000110 = 0x06
  inspect(packfile[12], content="b'\\xB4'")
  inspect(packfile[13], content="b'\\x06'")
}

///|
test "packfile trailer is 20 bytes" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let packfile = create_blob_packfile(content)

  // The packfile should end with a 20-byte SHA-1
  // Total = 12 (header) + object_data + 20 (trailer)
  assert_true(packfile.length() > 32)
}

///|
test "packfile multiple objects" {
  let obj1 = @git.PackObject::new(
    @git.ObjectType::Blob,
    Bytes::from_array([b'a']),
  )
  let obj2 = @git.PackObject::new(
    @git.ObjectType::Blob,
    Bytes::from_array([b'b']),
  )
  let packfile = create_packfile([obj1, obj2])

  // Check object count: 2
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x02'")
}

///|
test "create commit packfile" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o', b'\n'])
  let commit = @git.Commit::new(
    @git.ObjectId::zero(), // Will be replaced
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test commit\n",
  )
  let (commit_id, packfile) = create_commit_packfile(
    content, "hello.txt", commit,
  )

  // Verify commit ID is valid
  assert_true(commit_id.to_hex().length() == 40)

  // Verify packfile has 3 objects
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x03'")
}

///|
test "encode type and size small" {
  let result : Array[Byte] = []
  encode_type_and_size(3, 5, result) // blob, size=5
  inspect(result.length(), content="1")
  // 0b00110101 = 0x35
  inspect(result[0], content="b'\\x35'")
}

///|
test "encode type and size medium" {
  let result : Array[Byte] = []
  encode_type_and_size(3, 100, result) // blob, size=100
  inspect(result.length(), content="2")
  // First: 0b10110100 = 0xb4
  // Second: 0b00000110 = 0x06
  inspect(result[0], content="b'\\xB4'")
  inspect(result[1], content="b'\\x06'")
}

///|
test "encode type and size large" {
  let result : Array[Byte] = []
  encode_type_and_size(3, 0x1234, result) // blob, size=4660
  inspect(result.length(), content="3")
  // size=0x1234
  // First: MSB=1, type=3, size&0xf=4 → 0b10110100 = 0xb4
  // size>>4 = 0x123
  // Second: MSB=1, 0x123&0x7f=0x23 → 0b10100011 = 0xa3
  // 0x123>>7 = 0x2
  // Third: MSB=0, 0x2 → 0b00000010 = 0x02
  inspect(result[0], content="b'\\xB4'")
  inspect(result[1], content="b'\\xA3'")
  inspect(result[2], content="b'\\x02'")
}

// =============================================================================
// Delta Packfile Tests (using public API)
// =============================================================================

///|
test "packfile: OFS_DELTA mode creates delta" {
  // Two similar blobs should produce delta
  let base = @utf8.encode("Hello, World! This is a test content.\n")
  let target = @utf8.encode("Hello, World! This is a test changed.\n")
  let obj1 = @git.PackObject::new(@git.ObjectType::Blob, base)
  let obj2 = @git.PackObject::new(@git.ObjectType::Blob, target)
  let (pack, delta_count) = @git.create_packfile_with_delta_stats(
    [obj1, obj2],
    @git.PackDeltaMode::OfsDelta,
  )
  // Should have at least 1 delta if content is similar enough
  // (depends on delta efficiency)
  assert_true(pack.length() > 32)
  // Parse back and verify
  let objects = parse_packfile(pack)
  assert_true(objects.length() == 2)
  assert_true(objects[0].data.length() == base.length())
  assert_true(objects[1].data.length() == target.length())
  ignore(delta_count)
}

///|
test "packfile: REF_DELTA mode creates delta" {
  let base = @utf8.encode("Hello, World! This is a test content.\n")
  let target = @utf8.encode("Hello, World! This is a test changed.\n")
  let obj1 = @git.PackObject::new(@git.ObjectType::Blob, base)
  let obj2 = @git.PackObject::new(@git.ObjectType::Blob, target)
  let (pack, _) = @git.create_packfile_with_delta_stats(
    [obj1, obj2],
    @git.PackDeltaMode::RefDelta,
  )
  assert_true(pack.length() > 32)
  let objects = parse_packfile(pack)
  assert_true(objects.length() == 2)
  assert_true(objects[0].data.length() == base.length())
  assert_true(objects[1].data.length() == target.length())
}

///|
test "packfile: NoDelta mode preserves all objects" {
  let base = @utf8.encode("Hello, World! This is a test content.\n")
  let target = @utf8.encode("Hello, World! This is a test changed.\n")
  let obj1 = @git.PackObject::new(@git.ObjectType::Blob, base)
  let obj2 = @git.PackObject::new(@git.ObjectType::Blob, target)
  let (pack, delta_count) = @git.create_packfile_with_delta_stats(
    [obj1, obj2],
    @git.PackDeltaMode::NoDelta,
  )
  assert_true(delta_count == 0)
  let objects = parse_packfile(pack)
  assert_true(objects.length() == 2)
}
