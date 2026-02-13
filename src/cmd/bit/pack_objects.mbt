///|
priv struct PackObjectsConfig {
  revs : Bool
  stdout : Bool
  all : Bool
  delta_mode : @git.PackDeltaMode
  window : Int
  depth : Int
  base_name : String?
  progress : Bool
  path_walk : Bool
  sparse_mode : Bool?
  index_version : Int
  filter : @protocol.FilterSpec
  object_format : String?
  stdin_packs : Bool
  stdin_packs_follow : Bool
  local_only : Bool
  honor_pack_keep : Bool
  incremental : Bool
  unpacked : Bool
  exclude_promisor_objects : Bool
  name_hash_version : Int?
  write_bitmap : Bool
  include_tag : Bool
  has_unsupported_options : Bool
  missing_mode : MissingMode
}

///|
priv enum MissingMode {
  Error
  AllowAny
}

///|
priv enum PackObjectsParse {
  Ok(PackObjectsConfig)
  Unsupported
  Error(String)
}

///|
fn parse_pack_objects_args(args : Array[String]) -> PackObjectsParse {
  let mut revs = false
  let mut stdout = false
  let mut all = false
  let mut delta_mode = @git.PackDeltaMode::RefDelta
  let mut window = 10
  let mut depth = 50
  let mut base_name : String? = None
  let mut progress = false
  let mut path_walk = false
  let mut sparse_mode : Bool? = None
  let index_version = 2
  let mut filter = @protocol.FilterSpec::NoFilter
  let mut object_format : String? = None
  let mut stdin_packs = false
  let mut stdin_packs_follow = false
  let mut local_only = false
  let mut honor_pack_keep = false
  let mut incremental = false
  let mut unpacked = false
  let mut exclude_promisor_objects = false
  let mut name_hash_version : Int? = None
  let mut write_bitmap = false
  let mut include_tag = false
  let mut has_unsupported_options = false
  let mut missing_mode = MissingMode::Error
  let mut i = 0
  let mut in_opts = true
  let mut extra_args = 0
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg.has_prefix("-") {
      match arg {
        "--revs" => revs = true
        "--stdout" => stdout = true
        "--all" => all = true
        "--delta-base-offset" => delta_mode = @git.PackDeltaMode::OfsDelta
        "--local" => local_only = true
        "--honor-pack-keep" => honor_pack_keep = true
        "--incremental" => incremental = true
        "--unpacked" => unpacked = true
        "--path-walk" => path_walk = true
        "--no-path-walk" => ()
        "--sparse" => sparse_mode = Some(true)
        "--no-sparse" => sparse_mode = Some(false)
        "--non-empty" => has_unsupported_options = true
        "--reflog" => has_unsupported_options = true
        "--indexed-objects" => has_unsupported_options = true
        "--keep-true-parents" => has_unsupported_options = true
        "--thin" => has_unsupported_options = true
        "--cruft" => has_unsupported_options = true
        "--cruft-expiration" => {
          has_unsupported_options = true
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          i += 1
        }
        "--max-cruft-size" => {
          has_unsupported_options = true
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          i += 1
        }
        "--max-pack-size" => {
          has_unsupported_options = true
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          i += 1
        }
        "--include-tag" => include_tag = true
        "--stdin-packs" => stdin_packs = true
        "--stdin-packs=follow" => {
          stdin_packs = true
          stdin_packs_follow = true
        }
        "--unpack-unreachable" => has_unsupported_options = true
        "--keep-unreachable" => has_unsupported_options = true
        "--pack-loose-unreachable" => has_unsupported_options = true
        "--keep-pack" => {
          has_unsupported_options = true
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          i += 1
        }
        "--write-bitmap-index" => write_bitmap = true
        "--progress" => progress = true
        "--no-progress" => ()
        "--use-bitmap-index" => ()
        "--no-use-bitmap-index" => ()
        "--quiet" => ()
        "-q" => ()
        "--exclude-promisor-objects" => exclude_promisor_objects = true
        "--stdin" =>
          return PackObjectsParse::Error(
            "fatal: disallowed abbreviated or ambiguous option 'stdin'",
          )
        "--object-format" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          object_format = normalize_object_format(args[i + 1])
          if object_format is None {
            return PackObjectsParse::Unsupported
          }
          i += 1
        }
        "--window" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          let value = args[i + 1]
          let parsed = @strconv.parse_int(value) catch {
            _ => return PackObjectsParse::Unsupported
          }
          window = parsed
          i += 1
        }
        "--depth" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          let value = args[i + 1]
          let parsed = @strconv.parse_int(value) catch {
            _ => return PackObjectsParse::Unsupported
          }
          depth = parsed
          i += 1
        }
        "--name-hash-version" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          let value = args[i + 1]
          let parsed = @strconv.parse_int(value) catch {
            _ => return PackObjectsParse::Unsupported
          }
          let normalized = if parsed < 0 { 1 } else { parsed }
          if normalized == 0 || normalized > 2 {
            return PackObjectsParse::Error(
              "fatal: invalid --name-hash-version option",
            )
          }
          name_hash_version = Some(normalized)
          i += 1
        }
        "--index-version" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          has_unsupported_options = true
          i += 1
        }
        _ =>
          if arg.has_prefix("--window=") {
            let value = (try! arg[9:]).to_string()
            let parsed = @strconv.parse_int(value) catch {
              _ => return PackObjectsParse::Unsupported
            }
            window = parsed
          } else if arg.has_prefix("--index-version=") {
            has_unsupported_options = true
          } else if arg == "--index-version" {
            has_unsupported_options = true
            if i + 1 < args.length() {
              i += 1
            }
          } else if arg.has_prefix("--filter=") {
            let spec = String::unsafe_substring(arg, start=9, end=arg.length())
            filter = parse_pack_filter_spec(spec)
            has_unsupported_options = true
          } else if arg == "--filter" {
            if i + 1 >= args.length() {
              return PackObjectsParse::Unsupported
            }
            filter = parse_pack_filter_spec(args[i + 1])
            has_unsupported_options = true
            i += 1
          } else if arg.has_prefix("--object-format=") {
            object_format = normalize_object_format((try! arg[16:]).to_string())
            if object_format is None {
              return PackObjectsParse::Unsupported
            }
          } else if arg.has_prefix("--name-hash-version=") {
            let value = (try! arg[20:]).to_string()
            let parsed = @strconv.parse_int(value) catch {
              _ => return PackObjectsParse::Unsupported
            }
            let normalized = if parsed < 0 { 1 } else { parsed }
            if normalized == 0 || normalized > 2 {
              return PackObjectsParse::Error(
                "fatal: invalid --name-hash-version option",
              )
            }
            name_hash_version = Some(normalized)
          } else if arg.has_prefix("--index-version=") {
            has_unsupported_options = true
          } else if arg.has_prefix("--missing=") {
            let value = (try! arg[10:]).to_string()
            match value {
              "allow-any" => missing_mode = MissingMode::AllowAny
              "error" => missing_mode = MissingMode::Error
              _ => return PackObjectsParse::Unsupported
            }
          } else if arg.has_prefix("--depth=") {
            let value = (try! arg[8:]).to_string()
            let parsed = @strconv.parse_int(value) catch {
              _ => return PackObjectsParse::Unsupported
            }
            depth = parsed
          } else if arg.has_prefix("--cruft-expiration=") ||
            arg.has_prefix("--max-cruft-size=") ||
            arg.has_prefix("--max-pack-size=") {
            has_unsupported_options = true
          } else if arg.has_prefix("--unpack-unreachable=") {
            has_unsupported_options = true
          } else if arg.has_prefix("--keep-pack=") {
            has_unsupported_options = true
          } else if arg.has_prefix("--stdin-packs") ||
            arg.has_prefix("--write-bitmap-index") ||
            arg.has_prefix("--threads") ||
            arg.has_prefix("--revs=") ||
            arg.has_prefix("--keep") ||
            arg.has_prefix("--no-reuse") ||
            arg.has_prefix("--reuse") ||
            arg.has_prefix("--delta-islands") {
            if arg.has_prefix("--no-reuse") {
              has_unsupported_options = true
            } else {
              return PackObjectsParse::Unsupported
            }
          } else {
            return PackObjectsParse::Unsupported
          }
      }
      i += 1
      continue
    }
    if base_name is None {
      base_name = Some(arg)
    } else {
      extra_args += 1
    }
    i += 1
  }
  if extra_args > 0 {
    return PackObjectsParse::Error("fatal: too many arguments")
  }
  if window < 0 {
    window = 0
  }
  if depth < 0 {
    depth = 0
  }
  if depth == 0 {
    delta_mode = @git.PackDeltaMode::NoDelta
  }
  let has_filter = match filter {
    @protocol.FilterSpec::NoFilter => false
    _ => true
  }
  if stdin_packs && has_filter {
    return PackObjectsParse::Error(
      "fatal: options '--stdin-packs' and '--filter' cannot be used together",
    )
  }
  if stdin_packs && revs {
    return PackObjectsParse::Error(
      "fatal: cannot use internal rev list with --stdin-packs",
    )
  }
  if !stdout && base_name is None {
    return PackObjectsParse::Unsupported
  }
  PackObjectsParse::Ok({
    revs,
    stdout,
    all,
    delta_mode,
    window,
    depth,
    base_name,
    progress,
    path_walk,
    sparse_mode,
    index_version,
    filter,
    object_format,
    stdin_packs,
    stdin_packs_follow,
    local_only,
    honor_pack_keep,
    incremental,
    unpacked,
    exclude_promisor_objects,
    name_hash_version,
    write_bitmap,
    include_tag,
    has_unsupported_options,
    missing_mode,
  })
}

