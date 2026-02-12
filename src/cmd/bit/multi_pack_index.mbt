///|
async fn handle_multi_pack_index(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let pack_dir = git_dir + "/objects/pack"
  let mut subcommand : String? = None
  for arg in args {
    match arg {
      "write" | "verify" | "expire" | "repack" => {
        subcommand = Some(arg)
        break
      }
      _ => ()
    }
  }
  let mut object_dir : String? = None
  let mut progress = false
  let mut preferred_pack : String? = None
  let mut stdin_packs = false
  let mut bitmap = false
  let mut batch_size = 0
  let mut unsupported_opt : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--object-dir" if i + 1 < args.length() => {
        object_dir = Some(resolve_in_cwd(args[i + 1]))
        i += 2
        continue
      }
      _ if arg.has_prefix("--object-dir=") =>
        object_dir = Some(resolve_in_cwd(arg[13:].to_string()))
      "--progress" => progress = true
      "--no-progress" => progress = false
      "--batch-size" if i + 1 < args.length() => {
        batch_size = @strconv.parse_int(args[i + 1]) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => 0
        }
        i += 2
        continue
      }
      _ if arg.has_prefix("--batch-size=") =>
        batch_size = @strconv.parse_int(arg[13:].to_string()) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => 0
        }
      "--preferred-pack" if i + 1 < args.length() => {
        preferred_pack = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--preferred-pack=") =>
        preferred_pack = Some(arg[17:].to_string())
      "--stdin-packs" => stdin_packs = true
      "--bitmap" => bitmap = true
      "--incremental" => unsupported_opt = Some(arg)
      _ if arg.has_prefix("--refs-snapshot") => unsupported_opt = Some(arg)
      "write" | "verify" | "expire" | "repack" => subcommand = Some(arg)
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("multi-pack-index", arg)
        unsupported_opt = Some(arg)
      }
      _ => ()
    }
    i += 1
  }
  match unsupported_opt {
    Some(opt) => {
      eprint_line("error: unsupported option for multi-pack-index: " + opt)
      @sys.exit(1)
    }
    None => ()
  }
  match subcommand {
    Some("write") | Some("verify") =>
      if object_dir is None && not(fs.is_dir(git_dir)) {
        eprint_line(
          "fatal: not a git repository (or any of the parent directories): .git",
        )
        @sys.exit(128)
      }
    _ => ()
  }
  let effective_pack_dir = match object_dir {
    Some(dir) => dir + "/pack"
    None => pack_dir
  }
  match subcommand {
    Some("write") =>
      midx_write(
        fs, effective_pack_dir, progress, preferred_pack, stdin_packs, bitmap,
      )
    Some("verify") => midx_verify(fs, effective_pack_dir, progress)
    Some("expire") => midx_expire(fs, effective_pack_dir, progress)
    Some("repack") => midx_repack(fs, effective_pack_dir, batch_size, progress)
    _ => {
      eprint_line("usage: git multi-pack-index [<options>] <subcommand>")
      eprint_line("")
      eprint_line("Subcommands:")
      eprint_line("    write    Write a multi-pack-index file")
      eprint_line("    verify   Verify multi-pack-index file")
      eprint_line("    expire   Delete unreferenced pack-files")
      eprint_line("    repack   Consolidate pack-files")
      @sys.exit(129)
    }
  }
  ignore(batch_size)
}

