///| Upload-pack (server-side) implementation

///|
pub struct UploadPackRequest {
  wants : Array[@git.ObjectId]
  haves : Array[@git.ObjectId]
  capabilities : Array[String]
  done : Bool
  shallow : Array[@git.ObjectId]
  deepen : Int?
}

///|
/// Protocol v2 upload-pack request
pub struct UploadPackRequestV2 {
  command : String // "fetch", "ls-refs", etc.
  capabilities : Array[String]
  wants : Array[@git.ObjectId]
  want_refs : Array[String]
  haves : Array[@git.ObjectId]
  done : Bool
  // v2-specific capabilities
  filter : String? // e.g., "blob:none"
  packfile_uris : String? // e.g., "https"
}

///|
/// Detect protocol version from request bytes
/// Returns 1 for v1 (want lines), 2 for v2 (command=...)
pub fn detect_protocol_version(data : Bytes) -> Int {
  if data.length() < 8 {
    return 1
  }
  // Parse first pktline length
  let len = upload_parse_pkt_len_safe(data, 0)
  if len < 4 {
    return 1
  }
  // Check if first line starts with "command="
  let end = if len > data.length() { data.length() } else { len }
  let line = upload_bytes_to_string_range(data, 4, end)
  if line.has_prefix("command=") {
    2
  } else {
    1
  }
}

///|
fn upload_parse_pkt_len_safe(data : Bytes, start : Int) -> Int {
  if start + 4 > data.length() {
    return 0
  }
  let mut v = 0
  for i in 0..<4 {
    let c = data[start + i].to_int()
    let digit = if c >= 0x30 && c <= 0x39 {
      // '0'-'9'
      c - 0x30
    } else if c >= 0x61 && c <= 0x66 {
      // 'a'-'f'
      10 + (c - 0x61)
    } else if c >= 0x41 && c <= 0x46 {
      // 'A'-'F'
      10 + (c - 0x41)
    } else {
      return 0
    }
    v = v * 16 + digit
  }
  v
}

///|
/// Parse protocol v2 upload-pack request
pub fn parse_upload_pack_request_v2(
  data : Bytes,
) -> UploadPackRequestV2 raise @git.GitError {
  let mut command = ""
  let capabilities : Array[String] = []
  let wants : Array[@git.ObjectId] = []
  let want_refs : Array[String] = []
  let haves : Array[@git.ObjectId] = []
  let mut done = false
  let mut filter : String? = None
  let mut packfile_uris : String? = None
  let mut i = 0
  let mut in_args = false // After delimiter (0001)
  let mut saw_flush_after_args = false
  while i + 4 <= data.length() {
    let len = upload_parse_pkt_len_safe(data, i)

    // 0000 = flush
    if len == 0 {
      i += 4
      if in_args {
        saw_flush_after_args = true
      }
      continue
    }

    // 0001 = delimiter (switch from command section to arguments)
    if len == 1 {
      if in_args {
        let cmd = if command.length() > 0 { command } else { "unknown" }
        raise @git.GitError::ProtocolError(
          "expected flush after " + cmd + " arguments",
        )
      }
      in_args = true
      i += 4
      continue
    }
    if len < 4 || i + len > data.length() {
      raise @git.GitError::ProtocolError("Invalid pkt-line length in v2")
    }
    if saw_flush_after_args {
      raise @git.GitError::ProtocolError("Unexpected data after flush")
    }
    let line = upload_bytes_to_string_range(data, i + 4, i + len)
    let line = upload_trim_line(line)
    i += len
    if not(in_args) {
      // Command section
      if line.has_prefix("command=") {
        command = String::unsafe_substring(line, start=8, end=line.length())
      } else if line.has_prefix("object-format=") {
        // Ignore for now, assume sha1
      } else if line.length() > 0 {
        capabilities.push(line)
      }
      // Arguments section
    } else if line.has_prefix("want-ref ") {
      let refname = String::unsafe_substring(line, start=9, end=line.length())
      let refname = upload_trim_line(refname)
      if refname.length() > 0 {
        want_refs.push(refname)
      }
    } else if line.has_prefix("want ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      let hex = upload_trim_line(hex)
      if hex.length() >= 40 {
        let hex40 = String::unsafe_substring(hex, start=0, end=40)
        wants.push(@git.ObjectId::from_hex(hex40))
      }
    } else if line.has_prefix("have ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      let hex = upload_trim_line(hex)
      if hex.length() >= 40 {
        let hex40 = String::unsafe_substring(hex, start=0, end=40)
        haves.push(@git.ObjectId::from_hex(hex40))
      }
    } else if line == "done" {
      done = true
    } else if line.has_prefix("filter ") {
      filter = Some(String::unsafe_substring(line, start=7, end=line.length()))
    } else if line.has_prefix("packfile-uris ") {
      packfile_uris = Some(
        String::unsafe_substring(line, start=14, end=line.length()),
      )
    }
  }
  { command, capabilities, wants, want_refs, haves, done, filter, packfile_uris }
}