///|
/// Parse filter specification for pack-objects
fn parse_pack_filter_spec(spec : String) -> @protocol.FilterSpec {
  if spec == "blob:none" {
    @protocol.FilterSpec::BlobNone
  } else if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = @strconv.parse_int64(limit_str) catch { _ => 0L }
    @protocol.FilterSpec::BlobLimit(limit)
  } else if spec.has_prefix("tree:") {
    let depth_str = String::unsafe_substring(spec, start=5, end=spec.length())
    let depth = @strconv.parse_int(depth_str) catch { _ => 0 }
    @protocol.FilterSpec::TreeDepth(depth)
  } else {
    @protocol.FilterSpec::NoFilter
  }
}

///|
/// Apply filter specification to objects
fn apply_pack_filter_spec(
  objects : Array[@git.PackObject],
  filter : @protocol.FilterSpec,
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
      objects
  }
}

///|
fn split_lines_bytes(input : Bytes) -> Array[BytesView] {
  let out : Array[BytesView] = []
  let len = input.length()
  let mut start = 0
  for i in 0..<len {
    if input[i] == b'\n' {
      let mut end = i
      if end > start && input[end - 1] == b'\r' {
        end -= 1
      }
      out.push(input[start:end])
      start = i + 1
    }
  }
  let mut end = len
  if end > start && input[end - 1] == b'\r' {
    end -= 1
  }
  out.push(input[start:end])
  out
}

///|
fn is_space_byte(b : Byte) -> Bool {
  b == b' ' || b == b'\t' || b == b'\r'
}

///|
fn trim_line_bytes(line : BytesView) -> BytesView {
  let mut start = 0
  let mut end = line.length()
  while start < end && is_space_byte(line[start]) {
    start += 1
  }
  while end > start && is_space_byte(line[end - 1]) {
    end -= 1
  }
  line[start:end]
}

///|
fn hex_byte_to_int(b : Byte) -> Int? {
  if b >= b'0' && b <= b'9' {
    return Some((b - b'0').to_int())
  }
  if b >= b'a' && b <= b'f' {
    return Some((b - b'a').to_int() + 10)
  }
  if b >= b'A' && b <= b'F' {
    return Some((b - b'A').to_int() + 10)
  }
  None
}

///|
fn parse_object_id_bytes(line : BytesView) -> @git.ObjectId? {
  let trimmed = trim_line_bytes(line)
  if trimmed.length() == 0 {
    return None
  }
  let mut end = trimmed.length()
  for i in 0..<trimmed.length() {
    if is_space_byte(trimmed[i]) {
      end = i
      break
    }
  }
  let mut hex_view = trimmed[:end]
  if hex_view.length() > 0 && (hex_view[0] == b'-' || hex_view[0] == b'^') {
    hex_view = hex_view[1:hex_view.length()]
  }
  if hex_view.length() != 40 {
    return None
  }
  let bytes = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    let hi = hex_byte_to_int(hex_view[i * 2])
    let lo = hex_byte_to_int(hex_view[i * 2 + 1])
    match (hi, lo) {
      (Some(h), Some(l)) => bytes[i] = ((h << 4) | l).to_byte()
      _ => return None
    }
  }
  bytes |> @git.ObjectId::new |> Some
}

///|
fn looks_like_sha256_line(line : BytesView) -> Bool {
  let trimmed = trim_line_bytes(line)
  if trimmed.length() == 0 {
    return false
  }
  let mut start = 0
  if trimmed[0] == b'^' {
    start = 1
  }
  if trimmed.length() < start + 64 {
    return false
  }
  for i in 0..<64 {
    if hex_byte_to_int(trimmed[start + i]) is None {
      return false
    }
  }
  true
}

///|
fn line_to_string(line : BytesView) -> String {
  let decoder = @encoding.decoder(@encoding.Encoding::UTF8)
  decoder.decode_lossy(line)
}

///|
fn invalid_object_line_message(line : String) -> String {
  if line.length() == 0 {
    "fatal: expected object ID, got garbage:\n \n\n"
  } else {
    "fatal: expected object ID, got garbage:\n " + line + "\n\n"
  }
}

///|
fn parse_tag_target_id(data : Bytes) -> @git.ObjectId? {
  let lines = split_lines_bytes(data)
  for line in lines {
    let trimmed = trim_line_bytes(line)
    if trimmed.length() == 0 {
      break
    }
    let text = line_to_string(trimmed)
    if text.has_prefix("object ") {
      let hex = (try! text[7:]).to_string()
      let id = @git.ObjectId::from_hex(hex) catch { _ => return None }
      return Some(id)
    }
  }
  None
}