///|
async fn midx_write(
  fs : OsFs,
  pack_dir : String,
  progress : Bool,
  preferred_pack : String?,
  stdin_packs : Bool,
  bitmap : Bool,
) -> Unit raise Error {
  let all_pack_files = midx_find_pack_files(fs, pack_dir)
  let pack_files = if stdin_packs {
    let input = read_all_stdin()
    let (include_names, exclude_names) = parse_stdin_pack_lines(input)
    midx_select_pack_files_from_stdin(
      all_pack_files, include_names, exclude_names,
    )
  } else {
    all_pack_files
  }
  let midx_path = pack_dir + "/multi-pack-index"
  let has_existing_midx = fs.is_file(midx_path)
  let normalized_preferred = match preferred_pack {
    Some(name) => {
      let mut value = name
      if value.has_suffix(".idx") {
        let end = value.length() - 4
        value = String::unsafe_substring(value, start=0, end~) + ".pack"
      }
      match value.rev_find("/") {
        Some(idx) =>
          String::unsafe_substring(value, start=idx + 1, end=value.length())
        None => value
      }
    }
    None => ""
  }
  if pack_files.length() == 0 {
    if normalized_preferred.length() > 0 {
      eprint_line(
        "warning: unknown preferred pack: '" + normalized_preferred + "'",
      )
    }
    if has_existing_midx {
      eprint_line("could not load pack")
    } else {
      eprint_line("error: no pack files to index.")
    }
    @sys.exit(1)
    return
  }
  for pack_name in pack_files {
    let idx_path = pack_dir +
      "/" +
      String::unsafe_substring(pack_name, start=0, end=pack_name.length() - 5) +
      ".idx"
    let pack_path = pack_dir + "/" + pack_name
    if not(fs.is_file(idx_path)) || not(fs.is_file(pack_path)) {
      eprint_line("could not load pack")
      @sys.exit(1)
      return
    }
  }
  let has_alternates = midx_has_alternates(fs, pack_dir)
  let non_sha1_repo = midx_repo_is_non_sha1(pack_dir)
  let prefer_requested = preferred_pack is Some(_)
  ignore(has_existing_midx)
  ignore(has_alternates)
  ignore(non_sha1_repo)
  ignore(prefer_requested)
  let mut preferred_pack_idx : Int? = None
  // Collect all objects from all packs
  let all_entries : Array[MidxEntry] = []
  for pack_idx, pack_name in pack_files {
    let idx_path = pack_dir +
      "/" +
      String::unsafe_substring(pack_name, start=0, end=pack_name.length() - 5) +
      ".idx"
    let pack_path = pack_dir + "/" + pack_name
    if not(fs.is_file(idx_path)) || not(fs.is_file(pack_path)) {
      eprint_line("could not load pack")
      @sys.exit(1)
      return
    }
    if normalized_preferred.length() > 0 && pack_name == normalized_preferred {
      preferred_pack_idx = Some(pack_idx)
    }
    let entries = midx_read_pack_index(fs, idx_path, pack_idx)
    let mut has_large_offsets = false
    for entry in entries {
      if entry.offset_hi != 0 {
        has_large_offsets = true
        break
      }
    }
    if has_large_offsets {
      eprint_line("error: unsupported 64-bit pack offset")
      @sys.exit(1)
      return
    }
    if normalized_preferred.length() > 0 &&
      pack_name == normalized_preferred &&
      entries.length() == 0 {
      eprint_line("preferred pack " + pack_name + " with no objects")
      @sys.exit(1)
    }
    for entry in entries {
      all_entries.push(entry)
    }
  }
  if normalized_preferred.length() > 0 && preferred_pack_idx is None {
    eprint_line(
      "warning: unknown preferred pack: '" + normalized_preferred + "'",
    )
  }
  // Sort entries by object ID
  all_entries.sort_by(fn(a, b) {
    let cmp = midx_compare_oid(a.id, b.id)
    if cmp != 0 {
      return cmp
    }
    match preferred_pack_idx {
      Some(pref_idx) =>
        if a.pack_idx == pref_idx && b.pack_idx != pref_idx {
          -1
        } else if a.pack_idx != pref_idx && b.pack_idx == pref_idx {
          1
        } else {
          0
        }
      None => 0
    }
  })
  // Remove duplicates (keep first occurrence = preferred pack)
  let unique_entries : Array[MidxEntry] = []
  let mut last_id : @git.ObjectId? = None
  for entry in all_entries {
    match last_id {
      Some(lid) if lid == entry.id => continue
      _ => {
        unique_entries.push(entry)
        last_id = Some(entry.id)
      }
    }
  }
  if unique_entries.length() == 0 {
    eprint_line("error: no pack files to index.")
    @sys.exit(1)
    return
  }
  // Build MIDX file
  let midx_bytes = midx_build(pack_files, unique_entries, bitmap)
  if has_existing_midx {
    match midx_try_read_file(fs, midx_path) {
      Some(existing) => {
        if not(midx_has_valid_checksum(existing)) {
          eprint_line("error: checksum.mismatch in existing multi-pack-index")
        }
        if midx_bytes_equal(existing, midx_bytes) {
          midx_cleanup_rev_files(fs, pack_dir)
          if progress {
            eprint_line(
              "Wrote multi-pack-index with " +
              unique_entries.length().to_string() +
              " objects from " +
              pack_files.length().to_string() +
              " packs",
            )
          }
          return
        }
      }
      None => ()
    }
  }
  fs.write_file(midx_path, midx_bytes)
  midx_cleanup_rev_files(fs, pack_dir)
  if progress {
    eprint_line(
      "Wrote multi-pack-index with " +
      unique_entries.length().to_string() +
      " objects from " +
      pack_files.length().to_string() +
      " packs",
    )
  }
}

///|
fn midx_has_alternates(fs : OsFs, pack_dir : String) -> Bool {
  let objects_dir = parent_dir(pack_dir)
  let alternates_path = objects_dir + "/info/alternates"
  if not(fs.is_file(alternates_path)) {
    return false
  }
  let content = fs.read_file(alternates_path) catch { _ => return false }
  for line in decode_bytes(content).split("\n") {
    if line.trim().length() > 0 {
      return true
    }
  }
  false
}

///|
fn midx_repo_is_non_sha1(pack_dir : String) -> Bool {
  let objects_dir = parent_dir(pack_dir)
  let git_dir = parent_dir(objects_dir)
  match git_config_get(git_dir, "extensions", "objectformat") {
    Some(fmt) => {
      let f = fmt.trim().to_lower()
      f.length() > 0 && f != "sha1"
    }
    None => false
  }
}

