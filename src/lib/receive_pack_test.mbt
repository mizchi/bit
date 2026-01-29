///| Tests for receive-pack

///|
fn build_receive_request(
  old_id : @git.ObjectId,
  new_id : @git.ObjectId,
  refname : String,
  pack : Bytes,
) -> Bytes {
  let out : Array[Byte] = []
  let cmd = @git.build_ref_update(old_id, new_id, refname, "report-status")
  for b in @git.pktline_encode(cmd) {
    out.push(b)
  }
  for b in @git.pktline_flush() {
    out.push(b)
  }
  for b in pack {
    out.push(b)
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
test "receive-pack: push to empty repo" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/src"))
  ignore(try? init_repo(fs, "/dst"))
  fs.write_string("/src/a.txt", "hello\n")
  add_paths(fs, fs, "/src", ["a.txt"])
  let commit_id = commit(
    fs, fs, "/src", "msg\n", "Test <t@example.com>", 1700000000L,
  )
  let db = ObjectDb::load(fs, "/src/.git")
  let objects = collect_reachable_objects(db, fs, commit_id)
  let pack = @git.create_packfile(objects)
  let req = build_receive_request(
    @git.ObjectId::zero(),
    commit_id,
    "refs/heads/main",
    pack,
  )
  ignore(receive_pack(fs, fs, "/dst", req))
  match resolve_ref(fs, "/dst/.git", "refs/heads/main") {
    None => assert_true(false)
    Some(id) => assert_true(id == commit_id)
  }
  let pack_dir = "/dst/.git/objects/pack"
  assert_true(fs.is_dir(pack_dir))
  let files = fs.readdir(pack_dir)
  assert_true(files.length() > 0)
}

///|
test "receive-pack: advertise empty repo" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  let adv = build_receive_pack_advertisement(fs, "/repo")
  let decoded = @git.pktline_decode(adv) catch { _ => [] }
  assert_true(decoded.length() > 0)
  let (line_bytes, _) = decoded[0]
  let line = @utf8.decode_lossy(line_bytes[:])
  assert_true(line.contains("capabilities^{}"))
  assert_true(line.contains("report-status"))
}

///|
test "receive-pack: reject non-fast-forward" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/src"))
  ignore(try? init_repo(fs, "/dst"))
  fs.write_string("/src/a.txt", "one\n")
  add_paths(fs, fs, "/src", ["a.txt"])
  let commit_src = commit(
    fs, fs, "/src", "src\n", "Test <t@example.com>", 1700000000L,
  )
  fs.write_string("/dst/b.txt", "two\n")
  add_paths(fs, fs, "/dst", ["b.txt"])
  let commit_dst = commit(
    fs, fs, "/dst", "dst\n", "Test <t@example.com>", 1700000001L,
  )
  let db = ObjectDb::load(fs, "/src/.git")
  let objects = collect_reachable_objects(db, fs, commit_src)
  let pack = @git.create_packfile(objects)
  let req = build_receive_request(
    commit_dst, commit_src, "refs/heads/main", pack,
  )
  let res = parse_receive_pack_request(req)
  let result = apply_receive_pack(fs, fs, "/dst", res)
  assert_true(result.updated.length() == 0)
  assert_true(result.rejected.length() == 1)
  let (refname, msg) = result.rejected[0]
  assert_true(refname == "refs/heads/main")
  assert_true(msg.contains("non-fast-forward"))
}