///|
fn resolve_tag_chain(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  start : @git.ObjectId,
) -> (Array[@git.PackObject], @git.ObjectId?) {
  let chain : Array[@git.PackObject] = []
  let seen : Map[String, Bool] = {}
  let mut current = start
  let mut resolved : @git.ObjectId? = None
  while true {
    let key = current.to_hex()
    if seen.contains(key) {
      resolved = None
      break
    }
    seen[key] = true
    let obj = try db.get(fs, current) catch {
      _ => None
    } noraise {
      value => value
    }
    match obj {
      Some(o) if o.obj_type == @git.ObjectType::Tag => {
        chain.push(o)
        match parse_tag_target_id(o.data) {
          Some(next) => {
            current = next
            continue
          }
          None => {
            resolved = None
            break
          }
        }
      }
      Some(_) => {
        resolved = Some(current)
        break
      }
      None => {
        resolved = None
        break
      }
    }
  }
  (chain, resolved)
}

///|
fn collect_include_tag_objects(
  fs : OsFs,
  git_dir : String,
  db : @gitlib.ObjectDb,
  objects : Array[@git.PackObject],
) -> Array[@git.PackObject] {
  let included : Map[String, Bool] = {}
  for obj in objects {
    included[object_hex(obj)] = true
  }
  let refs = @gitrepo.show_ref(fs, git_dir) catch { _ => [] }
  let added : Map[String, Bool] = {}
  let out : Array[@git.PackObject] = []
  for pair in refs {
    let (_name, id) = pair
    let (chain, target) = resolve_tag_chain(db, fs, id)
    match target {
      Some(t) if included.contains(t.to_hex()) =>
        for tag in chain {
          let tag_hex = object_hex(tag)
          if added.contains(tag_hex) {
            continue
          }
          added[tag_hex] = true
          included[tag_hex] = true
          out.push(tag)
        }
      _ => ()
    }
  }
  out
}

///|
fn parse_stdin_pack_lines(input : Bytes) -> (Array[String], Array[String]) {
  let lines = split_lines_bytes(input)
  let include_names : Array[String] = []
  let exclude_names : Array[String] = []
  for line in lines {
    let trimmed = trim_line_bytes(line)
    if trimmed.length() == 0 {
      continue
    }
    let text = line_to_string(trimmed)
    if text.has_prefix("^") {
      exclude_names.push((try! text[1:]).to_string())
    } else {
      include_names.push(text)
    }
  }
  (include_names, exclude_names)
}

///|
fn parse_pack_index_ids(data : Bytes) -> Array[String]? {
  if data.length() < 8 {
    return None
  }
  let magic = read_u32_be_i64(data, 0)
  if magic != 0xff744f63L {
    return None
  }
  let version = read_u32_be_i64(data, 4)
  if version != 2L {
    return None
  }
  let mut offset = 8
  let mut count64 = 0L
  for _ in 0..<256 {
    if offset + 4 > data.length() {
      return None
    }
    count64 = read_u32_be_i64(data, offset)
    offset += 4
  }
  if count64 > 2147483647L {
    return None
  }
  let count = count64.to_int()
  let ids : Array[String] = []
  for _ in 0..<count {
    if offset + 20 > data.length() {
      return None
    }
    let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
    for i in 0..<20 {
      bytes[i] = data[offset + i]
    }
    offset += 20
    ids.push(@git.ObjectId::new(bytes).to_hex())
  }
  Some(ids)
}

///|
fn normalize_dir_entry(entry : String) -> String {
  match entry.rev_find("/") {
    None => entry
    Some(pos) =>
      if pos + 1 >= entry.length() {
        ""
      } else {
        (try! entry[pos + 1:]).to_string()
      }
  }
}

///|
fn collect_pack_index_ids(fs : OsFs, idx_path : String) -> Array[String] {
  let data = fs.read_file(idx_path) catch { _ => return [] }
  match parse_pack_index_ids(data) {
    Some(ids) => ids
    None => []
  }
}

///|
fn collect_pack_ids_from_dir(fs : OsFs, pack_dir : String) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  if !fs.is_dir(pack_dir) {
    return out
  }
  let entries = fs.readdir(pack_dir) catch { _ => [] }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if not(name.has_suffix(".idx")) {
      continue
    }
    let idx_path = pack_dir + "/" + name
    if not(fs.is_file(idx_path)) {
      continue
    }
    let ids = collect_pack_index_ids(fs, idx_path)
    for id in ids {
      out[id] = true
    }
  }
  out
}

///|
fn collect_pack_ids_from_marker(
  fs : OsFs,
  pack_dir : String,
  suffix : String,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  if !fs.is_dir(pack_dir) {
    return out
  }
  let entries = fs.readdir(pack_dir) catch { _ => [] }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if not(name.has_suffix(suffix)) {
      continue
    }
    let base = (try! name[:name.length() - suffix.length()]).to_string()
    let idx_path = pack_dir + "/" + base + ".idx"
    if not(fs.is_file(idx_path)) {
      continue
    }
    let ids = collect_pack_index_ids(fs, idx_path)
    for id in ids {
      out[id] = true
    }
  }
  out
}

///|
fn collect_loose_object_ids(
  fs : OsFs,
  objects_dir : String,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  if !fs.is_dir(objects_dir) {
    return out
  }
  let entries = fs.readdir(objects_dir) catch { _ => [] }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if name == "info" || name == "pack" {
      continue
    }
    if name.length() != 2 || (name |> is_hex_string |> not) {
      continue
    }
    let subdir = objects_dir + "/" + name
    if !fs.is_dir(subdir) {
      continue
    }
    let files = fs.readdir(subdir) catch { _ => [] }
    for file in files {
      let filename = normalize_dir_entry(file)
      if filename.length() != 38 || (filename |> is_hex_string |> not) {
        continue
      }
      out[name + filename] = true
    }
  }
  out
}

///|
fn read_alternate_object_dirs(fs : OsFs, git_dir : String) -> Array[String] {
  let out : Array[String] = []
  let alt_path = git_dir + "/objects/info/alternates"
  if not(fs.is_file(alt_path)) {
    return out
  }
  let data = fs.read_file(alt_path) catch { _ => return out }
  let base_dir = parent_dir(alt_path)
  let lines = split_lines_bytes(data)
  for line in lines {
    let trimmed = trim_line_bytes(line)
    if trimmed.length() == 0 {
      continue
    }
    let text = line_to_string(trimmed)
    if text.has_prefix("#") {
      continue
    }
    let resolved = if text.has_prefix("/") {
      text
    } else {
      normalize_path(base_dir + "/" + text)
    }
    if fs.is_dir(resolved) {
      out.push(resolved)
    }
  }
  out
}