///|
async fn midx_verify(
  fs : OsFs,
  pack_dir : String,
  progress : Bool,
) -> Unit raise Error {
  let midx_path = pack_dir + "/multi-pack-index"
  if not(fs.is_file(midx_path)) {
    eprint_line("error: could not open multi-pack-index")
    @sys.exit(1)
    return
  }
  let data = fs.read_file(midx_path)
  if progress {
    eprint_line("Verifying OID order in multi-pack-index")
  }
  if data.length() < 32 {
    eprint_line("error: multi-pack-index too short")
    @sys.exit(1)
    return
  }
  if not(
      data[0] == b'M' && data[1] == b'I' && data[2] == b'D' && data[3] == b'X',
    ) {
    eprint_line("error: multi-pack-index signature is invalid")
    @sys.exit(1)
    return
  }
  let version = data[4].to_int()
  if version != 1 {
    eprint_line(
      "error: multi-pack-index version " +
      version.to_string() +
      " not recognized",
    )
    @sys.exit(1)
    return
  }
  let oid_version = data[5].to_int()
  if oid_version != 1 {
    eprint_line(
      "multi-pack-index hash version " +
      oid_version.to_string() +
      " unsupported",
    )
    @sys.exit(1)
    return
  }
  let num_chunks = data[6].to_int()
  let num_packs = midx_read_u32(data, 8)
  if num_packs < 0 {
    eprint_line("error: improper chunk offset(s)")
    @sys.exit(1)
    return
  }
  let checksum_offset = data.length() - 20
  let toc_end = 12 + (num_chunks + 1) * 12
  if toc_end > checksum_offset {
    eprint_line("error: improper chunk offset(s)")
    @sys.exit(1)
    return
  }
  let chunks : Array[MidxChunkRange] = []
  for i in 0..<num_chunks {
    let entry_offset = 12 + i * 12
    let chunk_id = midx_read_u32(data, entry_offset)
    if chunk_id == 0 {
      eprint_line("error: terminating chunk id appears earlier than expected")
      @sys.exit(1)
      return
    }
    let chunk_offset_hi = midx_read_u32(data, entry_offset + 4)
    let chunk_offset = midx_read_u32(data, entry_offset + 8)
    let next_offset_hi = midx_read_u32(data, entry_offset + 16)
    let next_offset = midx_read_u32(data, entry_offset + 20)
    if chunk_offset_hi != 0 ||
      next_offset_hi != 0 ||
      chunk_offset < 0 ||
      next_offset < 0 ||
      next_offset < chunk_offset ||
      next_offset > checksum_offset ||
      chunk_offset % 4 != 0 {
      eprint_line("error: improper chunk offset(s)")
      @sys.exit(1)
      return
    }
    let id = midx_chunk_id_string(data, entry_offset)
    for existing in chunks {
      if existing.id == id {
        eprint_line("error: duplicate chunk ID")
        @sys.exit(1)
        return
      }
    }
    chunks.push({ id, start: chunk_offset, end: next_offset })
  }
  let terminator_id = midx_read_u32(data, 12 + num_chunks * 12)
  if terminator_id != 0 {
    eprint_line("error: final chunk has non-zero id")
    @sys.exit(1)
    return
  }
  let pnam_chunk = match midx_find_chunk_range(chunks, "PNAM") {
    Some(chunk) => chunk
    None => {
      eprint_line("error: multi-pack-index required pack-name chunk missing")
      @sys.exit(1)
      return
    }
  }
  let oidf_chunk = match midx_find_chunk_range(chunks, "OIDF") {
    Some(chunk) => chunk
    None => {
      eprint_line("error: multi-pack-index required OID fanout chunk missing")
      @sys.exit(1)
      return
    }
  }
  let oidl_chunk = match midx_find_chunk_range(chunks, "OIDL") {
    Some(chunk) => chunk
    None => {
      eprint_line("error: multi-pack-index required OID lookup chunk missing")
      @sys.exit(1)
      return
    }
  }
  let ooff_chunk = match midx_find_chunk_range(chunks, "OOFF") {
    Some(chunk) => chunk
    None => {
      eprint_line(
        "error: multi-pack-index required object offsets chunk missing",
      )
      @sys.exit(1)
      return
    }
  }
  if oidf_chunk.end - oidf_chunk.start != 256 * 4 {
    eprint_line("error: multi-pack-index OID fanout is of the wrong size")
    @sys.exit(1)
    return
  }
  let mut object_count = 0
  let mut prev_fanout = 0
  for i in 0..<256 {
    let value = midx_read_u32(data, oidf_chunk.start + i * 4)
    if i > 0 && midx_u32_gt(prev_fanout, value) {
      eprint_line("error: oid fanout out of order")
      @sys.exit(1)
      return
    }
    prev_fanout = value
    object_count = value
  }
  if object_count <= 0 {
    eprint_line("error: the midx contains no oid")
    @sys.exit(1)
    return
  }
  if oidl_chunk.end - oidl_chunk.start != object_count * 20 {
    eprint_line("error: multi-pack-index OID lookup chunk is the wrong size")
    @sys.exit(1)
    return
  }
  if ooff_chunk.end - ooff_chunk.start != object_count * 8 {
    eprint_line("error: multi-pack-index object offset chunk is the wrong size")
    @sys.exit(1)
    return
  }
  let pack_names : Array[String] = []
  let mut pos = pnam_chunk.start
  let mut prev_pack = ""
  for i in 0..<num_packs {
    let mut end = pos
    while end < pnam_chunk.end && data[end] != b'\x00' {
      end += 1
    }
    if end >= pnam_chunk.end {
      eprint_line("error: multi-pack-index pack-name chunk is too short")
      @sys.exit(1)
      return
    }
    let name = midx_bytes_to_string(data, pos, end)
    if i > 0 && midx_compare_string_lex(prev_pack, name) >= 0 {
      eprint_line(
        "error: multi-pack-index pack names out of order: '" +
        prev_pack +
        "' before '" +
        name +
        "'",
      )
      @sys.exit(1)
      return
    }
    pack_names.push(name)
    prev_pack = name
    pos = end + 1
  }
  let mut has_error = false
  let content = Bytes::from_array(
    FixedArray::makei(checksum_offset, i => data[i]),
  )
  let computed = @git.sha1(content)
  let stored = @git.ObjectId::new(
    FixedArray::makei(20, i => data[checksum_offset + i]),
  )
  if computed != stored {
    eprint_line("error: incorrect checksum")
    has_error = true
  }
  let pack_entries : Array[Array[MidxEntry]] = []
  for i, idx_name in pack_names {
    let idx_path = pack_dir + "/" + idx_name
    let pack_name = if idx_name.has_suffix(".idx") {
      String::unsafe_substring(idx_name, start=0, end=idx_name.length() - 4) +
      ".pack"
    } else {
      idx_name
    }
    let pack_path = pack_dir + "/" + pack_name
    if not(fs.is_file(idx_path)) || not(fs.is_file(pack_path)) {
      eprint_line("error: failed to load pack in position " + i.to_string())
      has_error = true
      pack_entries.push([])
      continue
    }
    let entries = midx_read_pack_index(fs, idx_path, i)
    if entries.length() == 0 {
      eprint_line("error: failed to load pack in position " + i.to_string())
      has_error = true
    }
    pack_entries.push(entries)
  }
  let object_ids : Array[@git.ObjectId] = []
  let mut prev_oid : @git.ObjectId? = None
  for i in 0..<object_count {
    let oid = @git.ObjectId::new(
      FixedArray::makei(20, j => data[oidl_chunk.start + i * 20 + j]),
    )
    match prev_oid {
      Some(prev) =>
        if midx_compare_oid(prev, oid) >= 0 {
          eprint_line(
            "error: oid lookup out of order: oid[" +
            (i - 1).to_string() +
            "] = " +
            prev.to_hex() +
            " >= " +
            oid.to_hex() +
            " = oid[" +
            i.to_string() +
            "]",
          )
          has_error = true
        }
      None => ()
    }
    object_ids.push(oid)
    prev_oid = Some(oid)
  }
  let loff_chunk = midx_find_chunk_range(chunks, "LOFF")
  if progress {
    eprint_line("Verifying object offsets")
  }
  for i in 0..<object_count {
    let entry_offset = ooff_chunk.start + i * 8
    let pack_int_id = midx_read_u32(data, entry_offset)
    if pack_int_id < 0 || pack_int_id >= num_packs {
      eprint_line(
        "error: bad pack-int-id: " +
        pack_int_id.to_string() +
        " (" +
        num_packs.to_string() +
        " total packs)",
      )
      has_error = true
      continue
    }
    let raw_offset = midx_read_u32(data, entry_offset + 4)
    let mut object_offset_hi = 0
    let mut object_offset = raw_offset
    if raw_offset < 0 {
      let large_idx = raw_offset & 2147483647
      match loff_chunk {
        Some(chunk) => {
          let loff_pos = chunk.start + large_idx * 8
          if loff_pos + 8 > chunk.end {
            eprint_line(
              "error: incorrect object offset for oid[" +
              i.to_string() +
              "] = " +
              object_ids[i].to_hex(),
            )
            has_error = true
            continue
          }
          let high = midx_read_u32(data, loff_pos)
          object_offset_hi = high
          object_offset = midx_read_u32(data, loff_pos + 4)
        }
        None => {
          eprint_line(
            "error: incorrect object offset for oid[" +
            i.to_string() +
            "] = " +
            object_ids[i].to_hex(),
          )
          has_error = true
          continue
        }
      }
    }
    let entries = pack_entries[pack_int_id]
    let oid = object_ids[i]
    let mut found = false
    for entry in entries {
      if entry.id == oid {
        found = true
        if entry.offset_hi != object_offset_hi || entry.offset != object_offset {
          eprint_line(
            "error: incorrect object offset for oid[" +
            i.to_string() +
            "] = " +
            oid.to_hex(),
          )
          has_error = true
        }
        break
      }
    }
    if not(found) {
      eprint_line(
        "error: failed to load pack entry for oid[" +
        i.to_string() +
        "] = " +
        oid.to_hex(),
      )
      has_error = true
    }
  }
  if has_error {
    @sys.exit(1)
    return
  }
  print_line("multi-pack-index verified")
}

