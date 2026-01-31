///| Upload-pack protocol helpers (v0/v2)

///|
pub(all) enum ProtocolVersion {
  V0
  V2
} derive(Eq)

///|
pub fn detect_protocol_version(data : Bytes) -> ProtocolVersion raise GitError {
  let lines = pktline_decode(data)
  for item in lines {
    let (line_bytes, is_flush) = item
    if is_flush || line_bytes.length() == 0 {
      continue
    }
    let line = bytes_to_string(line_bytes)
    if line.has_prefix("#") {
      continue
    }
    if line.has_prefix("version 2") {
      return ProtocolVersion::V2
    }
  }
  ProtocolVersion::V0
}

///|
pub fn parse_v2_advertised_caps(data : Bytes) -> Array[String] raise GitError {
  let result : Array[String] = []
  let lines = pktline_decode(data)
  for item in lines {
    let (line_bytes, is_flush) = item
    if is_flush || line_bytes.length() == 0 {
      continue
    }
    let line = trim_newline(bytes_to_string(line_bytes))
    if line.has_prefix("#") || line.has_prefix("version ") {
      continue
    }
    result.push(line)
  }
  result
}

///|
pub fn parse_v0_advertised_caps(data : Bytes) -> Array[String] raise GitError {
  let result : Array[String] = []
  let decoded = pktline_decode(data)
  for item in decoded {
    let (line_bytes, is_flush) = item
    if is_flush || line_bytes.length() == 0 {
      continue
    }
    let line = bytes_to_string(line_bytes)
    match line.find("\u0000") {
      None => continue
      Some(idx) => {
        let caps_str = trim_newline(
          String::unsafe_substring(line, start=idx + 1, end=line.length()),
        )
        let parts = split_by_space(caps_str)
        for p in parts {
          result.push(p)
        }
        break
      }
    }
  }
  result
}

///|
pub fn build_ls_refs_request(agent : String, prefixes : Array[String]) -> Bytes {
  let chunks : Array[Bytes] = []
  chunks.push(pktline_encode("command=ls-refs\n"))
  chunks.push(pktline_encode("agent=\{agent}\n"))
  chunks.push(pktline_encode("object-format=sha1\n"))
  chunks.push(pktline_delim())
  chunks.push(pktline_encode("peel\n"))
  chunks.push(pktline_encode("symrefs\n"))
  chunks.push(pktline_encode("unborn\n"))
  for prefix in prefixes {
    chunks.push(pktline_encode("ref-prefix \{prefix}\n"))
  }
  chunks.push(pktline_flush())
  concat_bytes(chunks)
}

///|
pub struct LsRefsResult {
  refs : Array[(ObjectId, String)]
  symrefs : Map[String, String]
}

///|
pub fn parse_ls_refs_response(data : Bytes) -> LsRefsResult raise GitError {
  let refs : Array[(ObjectId, String)] = []
  let symrefs : Map[String, String] = {}
  let lines = pktline_decode(data)
  for item in lines {
    let (line_bytes, is_flush) = item
    if is_flush || line_bytes.length() == 0 {
      continue
    }
    let line = trim_newline(bytes_to_string(line_bytes))
    let parts = split_by_space(line)
    if parts.length() < 2 {
      continue
    }
    let id = ObjectId::from_hex(parts[0])
    let name = parts[1]
    refs.push((id, name))
    for i in 2..<parts.length() {
      let attr = parts[i]
      if attr.has_prefix("symref-target:") {
        let target = String::unsafe_substring(attr, start=14, end=attr.length())
        symrefs[name] = target
      }
    }
  }
  { refs, symrefs }
}

///|
pub fn select_default_wants(
  refs : Array[(ObjectId, String)],
  symrefs : Map[String, String],
) -> Array[ObjectId] {
  let wants : Array[ObjectId] = []
  match symrefs.get("HEAD") {
    Some(target) =>
      for item in refs {
        let (id, name) = item
        if name == target {
          wants.push(id)
          return wants
        }
      }
    None => ()
  }
  for item in refs {
    let (id, name) = item
    if name == "HEAD" {
      wants.push(id)
      return wants
    }
  }
  if refs.length() > 0 {
    let (id, _) = refs[0]
    wants.push(id)
  }
  wants
}

///|
pub fn select_default_ref(
  refs : Array[(ObjectId, String)],
  symrefs : Map[String, String],
) -> (String, ObjectId)? {
  match symrefs.get("HEAD") {
    Some(target) =>
      for item in refs {
        let (id, name) = item
        if name == target {
          return Some((name, id))
        }
      }
    None => ()
  }
  for item in refs {
    let (id, name) = item
    if name == "HEAD" {
      return Some((name, id))
    }
  }
  if refs.length() > 0 {
    let (id, name) = refs[0]
    return Some((name, id))
  }
  None
}

///|
/// Filter specification for partial clone
pub(all) enum FilterSpec {
  NoFilter // No filter (full clone)
  BlobNone // blob:none - exclude all blobs
  BlobLimit(Int64) // blob:limit=<n> - exclude blobs > n bytes
  TreeDepth(Int) // tree:<depth> - limit tree depth
}

///|
pub fn FilterSpec::to_string(self : FilterSpec) -> String {
  match self {
    NoFilter => ""
    BlobNone => "blob:none"
    BlobLimit(n) => "blob:limit=\{n}"
    TreeDepth(d) => "tree:\{d}"
  }
}

