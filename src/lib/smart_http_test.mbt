///| Tests for smart HTTP helpers

///|
test "smart http: info/refs auth" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  let bad = receive_pack_info_refs_response(fs, "/repo", None, "token")
  assert_true(bad.status == 401)
  let ok = receive_pack_info_refs_response(
    fs,
    "/repo",
    Some("Bearer token"),
    "token",
  )
  assert_true(ok.status == 200)
  let decoded = @git.pktline_decode(ok.body) catch { _ => [] }
  assert_true(decoded.length() > 0)
  let (line_bytes, _) = decoded[0]
  let line = @utf8.decode_lossy(line_bytes[:])
  assert_true(line.contains("# service=git-receive-pack"))
}