///|
/// Build upload-pack advertisement (info/refs payload).
pub fn build_upload_pack_advertisement(
  fs : &@git.RepoFileSystem,
  root : String,
  agent? : String = "git/moonbit",
) -> Bytes raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let refs = show_ref(fs, git_dir)
  refs.sort_by(fn(a, b) { String::compare(a.0, b.0) })
  let caps = upload_default_caps(agent)
  let out : Array[Byte] = []
  if refs.length() == 0 {
    let zero = @git.ObjectId::zero().to_hex()
    let line = "\{zero} capabilities^{}\u0000\{caps}\n"
    upload_push_bytes(out, @git.pktline_encode(line))
    upload_push_bytes(out, @git.pktline_flush())
    return Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
  }
  let (first_name, first_id) = refs[0]
  let first_line = "\{first_id.to_hex()} \{first_name}\u0000\{caps}\n"
  upload_push_bytes(out, @git.pktline_encode(first_line))
  for i in 1..<refs.length() {
    let (name, id) = refs[i]
    let line = "\{id.to_hex()} \{name}\n"
    upload_push_bytes(out, @git.pktline_encode(line))
  }
  upload_push_bytes(out, @git.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
pub fn parse_upload_pack_request(
  data : Bytes,
) -> UploadPackRequest raise @git.GitError {
  let wants : Array[@git.ObjectId] = []
  let haves : Array[@git.ObjectId] = []
  let shallow : Array[@git.ObjectId] = []
  let capabilities : Array[String] = []
  let mut done = false
  let mut deepen : Int? = None
  let mut i = 0
  let mut first_want = true
  while i + 4 <= data.length() {
    let len = upload_parse_pkt_len(data, i)
    if len == 0 {
      // flush packet
      i += 4
      continue
    }
    if len < 4 || i + len > data.length() {
      raise @git.GitError::ProtocolError("Invalid pkt-line length")
    }
    let line = upload_bytes_to_string_range(data, i + 4, i + len)
    let mut line = upload_trim_line(line)
    // Parse capabilities from first want line
    if first_want && line.has_prefix("want ") {
      first_want = false
      // Try NUL separator first (git protocol)
      match line.find("\u0000") {
        Some(idx) => {
          let caps_str = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          line = String::unsafe_substring(line, start=0, end=idx)
          let caps = upload_split_by_space(caps_str)
          for c in caps {
            if c.length() > 0 {
              capabilities.push(c)
            }
          }
        }
        None => {
          // HTTP stateless-rpc: caps are space-separated after SHA
          // Format: "want <sha40> <cap1> <cap2> ..."
          let rest = String::unsafe_substring(line, start=5, end=line.length())
          let rest = upload_trim_line(rest)
          if rest.length() > 40 {
            let caps_str = String::unsafe_substring(
              rest,
              start=41,
              end=rest.length(),
            )
            let caps = upload_split_by_space(caps_str)
            for c in caps {
              if c.length() > 0 {
                capabilities.push(c)
              }
            }
          }
        }
      }
    }
    if line.has_prefix("want ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      let hex = upload_trim_line(hex)
      // Extract just the SHA (first 40 chars or until space)
      let hex = if hex.length() > 40 {
        String::unsafe_substring(hex, start=0, end=40)
      } else {
        match hex.find(" ") {
          None => hex
          Some(idx) => String::unsafe_substring(hex, start=0, end=idx)
        }
      }
      if hex.length() >= 40 {
        let hex40 = String::unsafe_substring(hex, start=0, end=40)
        wants.push(@git.ObjectId::from_hex(hex40))
      }
    } else if line.has_prefix("have ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      let hex = upload_trim_line(hex)
      if hex.length() >= 40 {
        let hex40 = String::unsafe_substring(hex, start=0, end=40)
        haves.push(@git.ObjectId::from_hex(hex40))
      }
    } else if line.has_prefix("shallow ") {
      let hex = String::unsafe_substring(line, start=8, end=line.length())
      let hex = upload_trim_line(hex)
      if hex.length() >= 40 {
        let hex40 = String::unsafe_substring(hex, start=0, end=40)
        shallow.push(@git.ObjectId::from_hex(hex40))
      }
    } else if line.has_prefix("deepen ") {
      let depth_str = String::unsafe_substring(line, start=7, end=line.length())
      let depth_str = upload_trim_line(depth_str)
      let depth = @strconv.parse_int(depth_str) catch { _ => -1 }
      if depth >= 0 {
        deepen = Some(depth)
      }
    } else if line == "done" {
      done = true
    }
    i += len
  }
  { wants, haves, capabilities, done, shallow, deepen }
}

///|
pub fn upload_pack(
  fs : &@git.RepoFileSystem,
  root : String,
  req : UploadPackRequest,
) -> Bytes raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let db = ObjectDb::load(fs, git_dir)

  // Validate wants (must be commit objects)
  for want in req.wants {
    let obj = db.get(fs, want)
    match obj {
      None =>
        raise @git.GitError::ProtocolError(
          "not our ref " + want.to_hex(),
        )
      Some(o) =>
        if o.obj_type != @git.ObjectType::Commit {
          raise @git.GitError::ProtocolError(
            "not our ref " + want.to_hex(),
          )
        }
    }
  }

  // Stateless clients may terminate after wants; respond with flush only
  if not(req.done) && req.haves.length() == 0 {
    return @git.pktline_flush()
  }

  // Check if client wants side-band
  let use_side_band = req.capabilities.contains("side-band-64k") ||
    req.capabilities.contains("side-band")

  // Collect have ACKs (v0 allows duplicates)
  let ack_ids = collect_have_acks_v0(db, fs, req.haves)
  if not(req.done) {
    return build_upload_pack_ack_response(ack_ids)
  }

  // Collect objects reachable from wants
  let include_pack_objects_died = req.shallow.length() == 0 &&
    req.deepen is None
  let objects = try collect_reachable_objects_from_commits(db, fs, req.wants) catch {
    err =>
      raise @git.GitError::ProtocolError(
        upload_pack_error_message(err, include_pack_objects_died),
      )
  }

  // If client has some objects, filter them out
  if req.haves.length() > 0 {
    let have_set : Map[String, Bool] = {}
    let have_objects = collect_reachable_objects_from_commits(db, fs, req.haves)
    for obj in have_objects {
      let id = @git.hash_object_content(obj.obj_type, obj.data)
      have_set[id.to_hex()] = true
    }
    let filtered : Array[@git.PackObject] = []
    for obj in objects {
      let id = @git.hash_object_content(obj.obj_type, obj.data)
      if not(have_set.contains(id.to_hex())) {
        filtered.push(obj)
      }
    }
    return build_upload_pack_response(filtered, use_side_band, ack_ids)
  }
  build_upload_pack_response(objects, use_side_band, ack_ids)
}

