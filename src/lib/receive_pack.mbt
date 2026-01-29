///| Receive-pack (server-side) implementation

///|
pub struct RefUpdate {
  old_id : @git.ObjectId
  new_id : @git.ObjectId
  refname : String
}

///|
pub struct ReceivePackRequest {
  updates : Array[RefUpdate]
  capabilities : Array[String]
  pack : Bytes
}

///|
pub struct ReceivePackResult {
  updated : Array[String]
  rejected : Array[(String, String)]
}

///|
/// Build receive-pack advertisement (info/refs payload).
pub fn build_receive_pack_advertisement(
  fs : &@git.RepoFileSystem,
  root : String,
  agent? : String = "git/moonbit",
) -> Bytes raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let refs = show_ref(fs, git_dir)
  refs.sort_by(fn(a, b) { String::compare(a.0, b.0) })
  let caps = receive_default_caps(agent)
  let out : Array[Byte] = []
  if refs.length() == 0 {
    let zero = @git.ObjectId::zero().to_hex()
    let line = "\{zero} capabilities^{}\u0000\{caps}\n"
    receive_push_bytes(out, @git.pktline_encode(line))
    receive_push_bytes(out, @git.pktline_flush())
    return Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
  }
  let (first_name, first_id) = refs[0]
  let first_line = "\{first_id.to_hex()} \{first_name}\u0000\{caps}\n"
  receive_push_bytes(out, @git.pktline_encode(first_line))
  for i in 1..<refs.length() {
    let (name, id) = refs[i]
    let line = "\{id.to_hex()} \{name}\n"
    receive_push_bytes(out, @git.pktline_encode(line))
  }
  receive_push_bytes(out, @git.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
pub fn parse_receive_pack_request(
  data : Bytes,
) -> ReceivePackRequest raise @git.GitError {
  let updates : Array[RefUpdate] = []
  let capabilities : Array[String] = []
  let mut i = 0
  let mut first = true
  while i + 4 <= data.length() {
    let len = receive_parse_pkt_len(data, i)
    if len == 0 {
      i += 4
      break
    }
    if len < 4 || i + len > data.length() {
      raise @git.GitError::ProtocolError("Invalid pkt-line length")
    }
    let line = receive_bytes_to_string_range(data, i + 4, i + len)
    let mut line = receive_trim_line(line)
    if first {
      first = false
      match line.find("\u0000") {
        None => ()
        Some(idx) => {
          let caps_str = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          line = String::unsafe_substring(line, start=0, end=idx)
          let caps = receive_split_by_space(caps_str)
          for c in caps {
            if c.length() > 0 {
              capabilities.push(c)
            }
          }
        }
      }
    }
    let parts = receive_split_by_space(line)
    if parts.length() < 3 {
      raise @git.GitError::ProtocolError("Invalid receive-pack command")
    }
    let old_id = @git.ObjectId::from_hex(parts[0])
    let new_id = @git.ObjectId::from_hex(parts[1])
    let refname = parts[2]
    updates.push({ old_id, new_id, refname })
    i += len
  }
  let pack = receive_bytes_slice(data, i, data.length())
  { updates, capabilities, pack }
}

///|
pub fn apply_receive_pack(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  req : ReceivePackRequest,
) -> ReceivePackResult raise @git.GitError {
  let git_dir = join_path(root, ".git")
  if req.pack.length() > 0 {
    let objects = @git.parse_packfile(req.pack)
    @git.write_packfile_with_index(fs, git_dir, req.pack, objects)
  }
  let db = ObjectDb::load(rfs, git_dir)
  let updated : Array[String] = []
  let rejected : Array[(String, String)] = []
  for upd in req.updates {
    let current = resolve_ref(rfs, git_dir, upd.refname)
    let current_id = match current {
      None => @git.ObjectId::zero()
      Some(id) => id
    }
    if current_id != upd.old_id {
      rejected.push((upd.refname, "old id mismatch"))
      continue
    }
    if upd.refname.has_prefix("refs/heads/") {
      if current_id != @git.ObjectId::zero() &&
        upd.new_id != @git.ObjectId::zero() {
        let ff = receive_is_ancestor_commit(db, rfs, current_id, upd.new_id) catch {
          _ => false
        }
        if not(ff) {
          rejected.push((upd.refname, "non-fast-forward"))
          continue
        }
      }
    }
    if upd.new_id == @git.ObjectId::zero() {
      if not(receive_delete_ref(fs, rfs, git_dir, upd.refname)) {
        rejected.push((upd.refname, "ref not found"))
        continue
      }
    } else {
      let ref_path = join_path(git_dir, upd.refname)
      let dir = parent_dir(ref_path)
      fs.mkdir_p(dir)
      fs.write_string(ref_path, upd.new_id.to_hex() + "\n")
    }
    updated.push(upd.refname)
  }
  { updated, rejected }
}

///|
pub fn receive_pack(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  data : Bytes,
) -> Bytes raise @git.GitError {
  let req = parse_receive_pack_request(data)
  let result = apply_receive_pack(fs, rfs, root, req)
  receive_build_status_response(result)
}

///|
fn receive_build_status_response(result : ReceivePackResult) -> Bytes {
  let out : Array[Byte] = []
  receive_push_bytes(out, @git.pktline_encode("unpack ok\n"))
  for refname in result.updated {
    receive_push_bytes(out, @git.pktline_encode("ok \{refname}\n"))
  }
  for item in result.rejected {
    let (refname, msg) = item
    receive_push_bytes(out, @git.pktline_encode("ng \{refname} \{msg}\n"))
  }
  receive_push_bytes(out, @git.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn receive_is_ancestor_commit(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  ancestor : @git.ObjectId,
  commit_id : @git.ObjectId,
) -> Bool raise @git.GitError {
  if ancestor == commit_id {
    return true
  }
  let stack : Array[@git.ObjectId] = [commit_id]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = match stack.pop() {
      None => raise @git.GitError::InvalidObject("Empty stack")
      Some(v) => v
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if id == ancestor {
      return true
    }
    let parents = receive_commit_parents(db, fs, id)
    for p in parents {
      stack.push(p)
    }
  }
  false
}

///|
fn receive_commit_parents(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @git.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @git.ObjectType::Commit {
        raise @git.GitError::InvalidObject("Object is not a commit")
      }
      let info = @git.parse_commit(o.data)
      info.parents
    }
  }
}

///|
fn receive_delete_ref(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Bool raise @git.GitError {
  let ref_path = join_path(git_dir, refname)
  if rfs.is_file(ref_path) {
    fs.remove_file(ref_path)
    return true
  }
  let packed = join_path(git_dir, "packed-refs")
  if not(rfs.is_file(packed)) {
    return false
  }
  let data = rfs.read_file(packed)
  let text = @utf8.decode_lossy(data[:])
  let out : Array[String] = []
  let mut removed = false
  let mut skip_peeled = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      continue
    }
    if skip_peeled {
      if line.has_prefix("^") {
        skip_peeled = false
        continue
      }
      skip_peeled = false
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      out.push(line)
      continue
    }
    match line.find(" ") {
      None => out.push(line)
      Some(idx) => {
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if name == refname {
          removed = true
          skip_peeled = true
        } else {
          out.push(line)
        }
      }
    }
  }
  if removed {
    let buf = StringBuilder::new()
    for l in out {
      buf.write_string(l)
      buf.write_char('\n')
    }
    fs.write_string(packed, buf.to_string())
  }
  removed
}