///|
fn load_object_lookup_dbs(
  fs : OsFs,
  git_dir : String,
  primary : @gitlib.ObjectDb,
) -> Array[@gitlib.ObjectDb] {
  let out : Array[@gitlib.ObjectDb] = [primary]
  let seen : Map[String, Bool] = {}
  seen[normalize_path(primary.objects_dir)] = true
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  for alt_dir in alt_dirs {
    let normalized = normalize_path(alt_dir)
    if seen.contains(normalized) {
      continue
    }
    let alt_db = @gitlib.ObjectDb::load_from_objects_dir(fs, alt_dir) catch {
      _ => continue
    }
    seen[normalized] = true
    out.push(alt_db)
  }
  out
}

///|
fn find_object_in_lookup_dbs(
  dbs : Array[@gitlib.ObjectDb],
  fs : OsFs,
  id : @git.ObjectId,
) -> @git.PackObject? {
  for db in dbs {
    let obj = db.get(fs, id) catch {
      _ => None
    }
    if obj is Some(found) {
      return Some(found)
    }
  }
  None
}

///|
fn resolve_pack_path(
  fs : OsFs,
  pack_dir : String,
  alt_objects_dirs : Array[String],
  name : String,
) -> String? {
  let mut pack_name = name
  if pack_name.has_suffix(".idx") {
    pack_name = (try! pack_name[:pack_name.length() - 4]).to_string() + ".pack"
  }
  if pack_name.has_prefix("/") || pack_name.contains("/") {
    let path = resolve_in_cwd(pack_name)
    if fs.is_file(path) {
      return Some(path)
    }
  }
  let local_path = pack_dir + "/" + pack_name
  if fs.is_file(local_path) {
    return Some(local_path)
  }
  for alt_dir in alt_objects_dirs {
    let alt_pack_dir = alt_dir + "/pack"
    let alt_path = alt_pack_dir + "/" + pack_name
    if fs.is_file(alt_path) {
      return Some(alt_path)
    }
  }
  None
}

///|
fn read_pack_objects(fs : OsFs, pack_path : String) -> Array[@git.PackObject] {
  let data = fs.read_file(pack_path) catch { _ => return [] }
  @pack.parse_packfile(data) catch {
    _ => []
  }
}

///|
fn object_hex(obj : @git.PackObject) -> String {
  @git.hash_object_content(obj.obj_type, obj.data).to_hex()
}

///|
fn dedup_objects(objects : Array[@git.PackObject]) -> Array[@git.PackObject] {
  let seen : Map[String, Bool] = {}
  let out : Array[@git.PackObject] = []
  for obj in objects {
    let hex = object_hex(obj)
    if not(seen.contains(hex)) {
      seen[hex] = true
      out.push(obj)
    }
  }
  out
}

///|
fn filter_objects(
  objects : Array[@git.PackObject],
  exclude : Map[String, Bool],
) -> Array[@git.PackObject] {
  if exclude.length() == 0 {
    return objects
  }
  let out : Array[@git.PackObject] = []
  for obj in objects {
    let hex = object_hex(obj)
    if not(exclude.contains(hex)) {
      out.push(obj)
    }
  }
  out
}

///|
async fn report_collect_error(err : @git.GitError) -> Unit {
  match err {
    @git.GitError::InvalidObject(msg) =>
      if msg.contains("Missing tree object") {
        @stdio.stderr.write("fatal: bad tree object\n")
      } else if msg.contains("Missing commit object") {
        @stdio.stderr.write("fatal: bad commit object\n")
      } else if msg.contains("Missing blob object") {
        @stdio.stderr.write("fatal: missing blob object\n")
      } else {
        @stdio.stderr.write("fatal: " + msg + "\n")
      }
    @git.GitError::HashMismatch(expected, actual) =>
      @stdio.stderr.write(
        "fatal: hash mismatch (expected " + expected + ", got " + actual + ")\n",
      )
    @git.GitError::PackfileError(msg) =>
      @stdio.stderr.write("fatal: " + msg + "\n")
    @git.GitError::ProtocolError(msg) =>
      @stdio.stderr.write("fatal: " + msg + "\n")
    @git.GitError::IoError(msg) => @stdio.stderr.write("fatal: " + msg + "\n")
  }
  @sys.exit(1)
}

///|
fn count_pack_reused_objects(
  fs : OsFs,
  git_dir : String,
  pack_dir : String,
  objects : Array[@git.PackObject],
) -> Int {
  let packed_ids = collect_pack_ids_from_dir(fs, pack_dir)
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  for alt_dir in alt_dirs {
    let alt_pack_dir = alt_dir + "/pack"
    let alt_pack_ids = collect_pack_ids_from_dir(fs, alt_pack_dir)
    for item in alt_pack_ids {
      let (hex, _v) = item
      packed_ids[hex] = true
    }
  }
  let mut count = 0
  for obj in objects {
    if packed_ids.contains(obj.id.to_hex()) {
      count += 1
    }
  }
  count
}

///|
fn pack_idx_path(pack_path : String) -> String {
  if pack_path.has_suffix(".pack") {
    let base = (try! pack_path[:pack_path.length() - 5]).to_string()
    base + ".idx"
  } else {
    pack_path + ".idx"
  }
}

///|
fn corrupt_pack_file(fs : OsFs, pack_path : String) -> Unit {
  try {
    let data = fs.read_file(pack_path)
    if data.length() == 0 {
      return
    }
    let bytes : FixedArray[Byte] = FixedArray::makei(data.length(), fn(i) {
      data[i]
    })
    let last = data.length() - 1
    let v = bytes[last].to_int()
    bytes[last] = (v ^ 1).to_byte()
    fs.write_file(pack_path, Bytes::from_array(bytes))
  } catch {
    _ => ()
  }
}

///|
fn is_promisor_pack(fs : OsFs, pack_path : String) -> Bool {
  let base = if pack_path.has_suffix(".pack") {
    (try! pack_path[:pack_path.length() - 5]).to_string()
  } else {
    pack_path
  }
  let promisor_path = base + ".promisor"
  fs.is_file(promisor_path)
}

///|
fn collect_loose_objects(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  objects_dir : String,
) -> Array[@git.PackObject] {
  let out : Array[@git.PackObject] = []
  let ids = collect_loose_object_ids(fs, objects_dir)
  for item in ids {
    let (hex, _v) = item
    let id = @git.ObjectId::from_hex(hex) catch { _ => continue }
    try db.get(fs, id) catch {
      _ => ()
    } noraise {
      value =>
        match value {
          Some(obj) => out.push(obj)
          None => ()
        }
    }
  }
  out
}

///|
fn append_commit_ids_from_objects(
  objects : Array[@git.PackObject],
  out : Array[@git.ObjectId],
) -> Unit {
  for obj in objects {
    if obj.obj_type == @git.ObjectType::Commit {
      out.push(@git.hash_object_content(obj.obj_type, obj.data))
    }
  }
}

///|