///|
fn build_upload_pack_ack_response(
  ack_ids : Array[@git.ObjectId],
) -> Bytes {
  let out : Array[Byte] = []
  if ack_ids.length() > 0 {
    for id in ack_ids {
      upload_push_bytes(out, @git.pktline_encode("ACK " + id.to_hex() + "\n"))
    }
  } else {
    upload_push_bytes(out, @git.pktline_encode("NAK\n"))
  }
  upload_push_bytes(out, @git.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn build_upload_pack_response(
  objects : Array[@git.PackObject],
  use_side_band : Bool,
  ack_ids : Array[@git.ObjectId],
) -> Bytes {
  let out : Array[Byte] = []
  if ack_ids.length() > 0 {
    for id in ack_ids {
      upload_push_bytes(out, @git.pktline_encode("ACK " + id.to_hex() + "\n"))
    }
  }
  // NAK (no common commits)
  upload_push_bytes(out, @git.pktline_encode("NAK\n"))
  // Create packfile
  let pack = @git.create_packfile(objects)
  if use_side_band {
    // Send packfile via side-band-64k (band 1)
    let chunk_size = 65515 // 65520 - 4 (pkt-line header) - 1 (band byte)
    let mut offset = 0
    while offset < pack.length() {
      let end = if offset + chunk_size > pack.length() {
        pack.length()
      } else {
        offset + chunk_size
      }
      let data_len = end - offset
      let pkt_len = data_len + 5 // 4 (header) + 1 (band byte)
      let len_hex = upload_int_to_hex4(pkt_len)
      for c in len_hex {
        out.push(c.to_int().to_byte())
      }
      out.push(b'\x01') // band 1 = packfile data
      for i in offset..<end {
        out.push(pack[i])
      }
      offset = end
    }
    // Send flush to indicate end of packfile
    upload_push_bytes(out, @git.pktline_flush())
  } else {
    // Send packfile directly (no side-band)
    for b in pack {
      out.push(b)
    }
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn collect_have_acks_v0(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  haves : Array[@git.ObjectId],
) -> Array[@git.ObjectId] raise @git.GitError {
  let out : Array[@git.ObjectId] = []
  for id in haves {
    let res : Result[@git.PackObject?, Error] = try? db.get(fs, id)
    match res {
      Ok(Some(_)) => out.push(id)
      _ => ()
    }
  }
  out
}

///|
fn collect_have_acks_v2(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  haves : Array[@git.ObjectId],
) -> Array[@git.ObjectId] raise @git.GitError {
  let out : Array[@git.ObjectId] = []
  let seen : Map[String, Bool] = {}
  for id in haves {
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    let res : Result[@git.PackObject?, Error] = try? db.get(fs, id)
    match res {
      Ok(Some(_)) => {
        out.push(id)
        seen[hex] = true
      }
      _ => ()
    }
  }
  out
}

///|
fn upload_pack_error_message(
  err : @git.GitError,
  include_pack_objects_died : Bool,
) -> String {
  let base = match err {
    InvalidObject(msg) => upload_pack_map_invalid_object(msg)
    HashMismatch(_, _) => "hash mismatch"
    PackfileError(msg) => msg
    ProtocolError(msg) => msg
    IoError(msg) => msg
  }
  if include_pack_objects_died && not(base.contains("pack-objects died")) {
    base + "\npack-objects died"
  } else {
    base
  }
}

///|
fn upload_pack_map_invalid_object(msg : String) -> String {
  let prefix = "Missing blob object: "
  if msg.has_prefix(prefix) {
    let hex = String::unsafe_substring(
      msg,
      start=prefix.length(),
      end=msg.length(),
    )
    "unable to read " + hex
  } else if msg.has_prefix("Missing tree object") ||
    msg.has_prefix("Object is not a tree") {
    "bad tree object"
  } else if msg.has_prefix("Missing commit object") ||
    msg.has_prefix("Object is not a commit") {
    "not our ref"
  } else {
    msg
  }
}

///|
fn upload_int_to_hex4(n : Int) -> String {
  let digits = "0123456789abcdef"
  let mut result = ""
  let mut v = n
  for _ in 0..<4 {
    let d = v % 16
    result = String::make(1, digits[d].to_int().unsafe_to_char()) + result
    v = v / 16
  }
  result
}

///|
fn upload_default_caps(agent : String) -> String {
  let caps : Array[String] = [
    "multi_ack",
    "multi_ack_detailed",
    "thin-pack",
    "side-band",
    "side-band-64k",
    "ofs-delta",
    "shallow",
    "no-progress",
    "include-tag",
    "no-done",
    "object-format=sha1",
    "agent=\{agent}",
  ]
  caps.join(" ")
}

///|
fn upload_parse_pkt_len(data : Bytes, start : Int) -> Int raise @git.GitError {
  if start + 4 > data.length() {
    raise @git.GitError::ProtocolError("Invalid pkt-line length")
  }
  let mut v = 0
  for i in 0..<4 {
    let c = data[start + i].to_int().unsafe_to_char()
    v = v * 16 + upload_hex_char_to_int(c)
  }
  v
}

///|
fn upload_hex_char_to_int(c : Char) -> Int raise @git.GitError {
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
fn upload_bytes_to_string_range(data : Bytes, start : Int, end : Int) -> String {
  let buf = StringBuilder::new()
  let mut i = start
  while i < end {
    buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  buf.to_string()
}

///|
fn upload_trim_line(line : String) -> String {
  if line.has_suffix("\n") {
    String::unsafe_substring(line, start=0, end=line.length() - 1)
  } else {
    line
  }
}

///|
fn upload_split_by_space(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut buf : Array[Char] = []
  for c in s {
    if c == ' ' {
      out.push(upload_chars_to_string(buf))
      buf = []
    } else {
      buf.push(c)
    }
  }
  out.push(upload_chars_to_string(buf))
  out
}

///|
fn upload_chars_to_string(chars : Array[Char]) -> String {
  let buf = StringBuilder::new()
  for c in chars {
    buf.write_char(c)
  }
  buf.to_string()
}

///|
fn upload_push_bytes(out : Array[Byte], data : Bytes) -> Unit {
  for b in data {
    out.push(b)
  }
}

///|
/// Upload-pack configuration for v2 protocol
pub(all) struct UploadPackConfig {
  allow_filter : Bool
  blob_packfile_uri : String? // If set, packfile-uris is allowed
  allow_ref_in_want : Bool
}

///|
pub fn UploadPackConfig::new(
  allow_filter : Bool,
  blob_packfile_uri : String?,
  allow_ref_in_want : Bool,
) -> UploadPackConfig {
  { allow_filter, blob_packfile_uri, allow_ref_in_want }
}

///|
pub fn UploadPackConfig::default() -> UploadPackConfig {
  { allow_filter: true, blob_packfile_uri: None, allow_ref_in_want: false }
}

///|
/// Handle protocol v2 upload-pack request
pub fn upload_pack_v2(
  fs : &@git.RepoFileSystem,
  root : String,
  req : UploadPackRequestV2,
  config : UploadPackConfig,
) -> Bytes raise @git.GitError {
  // Validate request against config
  if req.filter is Some(_) && not(config.allow_filter) {
    raise @git.GitError::ProtocolError(
      "unexpected line: 'filter " + req.filter.unwrap() + "'",
    )
  }
  if req.packfile_uris is Some(_) && config.blob_packfile_uri is None {
    raise @git.GitError::ProtocolError(
      "unexpected line: 'packfile-uris " + req.packfile_uris.unwrap() + "'",
    )
  }

  // Process the fetch command
  if req.command != "fetch" {
    raise @git.GitError::ProtocolError(
      "unsupported command: '" + req.command + "'",
    )
  }
  let git_dir = join_path(root, ".git")
  let db = ObjectDb::load(fs, git_dir)

  let refs = show_ref(fs, git_dir)
  let ref_map : Map[String, @git.ObjectId] = {}
  for item in refs {
    let (name, id) = item
    ref_map[name] = id
  }

  let all_wants : Array[@git.ObjectId] = []
  for id in req.wants {
    all_wants.push(id)
  }
  let wanted_refs : Array[(String, @git.ObjectId)] = []
  if req.want_refs.length() > 0 {
    if not(config.allow_ref_in_want) {
      raise @git.GitError::ProtocolError("unknown command 'want-ref'")
    }
    for name in req.want_refs {
      match ref_map.get(name) {
        Some(id) => {
          wanted_refs.push((name, id))
          all_wants.push(id)
        }
        None => raise @git.GitError::ProtocolError("unknown ref " + name)
      }
    }
  }

  let seen_wants : Map[String, Bool] = {}
  let wants : Array[@git.ObjectId] = []
  for id in all_wants {
    let hex = id.to_hex()
    if not(seen_wants.contains(hex)) {
      seen_wants[hex] = true
      wants.push(id)
    }
  }

  let ack_ids = collect_have_acks_v2(db, fs, req.haves)
  if not(req.done) {
    return build_upload_pack_response_v2_ack(ack_ids, wanted_refs)
  }

  // Collect objects reachable from wants
  let objects = try collect_reachable_objects_from_commits(db, fs, wants) catch {
    err =>
      raise @git.GitError::ProtocolError(upload_pack_error_message(err, true))
  }

  // Apply partial clone filter (blob:none, blob:limit, tree:depth)
  let filter_spec = match req.filter {
    Some(f) => parse_filter_spec(f)
    None => @git.FilterSpec::NoFilter
  }
  let objects = apply_filter_spec(objects, filter_spec)

  // If client has some objects, filter them out
  let filtered_objects = if req.haves.length() > 0 {
    let have_set : Map[String, Bool] = {}
    let have_objects = collect_reachable_objects_from_commits(db, fs, req.haves)
    for obj in have_objects {
      let id = @git.hash_object_content(obj.obj_type, obj.data)
      have_set[id.to_hex()] = true
    }
    let filtered : Array[@git.PackObject] = []
    for obj in objects {
      let id = @git.hash_object_content(obj.obj_type, obj.data)
      if not(have_set.contains(id.to_hex())) {
        filtered.push(obj)
      }
    }
    filtered
  } else {
    objects
  }

  // Build v2 response
  build_upload_pack_response_v2(filtered_objects, ack_ids, wanted_refs)
}

///|
/// Parse filter specification string (e.g., "blob:none", "blob:limit=1000")
fn parse_filter_spec(spec : String) -> @git.FilterSpec {
  if spec == "blob:none" {
    @git.FilterSpec::BlobNone
  } else if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = @strconv.parse_int64(limit_str) catch { _ => 0L }
    @git.FilterSpec::BlobLimit(limit)
  } else if spec.has_prefix("tree:") {
    let depth_str = String::unsafe_substring(spec, start=5, end=spec.length())
    let depth = @strconv.parse_int(depth_str) catch { _ => 0 }
    @git.FilterSpec::TreeDepth(depth)
  } else {
    @git.FilterSpec::NoFilter
  }
}

///|
/// Apply filter specification to objects
fn apply_filter_spec(
  objects : Array[@git.PackObject],
  filter : @git.FilterSpec,
) -> Array[@git.PackObject] {
  match filter {
    NoFilter => objects
    BlobNone => {
      // Exclude all blobs
      let result : Array[@git.PackObject] = []
      for obj in objects {
        if obj.obj_type != @git.ObjectType::Blob {
          result.push(obj)
        }
      }
      result
    }
    BlobLimit(max_size) => {
      // Exclude blobs larger than max_size
      let result : Array[@git.PackObject] = []
      for obj in objects {
        if obj.obj_type != @git.ObjectType::Blob ||
          obj.data.length().to_int64() <= max_size {
          result.push(obj)
        }
      }
      result
    }
    TreeDepth(_depth) =>
      // Tree depth filtering is complex, not implemented yet
      // For now, return all objects
      objects
  }
}

///|
fn build_upload_pack_response_v2_ack(
  ack_ids : Array[@git.ObjectId],
  wanted_refs : Array[(String, @git.ObjectId)],
) -> Bytes {
  let out : Array[Byte] = []
  if ack_ids.length() > 0 {
    upload_push_bytes(out, @git.pktline_encode("acknowledgments\n"))
    for id in ack_ids {
      upload_push_bytes(out, @git.pktline_encode("ACK " + id.to_hex() + "\n"))
    }
    upload_push_bytes(out, @git.pktline_delim())
  }
  if wanted_refs.length() > 0 {
    upload_push_bytes(out, @git.pktline_encode("wanted-refs\n"))
    for item in wanted_refs {
      let (name, id) = item
      upload_push_bytes(out, @git.pktline_encode("\{id.to_hex()} \{name}\n"))
    }
    upload_push_bytes(out, @git.pktline_delim())
  }
  upload_push_bytes(out, @git.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn build_upload_pack_response_v2(
  objects : Array[@git.PackObject],
  ack_ids : Array[@git.ObjectId],
  wanted_refs : Array[(String, @git.ObjectId)],
) -> Bytes {
  let out : Array[Byte] = []

  if ack_ids.length() > 0 {
    upload_push_bytes(out, @git.pktline_encode("acknowledgments\n"))
    for id in ack_ids {
      upload_push_bytes(out, @git.pktline_encode("ACK " + id.to_hex() + "\n"))
    }
    upload_push_bytes(out, @git.pktline_delim())
  }

  if wanted_refs.length() > 0 {
    upload_push_bytes(out, @git.pktline_encode("wanted-refs\n"))
    for item in wanted_refs {
      let (name, id) = item
      upload_push_bytes(out, @git.pktline_encode("\{id.to_hex()} \{name}\n"))
    }
    upload_push_bytes(out, @git.pktline_delim())
  }

  // Send packfile-section header
  upload_push_bytes(out, @git.pktline_encode("packfile\n"))

  // Create packfile
  let pack = @git.create_packfile(objects)

  // Send packfile via side-band-64k (band 1)
  let chunk_size = 65515 // 65520 - 4 (pkt-line header) - 1 (band byte)
  let mut offset = 0
  while offset < pack.length() {
    let end = if offset + chunk_size > pack.length() {
      pack.length()
    } else {
      offset + chunk_size
    }
    let data_len = end - offset
    let pkt_len = data_len + 5 // 4 (header) + 1 (band byte)
    let len_hex = upload_int_to_hex4(pkt_len)
    for c in len_hex {
      out.push(c.to_int().to_byte())
    }
    out.push(b'\x01') // band 1 = packfile data
    for i in offset..<end {
      out.push(pack[i])
    }
    offset = end
  }

  // Flush packet to end
  upload_push_bytes(out, @git.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}
