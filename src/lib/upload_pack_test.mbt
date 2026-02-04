///| Tests for upload-pack server implementation

///|
fn test_concat_bytes(chunks : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for chunk in chunks {
    for b in chunk {
      out.push(b)
    }
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
test "build_upload_pack_advertisement: empty repo" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  let adv = build_upload_pack_advertisement(fs, "/repo")
  // Should have capabilities^{} line for empty repo
  let text = @utf8.decode_lossy(adv[:])
  assert_true(text.contains("capabilities^{}"))
  assert_true(text.contains("agent=git/moonbit"))
}

///|
test "build_upload_pack_advertisement: with refs" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  // Create a commit to get a real ref
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let commit_id = commit(
    fs, fs, "/repo", "initial\n", "Test <t@example.com>", 1700000000L,
  )
  let adv = build_upload_pack_advertisement(fs, "/repo")
  let text = @utf8.decode_lossy(adv[:])
  assert_true(text.contains(commit_id.to_hex()))
  assert_true(text.contains("refs/heads/main"))
}

///|
test "parse_upload_pack_request: simple want" {
  // Build a simple want request
  let want_line = "want ce013625030ba8dba906f756967f9e9ca394464a\n"
  let req_bytes = test_concat_bytes([
    @git.pktline_encode(want_line),
    @git.pktline_flush(),
    @git.pktline_encode("done\n"),
  ])
  let req = parse_upload_pack_request(req_bytes)
  assert_true(req.wants.length() == 1)
  assert_true(
    req.wants[0].to_hex() == "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  assert_true(req.done)
}

///|
test "parse_upload_pack_request: want with capabilities" {
  // Build a want request with capabilities
  let want_line = "want ce013625030ba8dba906f756967f9e9ca394464a\u0000ofs-delta side-band-64k\n"
  let req_bytes = test_concat_bytes([
    @git.pktline_encode(want_line),
    @git.pktline_flush(),
    @git.pktline_encode("done\n"),
  ])
  let req = parse_upload_pack_request(req_bytes)
  assert_true(req.wants.length() == 1)
  assert_true(req.capabilities.length() == 2)
  assert_true(req.capabilities[0] == "ofs-delta")
  assert_true(req.capabilities[1] == "side-band-64k")
}

///|
test "parse_upload_pack_request: multiple wants and haves" {
  let want1 = "want ce013625030ba8dba906f756967f9e9ca394464a\n"
  let want2 = "want cc628ccd10742baea8241c5924df992b5c019f71\n"
  let have1 = "have 88e38705fdbd3608cddbe904b67c731f3234c45b\n"
  let req_bytes = test_concat_bytes([
    @git.pktline_encode(want1),
    @git.pktline_encode(want2),
    @git.pktline_flush(),
    @git.pktline_encode(have1),
    @git.pktline_encode("done\n"),
  ])
  let req = parse_upload_pack_request(req_bytes)
  assert_true(req.wants.length() == 2)
  assert_true(req.haves.length() == 1)
  assert_true(req.done)
}

///|
/// Protocol v2 format test helper - creates pktline without newline
fn test_pktline_v2(s : String) -> Bytes {
  let len = s.length() + 4
  let hex = test_int_to_hex4(len)
  let out : Array[Byte] = []
  for c in hex {
    out.push(c.to_int().to_byte())
  }
  for c in s {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn test_int_to_hex4(n : Int) -> String {
  let digits = "0123456789abcdef"
  let mut result = ""
  let mut v = n
  for _ in 0..<4 {
    let d = v % 16
    result = String::make(1, Int::unsafe_to_char(digits[d].to_int())) + result
    v = v / 16
  }
  result
}

///|
fn test_delimiter() -> Bytes {
  // 0001 = delimiter packet in protocol v2
  Bytes::from_array([b'0', b'0', b'0', b'1'])
}

///|
test "detect_protocol_version: v1 format (want line)" {
  let want_line = "want ce013625030ba8dba906f756967f9e9ca394464a\n"
  let req_bytes = test_concat_bytes([
    @git.pktline_encode(want_line),
    @git.pktline_flush(),
  ])
  let version = detect_protocol_version(req_bytes)
  inspect(version, content="1")
}

///|
test "detect_protocol_version: v2 format (command=fetch)" {
  let req_bytes = test_concat_bytes([
    test_pktline_v2("command=fetch"),
    test_pktline_v2("object-format=sha1"),
    test_delimiter(),
    test_pktline_v2("done"),
    @git.pktline_flush(),
  ])
  let version = detect_protocol_version(req_bytes)
  inspect(version, content="2")
}

///|
test "parse_upload_pack_request_v2: simple fetch" {
  let req_bytes = test_concat_bytes([
    test_pktline_v2("command=fetch"),
    test_pktline_v2("object-format=sha1"),
    test_delimiter(),
    test_pktline_v2("want ce013625030ba8dba906f756967f9e9ca394464a"),
    test_pktline_v2("done"),
    @git.pktline_flush(),
  ])
  let req = parse_upload_pack_request_v2(req_bytes)
  inspect(req.command, content="fetch")
  inspect(req.wants.length(), content="1")
  inspect(req.done, content="true")
}

///|
test "parse_upload_pack_request_v2: with packfile-uris" {
  let req_bytes = test_concat_bytes([
    test_pktline_v2("command=fetch"),
    test_pktline_v2("object-format=sha1"),
    test_delimiter(),
    test_pktline_v2("packfile-uris https"),
    test_pktline_v2("done"),
    @git.pktline_flush(),
  ])
  let req = parse_upload_pack_request_v2(req_bytes)
  inspect(req.command, content="fetch")
  inspect(req.packfile_uris, content="Some(\"https\")")
}

///|
test "parse_upload_pack_request_v2: with filter" {
  let req_bytes = test_concat_bytes([
    test_pktline_v2("command=fetch"),
    test_pktline_v2("object-format=sha1"),
    test_delimiter(),
    test_pktline_v2("filter blob:none"),
    test_pktline_v2("done"),
    @git.pktline_flush(),
  ])
  let req = parse_upload_pack_request_v2(req_bytes)
  inspect(req.filter, content="Some(\"blob:none\")")
}

///|
test "parse_upload_pack_request_v2: want-ref" {
  let req_bytes = test_concat_bytes([
    test_pktline_v2("command=fetch"),
    test_pktline_v2("object-format=sha1"),
    test_delimiter(),
    test_pktline_v2("want-ref refs/heads/main"),
    test_pktline_v2("done"),
    @git.pktline_flush(),
  ])
  let req = parse_upload_pack_request_v2(req_bytes)
  inspect(req.want_refs.length(), content="1")
  inspect(req.want_refs[0], content="refs/heads/main")
}

///|
test "parse_upload_pack_request_v2: extra delimiter" {
  let req_bytes = test_concat_bytes([
    test_pktline_v2("command=fetch"),
    test_pktline_v2("object-format=sha1"),
    test_delimiter(),
    test_delimiter(),
  ])
  let res : Result[UploadPackRequestV2, Error] = try? parse_upload_pack_request_v2(
    req_bytes,
  )
  match res {
    Ok(_) => fail("expected protocol error")
    Err(err) =>
      inspect(
        err.to_string().contains("expected flush after fetch arguments"),
        content="true",
      )
  }
}

// Note: Oracle tests for upload-pack are in src/git_oracle_pack_test.mbt
// (main package) which has access to native-only features (@process, @fs).