///|
fn receive_parse_pkt_len(data : Bytes, start : Int) -> Int raise @git.GitError {
  if start + 4 > data.length() {
    raise @git.GitError::ProtocolError("Invalid pkt-line length")
  }
  let mut v = 0
  for i in 0..<4 {
    let c = data[start + i].to_int().unsafe_to_char()
    v = v * 16 + receive_hex_char_to_int(c)
  }
  v
}

///|
fn receive_hex_char_to_int(c : Char) -> Int raise @git.GitError {
  if c >= '0' && c <= '9' {
    return c.to_int() - '0'.to_int()
  }
  if c >= 'a' && c <= 'f' {
    return 10 + (c.to_int() - 'a'.to_int())
  }
  if c >= 'A' && c <= 'F' {
    return 10 + (c.to_int() - 'A'.to_int())
  }
  raise @git.GitError::ProtocolError("Invalid hex char")
}

///|
fn receive_bytes_to_string_range(
  data : Bytes,
  start : Int,
  end : Int,
) -> String {
  let buf = StringBuilder::new()
  let mut i = start
  while i < end {
    buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  buf.to_string()
}

///|
fn receive_bytes_slice(data : Bytes, start : Int, end : Int) -> Bytes {
  let len = end - start
  if len <= 0 {
    return Bytes::from_array([])
  }
  let fixed = FixedArray::makei(len, fn(i) { data[start + i] })
  Bytes::from_array(fixed)
}

///|
fn receive_trim_line(line : String) -> String {
  if line.has_suffix("\n") {
    String::unsafe_substring(line, start=0, end=line.length() - 1)
  } else {
    line
  }
}

///|
fn receive_split_by_space(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut buf : Array[Char] = []
  for c in s {
    if c == ' ' {
      out.push(receive_chars_to_string(buf))
      buf = []
    } else {
      buf.push(c)
    }
  }
  out.push(receive_chars_to_string(buf))
  out
}

///|
fn receive_chars_to_string(chars : Array[Char]) -> String {
  let buf = StringBuilder::new()
  for c in chars {
    buf.write_char(c)
  }
  buf.to_string()
}

///|
fn receive_push_bytes(out : Array[Byte], data : Bytes) -> Unit {
  for b in data {
    out.push(b)
  }
}

///|
fn receive_default_caps(agent : String) -> String {
  let caps : Array[String] = [
    "report-status",
    "report-status-v2",
    "delete-refs",
    "side-band-64k",
    "ofs-delta",
    "object-format=sha1",
    "agent=\{agent}",
  ]
  caps.join(" ")
}