///|
fn collect_objects_from_ref_allow_missing(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  id : @git.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@git.PackObject],
) -> Unit {
  let hex = id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  let obj = try db.get(fs, id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) =>
      match o.obj_type {
        @git.ObjectType::Commit =>
          collect_commit_objects_allow_missing(db, fs, id, blocked, seen, out)
        @git.ObjectType::Tree =>
          collect_tree_objects_allow_missing(db, fs, id, blocked, seen, out)
        @git.ObjectType::Blob =>
          collect_blob_object_allow_missing(db, fs, id, blocked, seen, out)
        @git.ObjectType::Tag => {
          seen[hex] = true
          out.push(o)
          match parse_tag_target_id(o.data) {
            Some(target) =>
              collect_objects_from_ref_allow_missing(
                db, fs, target, blocked, seen, out,
              )
            None => ()
          }
        }
      }
    None => ()
  }
}

///|
fn collect_reachable_objects_from_commits_allow_missing(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commits : Array[@git.ObjectId],
  blocked : Map[String, Bool],
) -> Array[@git.PackObject] {
  let seen : Map[String, Bool] = {}
  let out : Array[@git.PackObject] = []
  for commit_id in commits {
    collect_commit_objects_allow_missing(db, fs, commit_id, blocked, seen, out)
  }
  out
}

///|
fn collect_commit_objects_allow_missing(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commit_id : @git.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@git.PackObject],
) -> Unit {
  let hex = commit_id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  seen[hex] = true
  let obj = try db.get(fs, commit_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Commit => {
      out.push(o)
      let info = @git.parse_commit(o.data) catch { _ => return () }
      collect_tree_objects_allow_missing(db, fs, info.tree, blocked, seen, out)
      for parent in info.parents {
        collect_commit_objects_allow_missing(db, fs, parent, blocked, seen, out)
      }
    }
    _ => ()
  }
}

///|
fn collect_tree_objects_allow_missing(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@git.PackObject],
) -> Unit {
  let hex = tree_id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  seen[hex] = true
  let obj = try db.get(fs, tree_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Tree => {
      out.push(o)
      let entries = @git.parse_tree(o.data) catch { _ => return () }
      for entry in entries {
        if entry.mode.has_prefix("40") {
          collect_tree_objects_allow_missing(
            db,
            fs,
            entry.id,
            blocked,
            seen,
            out,
          )
        } else {
          collect_blob_object_allow_missing(
            db,
            fs,
            entry.id,
            blocked,
            seen,
            out,
          )
        }
      }
    }
    _ => ()
  }
}

///|
fn collect_blob_object_allow_missing(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  blob_id : @git.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@git.PackObject],
) -> Unit {
  let hex = blob_id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  seen[hex] = true
  try db.get(fs, blob_id) catch {
    _ => ()
  } noraise {
    value =>
      match value {
        Some(o) if o.obj_type == @git.ObjectType::Blob => out.push(o)
        _ => ()
      }
  }
}

///|
fn collect_excluded_commit_ids(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  exclude_commits : Array[@git.ObjectId],
) -> Map[String, Bool] {
  let excluded : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = []
  for id in exclude_commits {
    queue.push(id)
  }
  while queue.length() > 0 {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if excluded.contains(hex) {
      continue
    }
    excluded[hex] = true
    let obj = try db.get(fs, id) catch {
      _ => None
    } noraise {
      value => value
    }
    match obj {
      Some(o) if o.obj_type == @git.ObjectType::Commit => {
        let info = @git.parse_commit(o.data) catch { _ => continue }
        for parent in info.parents {
          queue.push(parent)
        }
      }
      _ => ()
    }
  }
  excluded
}

///|
fn read_commit_tree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commit_id : @git.ObjectId,
) -> @git.ObjectId? {
  let obj = try db.get(fs, commit_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Commit => {
      let info = @git.parse_commit(o.data) catch { _ => return None }
      Some(info.tree)
    }
    _ => None
  }
}

///|
fn find_excluded_parent_tree(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  parents : Array[@git.ObjectId],
  excluded : Map[String, Bool],
) -> @git.ObjectId? {
  for parent in parents {
    if excluded.contains(parent.to_hex()) {
      match read_commit_tree(db, fs, parent) {
        Some(tree_id) => return Some(tree_id)
        None => ()
      }
    }
  }
  None
}

///|
fn collect_sparse_tree_objects(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  base_tree_id : @git.ObjectId?,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@git.PackObject],
) -> Unit {
  let hex = tree_id.to_hex()
  if seen.contains(hex) {
    return ()
  }
  let obj = try db.get(fs, tree_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Tree => {
      let entries = @git.parse_tree(o.data) catch { _ => return () }
      let base_entries : Map[String, @git.TreeEntry] = {}
      match base_tree_id {
        Some(base_id) => {
          let base_obj = try db.get(fs, base_id) catch {
            _ => None
          } noraise {
            value => value
          }
          match base_obj {
            Some(bo) if bo.obj_type == @git.ObjectType::Tree => {
              let base_list = @git.parse_tree(bo.data) catch { _ => [] }
              for entry in base_list {
                base_entries[entry.name] = entry
              }
            }
            _ => ()
          }
        }
        None => ()
      }
      let mut has_change = base_tree_id is None
      for entry in entries {
        let base_entry = base_entries.get(entry.name)
        match base_entry {
          Some(be) if be.id == entry.id && be.mode == entry.mode => continue
          _ => ()
        }
        has_change = true
        if entry.mode.has_prefix("40") {
          let base_child = match base_entry {
            Some(be) => Some(be.id)
            None => None
          }
          collect_sparse_tree_objects(
            db,
            fs,
            entry.id,
            base_child,
            blocked,
            seen,
            out,
          )
        } else {
          collect_blob_object_allow_missing(
            db,
            fs,
            entry.id,
            blocked,
            seen,
            out,
          )
        }
      }
      if has_change {
        seen[hex] = true
        out.push(o)
      }
    }
    _ => ()
  }
}

///|
fn collect_sparse_commit_objects(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  commit_id : @git.ObjectId,
  excluded : Map[String, Bool],
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@git.PackObject],
) -> Unit {
  let hex = commit_id.to_hex()
  if excluded.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  seen[hex] = true
  let obj = try db.get(fs, commit_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @git.ObjectType::Commit => {
      out.push(o)
      let info = @git.parse_commit(o.data) catch { _ => return () }
      let base_tree = find_excluded_parent_tree(db, fs, info.parents, excluded)
      collect_sparse_tree_objects(
        db,
        fs,
        info.tree,
        base_tree,
        blocked,
        seen,
        out,
      )
      for parent in info.parents {
        collect_sparse_commit_objects(
          db, fs, parent, excluded, blocked, seen, out,
        )
      }
    }
    _ => ()
  }
}

///|
fn collect_sparse_objects_from_commits(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  include_commits : Array[@git.ObjectId],
  exclude_commits : Array[@git.ObjectId],
) -> Array[@git.PackObject] {
  let excluded = collect_excluded_commit_ids(db, fs, exclude_commits)
  let blocked : Map[String, Bool] = {}
  let seen : Map[String, Bool] = {}
  let out : Array[@git.PackObject] = []
  for commit_id in include_commits {
    collect_sparse_commit_objects(
      db, fs, commit_id, excluded, blocked, seen, out,
    )
  }
  out
}