///|
pub fn FilterSpec::is_partial(self : FilterSpec) -> Bool {
  match self {
    NoFilter => false
    _ => true
  }
}

///|
/// Build a fetch request for protocol v2.
/// - depth > 0: shallow clone with that depth
/// - filter: partial clone filter specification
pub fn build_fetch_request_v2(
  agent : String,
  wants : Array[ObjectId],
  depth : Int,
  filter? : FilterSpec = FilterSpec::NoFilter,
) -> Bytes {
  let chunks : Array[Bytes] = []
  chunks.push(pktline_encode("command=fetch\n"))
  chunks.push(pktline_encode("agent=\{agent}\n"))
  chunks.push(pktline_encode("object-format=sha1\n"))
  chunks.push(pktline_delim())
  chunks.push(pktline_encode("thin-pack\n"))
  chunks.push(pktline_encode("no-progress\n"))
  chunks.push(pktline_encode("ofs-delta\n"))
  if depth > 0 {
    chunks.push(pktline_encode("deepen \{depth}\n"))
  }
  // Partial clone filter
  if filter.is_partial() {
    chunks.push(pktline_encode("filter \{filter.to_string()}\n"))
  }
  for want in wants {
    chunks.push(pktline_encode("want \{want.to_hex()}\n"))
  }
  chunks.push(pktline_encode("done\n"))
  chunks.push(pktline_flush())
  concat_bytes(chunks)
}

///|
pub fn build_fetch_request_v0(
  agent : String,
  wants : Array[ObjectId],
  advertised : Array[String],
) -> Bytes {
  if wants.length() == 0 {
    return pktline_flush()
  }
  let caps = select_v0_caps(agent, advertised)
  let chunks : Array[Bytes] = []
  let first = "want \{wants[0].to_hex()} \{caps}\n"
  chunks.push(pktline_encode(first))
  for i in 1..<wants.length() {
    chunks.push(pktline_encode("want \{wants[i].to_hex()}\n"))
  }
  chunks.push(pktline_flush())
  chunks.push(pktline_encode("done\n"))
  chunks.push(pktline_flush())
  concat_bytes(chunks)
}

///|
pub fn extract_pack_from_v2_response(data : Bytes) -> Bytes raise GitError {
  let lines = pktline_decode(data)
  let mut in_pack = false
  let chunks : Array[Byte] = []
  for item in lines {
    let (line_bytes, is_flush) = item
    if is_flush {
      if in_pack {
        break
      }
      continue
    }
    if line_bytes.length() == 0 {
      continue
    }
    if not(in_pack) {
      let line = trim_newline(bytes_to_string(line_bytes))
      if line == "packfile" {
        in_pack = true
      }
      continue
    }
    // side-band: channel byte + payload
    let channel = line_bytes[0].to_int()
    if channel == 1 {
      for i in 1..<line_bytes.length() {
        chunks.push(line_bytes[i])
      }
    } else if channel == 3 {
      let msg = bytes_to_string_from(line_bytes, 1)
      raise GitError::ProtocolError("upload-pack error: \{msg}")
    }
  }
  Bytes::from_array(FixedArray::makei(chunks.length(), fn(i) { chunks[i] }))
}

///|
pub fn extract_pack_from_v0_response(data : Bytes) -> Bytes raise GitError {
  let lines = pktline_decode(data)
  let chunks : Array[Byte] = []
  for item in lines {
    let (line_bytes, is_flush) = item
    if is_flush || line_bytes.length() == 0 {
      continue
    }
    let channel = line_bytes[0].to_int()
    if channel == 1 {
      for i in 1..<line_bytes.length() {
        chunks.push(line_bytes[i])
      }
    } else if channel == 3 {
      let msg = bytes_to_string_from(line_bytes, 1)
      raise GitError::ProtocolError("upload-pack error: \{msg}")
    }
  }
  Bytes::from_array(FixedArray::makei(chunks.length(), fn(i) { chunks[i] }))
}

///|
fn select_v0_caps(agent : String, advertised : Array[String]) -> String {
  let wanted = ["side-band-64k", "thin-pack", "ofs-delta"]
  let caps : Array[String] = []
  for cap in wanted {
    if advertised.contains(cap) {
      caps.push(cap)
    }
  }
  caps.push("agent=\{agent}")
  caps.join(" ")
}

///|
fn trim_newline(s : String) -> String {
  if s.has_suffix("\n") {
    String::unsafe_substring(s, start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
fn bytes_to_string(data : Bytes) -> String {
  let result = StringBuilder::new()
  for b in data {
    result.write_char(b.to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn bytes_to_string_from(data : Bytes, start : Int) -> String {
  if start >= data.length() {
    return ""
  }
  let result = StringBuilder::new()
  for i in start..<data.length() {
    result.write_char(data[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn split_by_space(s : String) -> Array[String] {
  let parts : Array[String] = []
  let mut current = StringBuilder::new()
  for c in s {
    if c == ' ' {
      if current.to_string().length() > 0 {
        parts.push(current.to_string())
        current = StringBuilder::new()
      }
    } else {
      current.write_char(c)
    }
  }
  if current.to_string().length() > 0 {
    parts.push(current.to_string())
  }
  parts
}

///|
fn concat_bytes(chunks : Array[Bytes]) -> Bytes {
  let result : Array[Byte] = []
  for chunk in chunks {
    for b in chunk {
      result.push(b)
    }
  }
  Bytes::from_array(FixedArray::makei(result.length(), fn(i) { result[i] }))
}