///|
async fn midx_expire(
  fs : OsFs,
  pack_dir : String,
  progress : Bool,
) -> Unit raise Error {
  let midx_path = pack_dir + "/multi-pack-index"
  if not(fs.is_file(midx_path)) {
    if progress {
      eprint_line("No multi-pack-index to expire")
    }
    return
  }
  // Read MIDX to get referenced packs
  let data = fs.read_file(midx_path)
  if data.length() < 12 {
    return
  }
  let num_packs = midx_read_u32(data, 8)
  let num_chunks = data[6].to_int()
  // Find PNAM chunk to get pack names
  let pnam_offset = midx_find_chunk(data, num_chunks, "PNAM")
  let pnam_end = midx_find_chunk_end(data, num_chunks, "PNAM")
  if pnam_offset == 0 {
    return
  }
  // Parse pack names
  let referenced_packs : Array[String] = []
  let mut start = pnam_offset
  for _ in 0..<num_packs {
    let mut end = start
    while end < pnam_end && data[end] != b'\x00' {
      end += 1
    }
    let name = midx_bytes_to_string(data, start, end)
    referenced_packs.push(name)
    start = end + 1
  }
  // Find all pack files
  let all_packs = midx_find_pack_files(fs, pack_dir)
  let mut expired = 0
  for pack_name in all_packs {
    let mut found = false
    for ref_name in referenced_packs {
      if pack_name == ref_name {
        found = true
        break
      }
    }
    if not(found) {
      // Check for .keep file
      let keep_path = pack_dir +
        "/" +
        String::unsafe_substring(pack_name, start=0, end=pack_name.length() - 5) +
        ".keep"
      if fs.is_file(keep_path) {
        continue
      }
      // Delete pack and idx
      let pack_path = pack_dir + "/" + pack_name
      let idx_path = pack_dir +
        "/" +
        String::unsafe_substring(pack_name, start=0, end=pack_name.length() - 5) +
        ".idx"
      fs.remove_file(pack_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      fs.remove_file(idx_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      expired += 1
    }
  }
  if progress {
    eprint_line("Expired " + expired.to_string() + " pack(s)")
  }
  // Rewrite MIDX without expired packs
  if expired > 0 {
    midx_write(fs, pack_dir, false, None, false, false)
  }
}

///|
async fn midx_repack(
  fs : OsFs,
  pack_dir : String,
  batch_size : Int,
  progress : Bool,
) -> Unit raise Error {
  // Find small packs to consolidate
  let pack_files = midx_find_pack_files(fs, pack_dir)
  if pack_files.length() < 2 {
    if progress {
      eprint_line("Not enough packs to repack")
    }
    return
  }
  // For simplicity, just suggest running git repack
  if progress {
    eprint_line(
      "Found " + pack_files.length().to_string() + " pack files to consolidate",
    )
    eprint_line("Use 'git repack' for full repacking functionality")
  }
  ignore(batch_size)
}

///|
/// MIDX entry for building
priv struct MidxEntry {
  id : @git.ObjectId
  pack_idx : Int
  offset_hi : Int
  offset : Int
}

///|
priv struct MidxChunkRange {
  id : String
  start : Int
  end : Int
}

///|
fn midx_find_pack_files(fs : OsFs, pack_dir : String) -> Array[String] {
  let files : Array[String] = []
  let entries = fs.readdir(pack_dir) catch { _ => return files }
  for entry in entries {
    if entry.has_suffix(".pack") && not(entry.has_prefix(".")) {
      files.push(entry)
    }
  }
  midx_sort_strings_lex_in_place(files)
  files
}

///|
fn midx_try_read_file(fs : OsFs, path : String) -> Bytes? {
  let data = fs.read_file(path) catch { _ => return None }
  Some(data)
}

///|
fn midx_bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
fn midx_normalize_stdin_pack_name(name : String) -> String? {
  let trimmed = name.trim().to_string()
  if trimmed.length() == 0 {
    return None
  }
  let base = match trimmed.rev_find("/") {
    Some(idx) =>
      String::unsafe_substring(trimmed, start=idx + 1, end=trimmed.length())
    None => trimmed
  }
  if base.has_suffix(".idx") {
    return Some(
      String::unsafe_substring(base, start=0, end=base.length() - 4) + ".pack",
    )
  }
  if base.has_suffix(".pack") {
    return Some(base)
  }
  if base.has_prefix("pack-") {
    return Some(base + ".pack")
  }
  None
}

///|
fn midx_array_has_string(values : Array[String], target : String) -> Bool {
  for value in values {
    if value == target {
      return true
    }
  }
  false
}

///|
fn midx_select_pack_files_from_stdin(
  all_pack_files : Array[String],
  include_names : Array[String],
  exclude_names : Array[String],
) -> Array[String] {
  let selected : Array[String] = []
  for name in include_names {
    match midx_normalize_stdin_pack_name(name) {
      Some(pack_name) =>
        if midx_array_has_string(all_pack_files, pack_name) &&
          not(midx_array_has_string(selected, pack_name)) {
          selected.push(pack_name)
        }
      None => ()
    }
  }
  if exclude_names.length() == 0 {
    return selected
  }
  let excluded : Array[String] = []
  for name in exclude_names {
    match midx_normalize_stdin_pack_name(name) {
      Some(pack_name) =>
        if not(midx_array_has_string(excluded, pack_name)) {
          excluded.push(pack_name)
        }
      None => ()
    }
  }
  if excluded.length() == 0 {
    return selected
  }
  let filtered : Array[String] = []
  for name in selected {
    if not(midx_array_has_string(excluded, name)) {
      filtered.push(name)
    }
  }
  filtered
}

///|
fn midx_has_valid_checksum(data : Bytes) -> Bool {
  if data.length() < 20 {
    return false
  }
  let body_len = data.length() - 20
  let body = Bytes::from_array(FixedArray::makei(body_len, i => data[i]))
  let checksum = @git.sha1(body)
  for i in 0..<20 {
    if checksum.bytes[i] != data[body_len + i] {
      return false
    }
  }
  true
}

///|
fn midx_cleanup_rev_files(fs : OsFs, pack_dir : String) -> Unit {
  let entries = fs.readdir(pack_dir) catch { _ => return }
  for entry in entries {
    if entry.has_prefix("multi-pack-index-") && entry.has_suffix(".rev") {
      fs.remove_file(pack_dir + "/" + entry) catch {
        _ => ()
      }
    }
  }
}

///|
fn midx_read_pack_index(
  fs : OsFs,
  idx_path : String,
  pack_idx : Int,
) -> Array[MidxEntry] {
  let entries : Array[MidxEntry] = []
  let data = fs.read_file(idx_path) catch { _ => return entries }
  if data.length() < 256 * 4 {
    return entries
  }
  let is_v2 = data.length() >= 8 &&
    data[0] == b'\xff' &&
    data[1] == b't' &&
    data[2] == b'O' &&
    data[3] == b'c'
  if is_v2 {
    let version = midx_read_u32(data, 4)
    if version != 2 {
      return entries
    }
    // Read fanout table to get object count
    let fanout_offset = 8
    let object_count = midx_read_u32(data, fanout_offset + 255 * 4)
    // Object names start after fanout
    let names_offset = fanout_offset + 256 * 4
    // CRCs and 32-bit offsets table
    let crc_offset = names_offset + object_count * 20
    let offsets_offset = crc_offset + object_count * 4
    let large_offsets_offset = offsets_offset + object_count * 4
    if offsets_offset + object_count * 4 > data.length() {
      return []
    }
    for i in 0..<object_count {
      let id_offset = names_offset + i * 20
      if id_offset + 20 > data.length() {
        return []
      }
      let id = @git.ObjectId::new(
        FixedArray::makei(20, j => data[id_offset + j]),
      )
      let raw_offset = midx_read_u32(data, offsets_offset + i * 4)
      let mut offset_hi = 0
      let offset = if raw_offset < 0 {
        let large_idx = raw_offset & 2147483647
        let pos = large_offsets_offset + large_idx * 8
        if pos + 8 > data.length() {
          return []
        }
        let high = midx_read_u32(data, pos)
        let low = midx_read_u32(data, pos + 4)
        offset_hi = high
        low
      } else {
        raw_offset
      }
      entries.push({ id, pack_idx, offset_hi, offset })
    }
    return entries
  }
  // v1 index: fanout table + (offset(4) + oid(20)) * N
  let object_count = midx_read_u32(data, 255 * 4)
  let entries_offset = 256 * 4
  if entries_offset + object_count * 24 > data.length() {
    return entries
  }
  for i in 0..<object_count {
    let entry_offset = entries_offset + i * 24
    let offset = midx_read_u32(data, entry_offset)
    let id_offset = entry_offset + 4
    let id = @git.ObjectId::new(FixedArray::makei(20, j => data[id_offset + j]))
    entries.push({ id, pack_idx, offset_hi: 0, offset })
  }
  entries
}

///|
fn midx_build(
  pack_files : Array[String],
  entries : Array[MidxEntry],
  bitmap : Bool,
) -> Bytes {
  let out : Array[Byte] = []
  let num_chunks = if bitmap { 5 } else { 4 }
  // Header
  out.push(b'M')
  out.push(b'I')
  out.push(b'D')
  out.push(b'X')
  out.push(b'\x01') // version
  out.push(b'\x01') // OID version (SHA-1)
  out.push(num_chunks.to_byte()) // chunk count
  out.push(b'\x00') // number of base MIDX files
  midx_push_u32(out, pack_files.length())
  // Build chunks
  let pnam_chunk = midx_build_pnam(pack_files)
  let oidf_chunk = midx_build_oidf(entries)
  let oidl_chunk = midx_build_oidl(entries)
  let ooff_chunk = midx_build_ooff(entries)
  let btmp_chunk = if bitmap {
    Some(midx_build_btmp(pack_files.length(), entries))
  } else {
    None
  }
  // Chunk lookup table ((N + 1) entries, 12 bytes each)
  let header_size = 12
  let chunk_table_size = (num_chunks + 1) * 12
  let mut offset = header_size + chunk_table_size
  // Calculate PNAM padded length (4-byte aligned)
  let pnam_padded_len = (pnam_chunk.length() + 3) / 4 * 4
  // PNAM entry
  out.push(b'P')
  out.push(b'N')
  out.push(b'A')
  out.push(b'M')
  midx_push_u64(out, offset)
  offset += pnam_padded_len
  // OIDF entry
  out.push(b'O')
  out.push(b'I')
  out.push(b'D')
  out.push(b'F')
  midx_push_u64(out, offset)
  offset += oidf_chunk.length()
  // OIDL entry
  out.push(b'O')
  out.push(b'I')
  out.push(b'D')
  out.push(b'L')
  midx_push_u64(out, offset)
  offset += oidl_chunk.length()
  // OOFF entry
  out.push(b'O')
  out.push(b'O')
  out.push(b'F')
  out.push(b'F')
  midx_push_u64(out, offset)
  offset += ooff_chunk.length()
  match btmp_chunk {
    Some(chunk) => {
      out.push(b'B')
      out.push(b'T')
      out.push(b'M')
      out.push(b'P')
      midx_push_u64(out, offset)
      offset += chunk.length()
    }
    None => ()
  }
  // Terminator
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  midx_push_u64(out, offset)
  // Write chunk data with 4-byte alignment
  for b in pnam_chunk {
    out.push(b)
  }
  // Pad PNAM to 4-byte alignment
  let pnam_padding = pnam_padded_len - pnam_chunk.length()
  for _ in 0..<pnam_padding {
    out.push(b'\x00')
  }
  for b in oidf_chunk {
    out.push(b)
  }
  for b in oidl_chunk {
    out.push(b)
  }
  for b in ooff_chunk {
    out.push(b)
  }
  match btmp_chunk {
    Some(chunk) =>
      for b in chunk {
        out.push(b)
      }
    None => ()
  }
  // Checksum
  let content = Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
  let checksum = @git.sha1(content)
  for b in checksum.bytes {
    out.push(b)
  }
  Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
}

///|
fn midx_build_pnam(pack_files : Array[String]) -> Array[Byte] {
  let out : Array[Byte] = []
  for name in pack_files {
    // Convert .pack to .idx for PNAM chunk
    let idx_name = if name.has_suffix(".pack") {
      String::unsafe_substring(name, start=0, end=name.length() - 5) + ".idx"
    } else {
      name
    }
    for i in 0..<idx_name.length() {
      out.push(idx_name[i].to_int().to_byte())
    }
    out.push(b'\x00')
  }
  out
}

///|
fn midx_build_oidf(entries : Array[MidxEntry]) -> Array[Byte] {
  // Build fanout table
  let counts : Array[Int] = Array::make(256, 0)
  for entry in entries {
    let first = entry.id.bytes[0].to_int()
    counts[first] = counts[first] + 1
  }
  let out : Array[Byte] = []
  let mut sum = 0
  for i in 0..<256 {
    sum = sum + counts[i]
    midx_push_u32(out, sum)
  }
  out
}

///|
fn midx_build_oidl(entries : Array[MidxEntry]) -> Array[Byte] {
  let out : Array[Byte] = []
  for entry in entries {
    for b in entry.id.bytes {
      out.push(b)
    }
  }
  out
}

///|
fn midx_build_ooff(entries : Array[MidxEntry]) -> Array[Byte] {
  let out : Array[Byte] = []
  for entry in entries {
    midx_push_u32(out, entry.pack_idx)
    midx_push_u32(out, entry.offset)
  }
  out
}

///|
fn midx_build_btmp(pack_count : Int, entries : Array[MidxEntry]) -> Array[Byte] {
  let counts : Array[Int] = Array::make(pack_count, 0)
  for entry in entries {
    if entry.pack_idx >= 0 && entry.pack_idx < pack_count {
      counts[entry.pack_idx] = counts[entry.pack_idx] + 1
    }
  }
  let out : Array[Byte] = []
  let mut bitmap_pos = 0
  for i in 0..<pack_count {
    let bitmap_nr = counts[i]
    midx_push_u32(out, bitmap_pos)
    midx_push_u32(out, bitmap_nr)
    bitmap_pos += bitmap_nr
  }
  out
}

///|
fn midx_push_u32(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 24) & 0xff).to_byte())
  out.push(((value >> 16) & 0xff).to_byte())
  out.push(((value >> 8) & 0xff).to_byte())
  out.push((value & 0xff).to_byte())
}