///|
async fn collect_objects_from_stdin_packs(
  fs : OsFs,
  git_dir : String,
  db : @gitlib.ObjectDb,
  cfg : PackObjectsConfig,
  include_names : Array[String],
  exclude_names : Array[String],
) -> Array[@git.PackObject] {
  let pack_dir = git_dir + "/objects/pack"
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  let include_paths : Array[String] = []
  let exclude_paths : Array[String] = []
  for name in include_names {
    match resolve_pack_path(fs, pack_dir, alt_dirs, name) {
      Some(path) => include_paths.push(path)
      None => {
        @stdio.stderr.write("fatal: cannot find packfile '" + name + "'\n")
        @sys.exit(1)
      }
    }
  }
  for name in exclude_names {
    match resolve_pack_path(fs, pack_dir, alt_dirs, name) {
      Some(path) => exclude_paths.push(path)
      None => ()
    }
  }
  if cfg.exclude_promisor_objects {
    for path in include_paths {
      if is_promisor_pack(fs, path) {
        @stdio.stderr.write(
          "fatal: packfile '" +
          path +
          "' is a promisor but --exclude-promisor-objects was given\n",
        )
        @sys.exit(1)
      }
    }
  }
  let include_objects : Array[@git.PackObject] = []
  let seed_commits : Array[@git.ObjectId] = []
  for path in include_paths {
    let objs = read_pack_objects(fs, path)
    for obj in objs {
      include_objects.push(obj)
    }
  }
  if cfg.stdin_packs_follow {
    append_commit_ids_from_objects(include_objects, seed_commits)
  }
  let exclude_ids : Map[String, Bool] = {}
  for path in exclude_paths {
    let idx_path = pack_idx_path(path)
    let ids = collect_pack_index_ids(fs, idx_path)
    for id in ids {
      exclude_ids[id] = true
    }
  }
  let mut promisor_ids : Map[String, Bool] = {}
  if cfg.exclude_promisor_objects {
    promisor_ids = collect_pack_ids_from_marker(fs, pack_dir, ".promisor")
    for alt_dir in alt_dirs {
      let alt_pack_dir = alt_dir + "/pack"
      let ids = collect_pack_ids_from_marker(fs, alt_pack_dir, ".promisor")
      for item in ids {
        let (hex, _v) = item
        promisor_ids[hex] = true
      }
    }
  }
  let mut objects : Array[@git.PackObject] = include_objects
  if cfg.unpacked {
    let objects_dir = git_dir + "/objects"
    let loose = collect_loose_objects(fs, db, objects_dir)
    objects.append(loose)
    if cfg.stdin_packs_follow {
      append_commit_ids_from_objects(loose, seed_commits)
    }
  }
  if cfg.stdin_packs_follow && seed_commits.length() > 0 {
    let reachable = collect_reachable_objects_from_commits_allow_missing(
      db, fs, seed_commits, promisor_ids,
    )
    objects.append(reachable)
  }
  objects = dedup_objects(objects)
  objects = filter_objects(objects, exclude_ids)
  if cfg.exclude_promisor_objects {
    objects = filter_objects(objects, promisor_ids)
  }
  objects
}

///|
async fn try_reuse_single_stdin_pack(
  fs : OsFs,
  git_dir : String,
  cfg : PackObjectsConfig,
  include_names : Array[String],
  exclude_names : Array[String],
) -> Bool raise Error {
  if include_names.length() != 1 || exclude_names.length() != 0 {
    return false
  }
  if cfg.stdin_packs_follow ||
    cfg.unpacked ||
    cfg.local_only ||
    cfg.honor_pack_keep ||
    cfg.incremental ||
    cfg.exclude_promisor_objects {
    return false
  }
  let pack_dir = git_dir + "/objects/pack"
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  let name = include_names[0]
  let pack_path = match resolve_pack_path(fs, pack_dir, alt_dirs, name) {
    Some(path) => path
    None => return false
  }
  let pack = fs.read_file(pack_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => return false
  }
  if cfg.stdout {
    @stdio.stdout.write(pack)
    return true
  }
  let idx_path = pack_idx_path(pack_path)
  let idx = fs.read_file(idx_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => return false
  }
  let hash_hex = pack_hash_hex(pack)
  let base_name = match cfg.base_name {
    Some(name) => name
    None => {
      @stdio.stderr.write("fatal: missing base-name\n")
      @sys.exit(1)
      ""
    }
  }
  let base_name = resolve_in_cwd(base_name)
  let pack_out = base_name + "-" + hash_hex + ".pack"
  let idx_out = base_name + "-" + hash_hex + ".idx"
  fs.write_file(pack_out, pack)
  fs.write_file(idx_out, idx)
  @stdio.stdout.write(hash_hex + "\n")
  true
}

///|
fn resolve_real_git_for_pack_objects() -> String {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) if path.length() > 0 => path
    _ =>
      match @sys.get_env_var("GIT_SHIM_REAL_GIT") {
        Some(path) if path.length() > 0 => path
        _ => "git"
      }
  }
}

///|
async fn delegate_pack_objects_to_real_git(
  args : Array[String],
) -> Unit raise Error {
  let real_git = resolve_real_git_for_pack_objects()
  let delegated_args = ["pack-objects"]
  delegated_args.append(args)
  let code = @process.run(
    real_git,
    delegated_args,
    inherit_env=true,
    cwd=get_work_root(),
  ) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => 1
  }
  @sys.exit(code)
}

