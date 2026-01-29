///| Whitebox tests for packfile delta encoding/decoding

///|
test "delta: build and apply roundtrip" {
  let base = @utf8.encode("Hello, World!\n")
  let target = @utf8.encode("Hello, MoonBit!\n")
  let delta = build_delta(base, target)
  let result = apply_delta(base, delta)
  assert_true(result.length() == target.length())
  for i = 0; i < target.length(); i = i + 1 {
    assert_true(result[i] == target[i])
  }
}

///|
test "delta: identical content produces copy-based delta" {
  let data = @utf8.encode("Hello, World!\n")
  let delta = build_delta(data, data)
  let result = apply_delta(data, delta)
  assert_true(result.length() == data.length())
  for i = 0; i < data.length(); i = i + 1 {
    assert_true(result[i] == data[i])
  }
}

///|
test "delta: empty target" {
  let base = @utf8.encode("Hello\n")
  let target = Bytes::from_array([])
  let delta = build_delta(base, target)
  let result = apply_delta(base, delta)
  assert_true(result.length() == 0)
}

///|
test "delta: large similar content uses copy ops" {
  let base_parts : Array[Byte] = []
  let target_parts : Array[Byte] = []
  for i = 0; i < 500; i = i + 1 {
    let line = "line \{i}: some content here\n"
    for c in line {
      base_parts.push(c.to_int().to_byte())
      target_parts.push(c.to_int().to_byte())
    }
  }
  // Modify one line in target
  let mod_line = "line 250: MODIFIED content here\n"
  let mod_start = 250 * 28
  let mut mod_idx = 0
  for c in mod_line {
    if mod_start + mod_idx < target_parts.length() {
      target_parts[mod_start + mod_idx] = c.to_int().to_byte()
    }
    mod_idx += 1
  }
  let base = Bytes::from_array(
    FixedArray::makei(base_parts.length(), fn(i) { base_parts[i] }),
  )
  let target = Bytes::from_array(
    FixedArray::makei(target_parts.length(), fn(i) { target_parts[i] }),
  )
  let delta = build_delta(base, target)
  let result = apply_delta(base, delta)
  // Delta should be smaller than full content
  assert_true(delta.length() < target.length())
  assert_true(result.length() == target.length())
  for i = 0; i < target.length(); i = i + 1 {
    assert_true(result[i] == target[i])
  }
}

///|
test "delta: completely different content uses insert ops" {
  let base = @utf8.encode("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n")
  let target = @utf8.encode("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n")
  let delta = build_delta(base, target)
  let result = apply_delta(base, delta)
  assert_true(result.length() == target.length())
  for i = 0; i < target.length(); i = i + 1 {
    assert_true(result[i] == target[i])
  }
}

///|
test "delta: encode_ofs_delta_offset roundtrip" {
  // Test various offset values
  let test_values = [1, 127, 128, 255, 256, 1000, 0x1234, 0x12345]
  for val in test_values {
    let buf : Array[Byte] = []
    encode_ofs_delta_offset(val, buf)
    // Convert to Bytes for read_ofs_delta_offset
    let bytes = Bytes::from_array(
      FixedArray::makei(buf.length(), fn(i) { buf[i] }),
    )
    let (decoded, _) = read_ofs_delta_offset(bytes, 0)
    assert_true(decoded == val)
  }
}

///|
test "delta: encode_delta_size roundtrip" {
  let test_values = [0, 1, 127, 128, 255, 256, 1000, 0x1234, 0x12345]
  for val in test_values {
    let buf : Array[Byte] = []
    encode_delta_size(val, buf)
    let bytes = Bytes::from_array(
      FixedArray::makei(buf.length(), fn(i) { buf[i] }),
    )
    let (decoded, _) = read_delta_size(bytes, 0)
    assert_true(decoded == val)
  }
}