///|
fn midx_push_u64(out : Array[Byte], value : Int) -> Unit {
  // For simplicity, we assume offsets fit in 32 bits (prepend 4 zero bytes)
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x00')
  midx_push_u32(out, value)
}

///|
fn midx_read_u32(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn midx_u32_lt(a : Int, b : Int) -> Bool {
  let a_neg = a < 0
  let b_neg = b < 0
  if a_neg != b_neg {
    not(a_neg) && b_neg
  } else {
    a < b
  }
}

///|
fn midx_u32_gt(a : Int, b : Int) -> Bool {
  midx_u32_lt(b, a)
}

///|
fn midx_compare_string_lex(a : String, b : String) -> Int {
  let min_len = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<min_len {
    let av = a[i].to_int()
    let bv = b[i].to_int()
    if av != bv {
      return av - bv
    }
  }
  a.length() - b.length()
}

///|
fn midx_sort_strings_lex_in_place(values : Array[String]) -> Unit {
  let n = values.length()
  let mut i = 0
  while i < n {
    let mut j = i + 1
    while j < n {
      if midx_compare_string_lex(values[i], values[j]) > 0 {
        let tmp = values[i]
        values[i] = values[j]
        values[j] = tmp
      }
      j += 1
    }
    i += 1
  }
}

///|
fn midx_compare_oid(a : @git.ObjectId, b : @git.ObjectId) -> Int {
  for i in 0..<20 {
    let av = a.bytes[i].to_int()
    let bv = b.bytes[i].to_int()
    if av != bv {
      return av - bv
    }
  }
  0
}

///|
fn midx_chunk_id_string(data : Bytes, offset : Int) -> String {
  String::from_array([
    Int::unsafe_to_char(data[offset].to_int()),
    Int::unsafe_to_char(data[offset + 1].to_int()),
    Int::unsafe_to_char(data[offset + 2].to_int()),
    Int::unsafe_to_char(data[offset + 3].to_int()),
  ])
}

///|
fn midx_find_chunk_range(
  chunks : Array[MidxChunkRange],
  chunk_id : String,
) -> MidxChunkRange? {
  for chunk in chunks {
    if chunk.id == chunk_id {
      return Some(chunk)
    }
  }
  None
}

///|
fn midx_find_chunk(data : Bytes, num_chunks : Int, chunk_id : String) -> Int {
  let header_size = 12
  for i in 0..<num_chunks {
    let entry_offset = header_size + i * 12
    let id0 = data[entry_offset].to_int()
    let id1 = data[entry_offset + 1].to_int()
    let id2 = data[entry_offset + 2].to_int()
    let id3 = data[entry_offset + 3].to_int()
    let id_str = String::from_array([
      Int::unsafe_to_char(id0),
      Int::unsafe_to_char(id1),
      Int::unsafe_to_char(id2),
      Int::unsafe_to_char(id3),
    ])
    if id_str == chunk_id {
      // Read offset (8 bytes, but we use lower 4)
      return midx_read_u32(data, entry_offset + 8)
    }
  }
  0
}

///|
fn midx_find_chunk_end(
  data : Bytes,
  num_chunks : Int,
  chunk_id : String,
) -> Int {
  let header_size = 12
  for i in 0..<num_chunks {
    let entry_offset = header_size + i * 12
    let id0 = data[entry_offset].to_int()
    let id1 = data[entry_offset + 1].to_int()
    let id2 = data[entry_offset + 2].to_int()
    let id3 = data[entry_offset + 3].to_int()
    let id_str = String::from_array([
      Int::unsafe_to_char(id0),
      Int::unsafe_to_char(id1),
      Int::unsafe_to_char(id2),
      Int::unsafe_to_char(id3),
    ])
    if id_str == chunk_id {
      // Next chunk's offset is the end
      return midx_read_u32(data, entry_offset + 12 + 8)
    }
  }
  data.length() - 20
}

///|
fn midx_bytes_to_string(data : Bytes, start : Int, end : Int) -> String {
  let chars : Array[Char] = []
  for i in start..<end {
    chars.push(Int::unsafe_to_char(data[i].to_int()))
  }
  String::from_array(chars)
}

///|