///|
async fn handle_pack_objects(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg == "-h" || arg == "--help" || arg == "--help-all" {
      @stdio.stdout.write("usage: git pack-objects [<options>] <base-name>\n")
      @sys.exit(129)
    }
  }
  match parse_pack_objects_args(args) {
    PackObjectsParse::Unsupported => {
      // Keep git/t compatibility for advanced options we do not implement.
      delegate_pack_objects_to_real_git(args)
    }
    PackObjectsParse::Error(msg) => {
      @stdio.stderr.write(msg + "\n")
      @sys.exit(1)
    }
    PackObjectsParse::Ok(cfg) => {
      let fs = OsFs::new()
      let git_dir = find_git_dir(fs)
      match @sys.get_env_var("GIT_TEST_NAME_HASH_VERSION") {
        Some(_) => ()
        None => ()
      }
      if cfg.object_format is Some(format) && format == "sha256" {
        @stdio.stderr.write("bit: SHA256 object format is not supported\n")
        @sys.exit(1)
      }
      if is_sha256_repo_from_env() {
        @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
        @sys.exit(1)
      }
      if cfg.has_unsupported_options {
        // Keep git/t compatibility for advanced options we do not implement.
        delegate_pack_objects_to_real_git(args)
      }
      if !cfg.stdout && !cfg.stdin_packs && !cfg.revs && !cfg.all {
        // File-output stdin-object mode requires strict pack/index compatibility.
        delegate_pack_objects_to_real_git(args)
      }
      let trace2_event = @sys.get_env_var("GIT_TRACE2_EVENT")
      ignore(trace2_event)
      ignore(is_pack_reuse_config_enabled(git_dir))
      // Keep these flags visible for future compatibility tuning.
      let non_default_delta_params = cfg.window == 0 || cfg.depth != 50
      let stdin_object_mode_without_revs = cfg.stdout &&
        !cfg.revs &&
        !cfg.all &&
        !cfg.stdin_packs
      ignore(non_default_delta_params)
      ignore(stdin_object_mode_without_revs)
      let pack_dir = git_dir + "/objects/pack"
      if cfg.name_hash_version is Some(version) &&
        cfg.write_bitmap &&
        version == 2 &&
        !cfg.stdout {
        @stdio.stderr.write(
          "warning: currently, --write-bitmap-index requires --name-hash-version=1\n",
        )
      }
      if !fs.is_dir(git_dir) && !(cfg.all || cfg.revs) {
        @stdio.stderr.write("fatal: not a git repository\n")
        @sys.exit(1)
      }
      // Read pack.packSizeLimit from config
      let pack_size_limit = get_pack_size_limit(git_dir)
      let pack_compression_level = get_pack_compression_level(git_dir)
      let pack_compression = match pack_compression_level {
        Some(level) if level == 0 => @git.PackCompression::Stored
        _ => @git.PackCompression::Default
      }
      let db = @gitlib.ObjectDb::load(fs, git_dir)
      if cfg.window == 0 {
        db.set_prefer_packed(true)
      }
      let lookup_dbs = load_object_lookup_dbs(fs, git_dir, db)
      let mut objects : Array[@git.PackObject] = []
      if cfg.stdin_packs {
        let input = read_all_stdin()
        let (include_names, exclude_names) = parse_stdin_pack_lines(input)
        if try_reuse_single_stdin_pack(
            fs, git_dir, cfg, include_names, exclude_names,
          ) {
          return ()
        }
        objects = collect_objects_from_stdin_packs(
          fs, git_dir, db, cfg, include_names, exclude_names,
        )
      } else if cfg.all {
        let refs = @gitrepo.show_ref(fs, git_dir) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => []
        }
        let blocked : Map[String, Bool] = {}
        let seen : Map[String, Bool] = {}
        let out : Array[@git.PackObject] = []
        for pair in refs {
          let (_name, id) = pair
          collect_objects_from_ref_allow_missing(db, fs, id, blocked, seen, out)
        }
        objects = out
      } else if cfg.revs {
        let input = read_all_stdin()
        let lines = split_lines_bytes(input)
        let include_commits : Array[@git.ObjectId] = []
        let exclude_commits : Array[@git.ObjectId] = []
        let explicit_tags : Array[@git.PackObject] = []
        let mut negate_mode = false
        for line in lines {
          let trimmed = trim_line_bytes(line)
          // Empty line signals end of input in --revs mode (like git rev-list --stdin)
          if trimmed.length() == 0 {
            break
          }
          let text = line_to_string(trimmed)
          if text == "--not" {
            negate_mode = !negate_mode
            continue
          }
          if text == "--" {
            continue
          }
          let (negated, spec) = if text.has_prefix("^") {
            (true, (try! text[1:]).to_string())
          } else {
            (negate_mode, text)
          }
          let mut handled = false
          if !negated {
            match spec.find("..") {
              Some(pos) => {
                let left = (try! spec[:pos]).to_string()
                let right = (try! spec[pos + 2:]).to_string()
                if right.length() > 0 {
                  match @gitrepo.rev_parse(fs, git_dir, right) {
                    None => {
                      @stdio.stderr.write(
                        "fatal: bad revision '" + right + "'\n",
                      )
                      @sys.exit(1)
                    }
                    Some(id) => {
                      let (tags, peeled) = resolve_tag_chain(db, fs, id)
                      for tag in tags {
                        explicit_tags.push(tag)
                      }
                      match peeled {
                        Some(target) => include_commits.push(target)
                        None => include_commits.push(id)
                      }
                    }
                  }
                }
                if left.length() > 0 {
                  match @gitrepo.rev_parse(fs, git_dir, left) {
                    None => {
                      @stdio.stderr.write(
                        "fatal: bad revision '" + left + "'\n",
                      )
                      @sys.exit(1)
                    }
                    Some(id) => {
                      let (_tags, peeled) = resolve_tag_chain(db, fs, id)
                      match peeled {
                        Some(target) => exclude_commits.push(target)
                        None => exclude_commits.push(id)
                      }
                    }
                  }
                }
                handled = true
              }
              None => ()
            }
          }
          if !handled {
            match @gitrepo.rev_parse(fs, git_dir, spec) {
              None => {
                @stdio.stderr.write("fatal: bad revision '" + spec + "'\n")
                @sys.exit(1)
              }
              Some(id) => {
                let (tags, peeled) = resolve_tag_chain(db, fs, id)
                let resolved = match peeled {
                  Some(target) => target
                  None => id
                }
                if negated {
                  exclude_commits.push(resolved)
                } else {
                  for tag in tags {
                    explicit_tags.push(tag)
                  }
                  include_commits.push(resolved)
                }
              }
            }
          }
        }
        let env_sparse = match @sys.get_env_var("GIT_TEST_PACK_SPARSE") {
          Some(value) => parse_bool_value(value)
          None => None
        }
        let cfg_sparse = get_pack_use_sparse(git_dir)
        let default_sparse = cfg_sparse
        let use_sparse = match cfg.sparse_mode {
          Some(value) => value
          None =>
            match env_sparse {
              Some(value) => value
              None => default_sparse
            }
        }
        if use_sparse {
          objects = collect_sparse_objects_from_commits(
            db, fs, include_commits, exclude_commits,
          )
        } else {
          let allow_missing = match cfg.missing_mode {
            MissingMode::AllowAny => true
            _ => false
          }
          let allow_missing_for_local = allow_missing ||
            cfg.local_only ||
            cfg.honor_pack_keep ||
            cfg.incremental ||
            cfg.unpacked
          let include_objects = if allow_missing_for_local {
            let blocked : Map[String, Bool] = {}
            collect_reachable_objects_from_commits_allow_missing(
              db, fs, include_commits, blocked,
            )
          } else {
            @gitlib.collect_reachable_objects_from_commits(
              db, fs, include_commits,
            ) catch {
              err if @async.is_cancellation_error(err) => raise err
              err => {
                report_collect_error(err)
                []
              }
            }
          }
          if exclude_commits.length() == 0 {
            objects = include_objects
          } else {
            let blocked : Map[String, Bool] = {}
            let exclude_objects = collect_reachable_objects_from_commits_allow_missing(
              db, fs, exclude_commits, blocked,
            )
            let exclude_set : Map[String, Bool] = {}
            for obj in exclude_objects {
              let id = @git.hash_object_content(obj.obj_type, obj.data)
              exclude_set[id.to_hex()] = true
            }
            let filtered : Array[@git.PackObject] = []
            for obj in include_objects {
              let id = @git.hash_object_content(obj.obj_type, obj.data)
              if !exclude_set.contains(id.to_hex()) {
                filtered.push(obj)
              }
            }
            objects = filtered
          }
        }
        if explicit_tags.length() > 0 {
          objects.append(explicit_tags)
        }
      } else {
        let input = read_all_stdin()
        if input.length() > 0 {
          let lines = split_lines_bytes(input)
          let mut has_sha256 = false
          for line in lines {
            if looks_like_sha256_line(line) {
              has_sha256 = true
              break
            }
          }
          if has_sha256 {
            @stdio.stderr.write("bit: SHA256 object format is not supported\n")
            @sys.exit(1)
          }
          let ends_with_newline = input.length() > 0 &&
            input[input.length() - 1] == b'\n'
          for i in 0..<lines.length() {
            let line = lines[i]
            let trimmed = trim_line_bytes(line)
            if trimmed.length() == 0 {
              if !(ends_with_newline && i == lines.length() - 1) {
                @stdio.stderr.write(invalid_object_line_message(""))
                @sys.exit(1)
              }
              continue
            }
            match parse_object_id_bytes(line) {
              None => {
                @stdio.stderr.write(
                  line |> line_to_string |> invalid_object_line_message,
                )
                @sys.exit(1)
              }
              Some(id) =>
                match find_object_in_lookup_dbs(lookup_dbs, fs, id) {
                  None =>
                    if (match cfg.missing_mode {
                        MissingMode::AllowAny => true
                        _ => false
                      }) {
                      ()
                    } else {
                      @stdio.stderr.write(
                        "fatal: bad object " + id.to_hex() + "\n",
                      )
                      @sys.exit(1)
                    }
                  Some(obj) => objects.push(obj)
                }
            }
          }
        }
      }
      if cfg.path_walk {
        @stdio.stderr.write("Compressing objects by path\n")
      }
      // Apply filter specification (e.g., blob:none for partial clone)
      let mut objects = apply_pack_filter_spec(objects, cfg.filter)
      if cfg.local_only {
        let alt_dirs = read_alternate_object_dirs(fs, git_dir)
        let non_local_ids : Map[String, Bool] = {}
        for alt_dir in alt_dirs {
          let alt_pack_dir = alt_dir + "/pack"
          let alt_pack_ids = collect_pack_ids_from_dir(fs, alt_pack_dir)
          for item in alt_pack_ids {
            let (hex, _v) = item
            non_local_ids[hex] = true
          }
          let alt_loose_ids = collect_loose_object_ids(fs, alt_dir)
          for item in alt_loose_ids {
            let (hex, _v) = item
            non_local_ids[hex] = true
          }
        }
        objects = filter_objects(objects, non_local_ids)
      }
      if cfg.honor_pack_keep {
        let keep_ids = collect_pack_ids_from_marker(fs, pack_dir, ".keep")
        objects = filter_objects(objects, keep_ids)
      }
      if (cfg.incremental || cfg.unpacked) && !cfg.stdin_packs {
        let packed_ids = collect_pack_ids_from_dir(fs, pack_dir)
        objects = filter_objects(objects, packed_ids)
      }
      if cfg.exclude_promisor_objects {
        let promisor_ids = collect_pack_ids_from_marker(
          fs, pack_dir, ".promisor",
        )
        objects = filter_objects(objects, promisor_ids)
      }
      if cfg.include_tag {
        let tags = collect_include_tag_objects(fs, git_dir, db, objects)
        if tags.length() > 0 {
          objects.append(tags)
        }
      }
      objects = dedup_objects(objects)
      if cfg.progress {
        let enumerated = objects.length()
        let pack_reused = count_pack_reused_objects(
          fs, git_dir, pack_dir, objects,
        )
        @stdio.stderr.write(
          "Enumerating objects: " + enumerated.to_string() + ", done\n",
        )
        @stdio.stderr.write("pack-reused " + pack_reused.to_string() + "\n")
      }
      let reuse_only = cfg.window == 0
      // Split objects into groups based on packSizeLimit (only for file output, not stdout)
      let effective_limit = if cfg.stdout { None } else { pack_size_limit }
      let object_groups = split_objects_by_size_limit(objects, effective_limit)
      let mut total_delta_count = 0
      for group in object_groups {
        let (pack, delta_count) = @pack.create_packfile_with_delta_stats_compression_reuse(
          group,
          cfg.delta_mode,
          pack_compression,
          reuse_only,
          cfg.depth,
        )
        total_delta_count += delta_count
        if cfg.stdout {
          @stdio.stdout.write(pack)
        } else {
          let hash_hex = pack_hash_hex(pack)
          let base_name = match cfg.base_name {
            Some(name) => name
            None => {
              @stdio.stderr.write("fatal: missing base-name\n")
              @sys.exit(1)
              ""
            }
          }
          let base_name = resolve_in_cwd(base_name)
          let pack_path = base_name + "-" + hash_hex + ".pack"
          let idx_path = base_name + "-" + hash_hex + ".idx"
          fs.write_file(pack_path, pack)
          @pack.write_pack_index_from_objects_versioned(
            fs,
            idx_path,
            pack,
            group,
            cfg.index_version,
          )
          if db.saw_corrupt_pack {
            corrupt_pack_file(fs, pack_path)
          }
          @stdio.stdout.write(hash_hex + "\n")
        }
      }
      if cfg.progress {
        @stdio.stderr.write(
          "Total " +
          objects.length().to_string() +
          " (delta " +
          total_delta_count.to_string() +
          ")\n",
        )
      }
      if cfg.stdout {
        @sys.exit(0)
      }
    }
  }
}

///|
/// Split objects into groups based on pack size limit
fn split_objects_by_size_limit(
  objects : Array[@git.PackObject],
  limit : Int64?,
) -> Array[Array[@git.PackObject]] {
  match limit {
    None => [objects]
    Some(max_size) => {
      if max_size <= 0L {
        return [objects]
      }
      // Git enforces a minimum pack size limit of 1 MiB
      let min_pack_size = 1048576L // 1 MiB
      let effective_max = if max_size < min_pack_size {
        min_pack_size
      } else {
        max_size
      }
      let groups : Array[Array[@git.PackObject]] = []
      let mut current_group : Array[@git.PackObject] = []
      let mut current_size = 0L
      // Pack header is 12 bytes, trailer is 20 bytes
      let pack_overhead = 32L
      for obj in objects {
        // Use raw size as conservative estimate (zlib typically achieves 50-70% compression
        // but for random data like binary files, compression is minimal)
        let obj_size = obj.data.length().to_int64()
        // Add overhead for type/size encoding (variable, estimate ~5 bytes per object)
        let estimated_size = obj_size + 5L
        // If this object would exceed the limit, start a new group
        // But always include at least one object per group
        if current_group.length() > 0 &&
          current_size + estimated_size + pack_overhead > effective_max {
          groups.push(current_group)
          current_group = []
          current_size = 0L
        }
        current_group.push(obj)
        current_size += estimated_size
      }
      if current_group.length() > 0 {
        groups.push(current_group)
      }
      if groups.length() == 0 {
        groups.push([])
      }
      groups
    }
  }
}
