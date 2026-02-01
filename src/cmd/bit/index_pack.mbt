///|
priv struct IndexPackConfig {
  stdin : Bool
  verify : Bool
  output_path : String?
  keep_msg : String?
  pack_path : String?
}

///|
priv enum IndexPackParse {
  Ok(IndexPackConfig)
  Unsupported
  Error(String)
}

///|
fn parse_index_pack_args(args : Array[String]) -> IndexPackParse {
  let mut stdin = false
  let mut verify = false
  let mut output_path : String? = None
  let mut keep_msg : String? = None
  let mut pack_path : String? = None
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
        "--stdin" => stdin = true
        "--verify" => verify = true
        "--fix-thin" => ()
        "--keep" => keep_msg = Some("")
        "-o" => {
          if i + 1 >= args.length() {
            return IndexPackParse::Unsupported
          }
          output_path = Some(args[i + 1])
          i += 1
        }
        _ =>
          if arg.has_prefix("--keep=") {
            keep_msg = Some((try! arg[7:]).to_string())
          } else if arg.has_prefix("--object-format") ||
            arg.has_prefix("--strict") ||
            arg.has_prefix("--fsck-objects") ||
            arg.has_prefix("--threads") {
            return IndexPackParse::Unsupported
          } else {
            return IndexPackParse::Unsupported
          }
      }
      i += 1
      continue
    }
    if pack_path is None {
      pack_path = Some(arg)
    } else {
      extra_args += 1
    }
    i += 1
  }
  if extra_args > 0 {
    return IndexPackParse::Error("fatal: too many arguments")
  }
  if !stdin && !verify && pack_path is None {
    return IndexPackParse::Unsupported
  }
  if verify && pack_path is None {
    return IndexPackParse::Error("fatal: --verify requires a pack file")
  }
  IndexPackParse::Ok({ stdin, verify, output_path, keep_msg, pack_path })
}

///|
fn write_keep_file(
  fs : OsFs,
  path : String,
  msg : String?,
) -> Unit raise @git.GitError {
  match msg {
    None => ()
    Some(text) => {
      let content = if text.length() == 0 { "" } else { text + "\n" }
      fs.write_string(path, content)
    }
  }
}

///|
/// Verify pack index against pack file.
/// Returns error message on failure, None on success.
fn verify_pack_index(idx : Bytes, pack : Bytes) -> String? {
  // Check minimum lengths
  if idx.length() < 8 {
    return Some("pack index too short")
  }
  if pack.length() < 32 {
    return Some("pack file too short")
  }

  // Check index magic and version
  if idx[0] != b'\xff' || idx[1] != b't' || idx[2] != b'O' || idx[3] != b'c' {
    // v1 format - different structure
    return verify_pack_index_v1(idx, pack)
  }
  let version = read_u32_be(idx, 4)
  if version != 2 {
    return Some("unsupported index version: \{version}")
  }

  // Verify index checksum (last 20 bytes)
  if idx.length() < 40 {
    return Some("index file truncated")
  }
  let idx_data_len = idx.length() - 20
  let idx_data = Bytes::from_array(
    FixedArray::makei(idx_data_len, fn(i) { idx[i] }),
  )
  let computed_idx_checksum = @git.sha1(idx_data)
  let stored_idx_checksum = read_sha1_at(idx, idx_data_len)
  if computed_idx_checksum != stored_idx_checksum {
    return Some("incorrect index checksum")
  }

  // Read fanout table and get object count
  let fanout_start = 8
  let mut prev_count : Int64 = 0
  for i in 0..<256 {
    let count = read_u32_be_i64(idx, fanout_start + i * 4)
    if count < prev_count {
      return Some("corrupt fanout table: non-monotonic")
    }
    prev_count = count
  }
  let count = prev_count
  if count > 2147483647L {
    return Some("too many objects in index")
  }
  let count_i = count.to_int()

  // Calculate table positions
  let ids_start = fanout_start + 256 * 4
  let crc_start = ids_start + count_i * 20
  let offsets_start = crc_start + count_i * 4

  // Check if offset table fits
  let min_idx_len = offsets_start + count_i * 4 + 20 + 20 // offsets + pack_checksum + idx_checksum
  if idx.length() < min_idx_len {
    return Some("index file truncated (offsets)")
  }

  // Verify pack checksum stored in index matches actual pack
  let pack_checksum_in_idx_offset = idx.length() - 40
  let stored_pack_checksum = read_sha1_at(idx, pack_checksum_in_idx_offset)
  let pack_data_len = pack.length() - 20
  if pack_data_len < 12 {
    return Some("pack file too short")
  }
  let pack_data = Bytes::from_array(
    FixedArray::makei(pack_data_len, fn(i) { pack[i] }),
  )
  let computed_pack_checksum = @git.sha1(pack_data)
  if computed_pack_checksum != stored_pack_checksum {
    return Some("pack checksum mismatch")
  }

  // Verify pack header
  if pack[0] != b'P' || pack[1] != b'A' || pack[2] != b'C' || pack[3] != b'K' {
    return Some("invalid pack magic")
  }
  let pack_version = read_u32_be(pack, 4)
  if pack_version != 2 {
    return Some("unsupported pack version: \{pack_version}")
  }
  let pack_count = read_u32_be(pack, 8)
  if pack_count != count_i {
    return Some(
      "object count mismatch: pack has \{pack_count}, index has \{count_i}",
    )
  }

  // Count how many offsets have MSB set (use extended table)
  let mut extended_count = 0
  for i in 0..<count_i {
    let offset_raw = read_u32_be_i64(idx, offsets_start + i * 4)
    if (offset_raw & 0x80000000L) != 0L {
      extended_count += 1
    }
  }

  // If extended offsets exist, verify the extended table
  let extended_start = offsets_start + count_i * 4
  if extended_count > 0 {
    let expected_extended_end = extended_start + extended_count * 8
    if expected_extended_end > pack_checksum_in_idx_offset {
      return Some("index file truncated (extended offsets)")
    }
  }

  // Verify all offsets are within pack bounds
  let pack_data_end = pack.length() - 20 // exclude trailer
  let mut ext_idx = 0
  for i in 0..<count_i {
    let offset_raw = read_u32_be_i64(idx, offsets_start + i * 4)
    let offset = if (offset_raw & 0x80000000L) != 0L {
      // Extended offset - get from extended table
      let ext_offset_pos = extended_start + ext_idx * 8
      if ext_offset_pos + 8 > pack_checksum_in_idx_offset {
        return Some("bogus offset into extended table")
      }
      ext_idx += 1
      read_u64_be(idx, ext_offset_pos)
    } else {
      offset_raw
    }
    if offset < 12L {
      return Some("bogus object offset: \{offset} (before header)")
    }
    if offset >= pack_data_end.to_int64() {
      return Some("bogus object offset: \{offset} (beyond pack data)")
    }
  }
  None
}

///|
/// Verify v1 pack index
fn verify_pack_index_v1(idx : Bytes, pack : Bytes) -> String? {
  // v1 index: fanout[256] + entries[count] * (offset[4] + sha1[20])
  // No magic header, starts directly with fanout

  if idx.length() < 256 * 4 {
    return Some("v1 index too short for fanout")
  }

  // Read fanout to get count
  let mut prev_count : Int64 = 0
  for i in 0..<256 {
    let count = read_u32_be_i64(idx, i * 4)
    if count < prev_count {
      return Some("corrupt fanout table: non-monotonic")
    }
    prev_count = count
  }
  let count = prev_count
  if count > 2147483647L {
    return Some("too many objects in v1 index")
  }
  let count_i = count.to_int()

  // v1 entries: each entry is offset(4) + sha1(20) = 24 bytes
  let entries_start = 256 * 4
  let expected_len = entries_start + count_i * 24 + 20 // + pack checksum
  if idx.length() < expected_len {
    return Some("v1 index file truncated")
  }

  // Verify pack checksum
  let pack_checksum_offset = entries_start + count_i * 24
  let stored_pack_checksum = read_sha1_at(idx, pack_checksum_offset)
  let pack_data_len = pack.length() - 20
  if pack_data_len < 12 {
    return Some("pack file too short")
  }
  let pack_data = Bytes::from_array(
    FixedArray::makei(pack_data_len, fn(i) { pack[i] }),
  )
  let computed_pack_checksum = @git.sha1(pack_data)
  if computed_pack_checksum != stored_pack_checksum {
    return Some("pack checksum mismatch")
  }

  // Verify pack header and count
  if pack[0] != b'P' || pack[1] != b'A' || pack[2] != b'C' || pack[3] != b'K' {
    return Some("invalid pack magic")
  }
  let pack_count = read_u32_be(pack, 8)
  if pack_count != count_i {
    return Some(
      "object count mismatch: pack has \{pack_count}, index has \{count_i}",
    )
  }

  // Verify all offsets are within pack bounds
  let pack_data_end = pack.length() - 20
  for i in 0..<count_i {
    let offset = read_u32_be_i64(idx, entries_start + i * 24)
    if offset < 12L {
      return Some("bogus object offset: \{offset} (before header)")
    }
    if offset >= pack_data_end.to_int64() {
      return Some("bogus object offset: \{offset} (beyond pack data)")
    }
  }
  None
}

///|
fn read_u32_be(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn read_u32_be_i64(data : Bytes, offset : Int) -> Int64 {
  let b0 = data[offset].to_int64()
  let b1 = data[offset + 1].to_int64()
  let b2 = data[offset + 2].to_int64()
  let b3 = data[offset + 3].to_int64()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn read_u64_be(data : Bytes, offset : Int) -> Int64 {
  let hi = read_u32_be_i64(data, offset)
  let lo = read_u32_be_i64(data, offset + 4)
  (hi << 32) | lo
}

///|
fn read_sha1_at(data : Bytes, offset : Int) -> @git.ObjectId {
  let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    bytes[i] = data[offset + i]
  }
  @git.ObjectId::new(bytes)
}

///|
async fn handle_index_pack(args : Array[String]) -> Unit {
  match parse_index_pack_args(args) {
    IndexPackParse::Unsupported => {
      @stdio.stderr.write("bit index-pack: unsupported options\n")
      @sys.exit(1)
    }
    IndexPackParse::Error(msg) => {
      @stdio.stderr.write(msg + "\n")
      @sys.exit(1)
    }
    IndexPackParse::Ok(cfg) => {
      let fs = OsFs::new()

      // Handle --verify mode
      if cfg.verify {
        let pack_path = match cfg.pack_path {
          Some(path) => resolve_in_cwd(path)
          None => {
            @stdio.stderr.write("fatal: --verify requires a pack file\n")
            @sys.exit(1)
            ""
          }
        }
        let pack = @fs.read_file_to_bytes(pack_path) catch {
          err => {
            @stdio.stderr.write("fatal: " + err.to_string() + "\n")
            @sys.exit(1)
            Bytes::default()
          }
        }
        let idx_path = if pack_path.has_suffix(".pack") {
          let base = (try! pack_path[:pack_path.length() - 5]).to_string()
          base + ".idx"
        } else {
          pack_path + ".idx"
        }
        let idx = @fs.read_file_to_bytes(idx_path) catch {
          err => {
            @stdio.stderr.write("fatal: " + err.to_string() + "\n")
            @sys.exit(1)
            Bytes::default()
          }
        }
        match verify_pack_index(idx, pack) {
          Some(err) => {
            @stdio.stderr.write("error: " + err + "\n")
            @sys.exit(1)
          }
          None => {
            // Success - print the pack hash
            let hash_hex = pack_hash_hex(pack)
            @stdio.stdout.write(hash_hex + "\n")
          }
        }
        return
      }
      if cfg.stdin {
        let pack = read_all_stdin()
        let hash_hex = pack_hash_hex(pack)
        let git_dir = git_dir_from_env()
        if !fs.is_dir(git_dir) {
          @stdio.stderr.write("fatal: not a git repository\n")
          @sys.exit(1)
        }
        // SHA256 repositories are not yet supported
        if is_sha256_repo(git_dir) {
          @stdio.stderr.write(
            "bit: SHA256 repositories are not supported\n",
          )
          @sys.exit(1)
        }
        let pack_dir = git_dir + "/objects/pack"
        ensure_dir(pack_dir)
        let pack_path = pack_dir + "/pack-" + hash_hex + ".pack"
        let idx_path = match cfg.output_path {
          Some(path) => resolve_in_cwd(path)
          None => pack_dir + "/pack-" + hash_hex + ".idx"
        }
        fs.write_file(pack_path, pack)
        @git.write_pack_index(fs, idx_path, pack)
        let keep_path = pack_dir + "/pack-" + hash_hex + ".keep"
        write_keep_file(fs, keep_path, cfg.keep_msg)
        @stdio.stdout.write(hash_hex + "\n")
        return ()
      }
      // For file mode, check if current repo is SHA256
      let git_dir = git_dir_from_env()
      if fs.is_dir(git_dir) && is_sha256_repo(git_dir) {
        @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
        @sys.exit(1)
      }
      let pack_path = match cfg.pack_path {
        Some(path) => path
        None => {
          @stdio.stderr.write("fatal: missing pack file\n")
          @sys.exit(1)
          ""
        }
      }
      let pack_path = resolve_in_cwd(pack_path)
      let pack = @fs.read_file_to_bytes(pack_path) catch {
        err => {
          @stdio.stderr.write("fatal: " + err.to_string() + "\n")
          @sys.exit(1)
          Bytes::default()
        }
      }
      let hash_hex = pack_hash_hex(pack)
      let idx_path = match cfg.output_path {
        Some(path) => resolve_in_cwd(path)
        None =>
          if pack_path.has_suffix(".pack") {
            let base = (try! pack_path[:pack_path.length() - 5]).to_string()
            base + ".idx"
          } else {
            pack_path + ".idx"
          }
      }
      @git.write_pack_index(fs, idx_path, pack)
      if cfg.keep_msg is Some(_) {
        let keep_path = if pack_path.has_suffix(".pack") {
          let base = (try! pack_path[:pack_path.length() - 5]).to_string()
          base + ".keep"
        } else {
          pack_path + ".keep"
        }
        write_keep_file(fs, keep_path, cfg.keep_msg)
      }
      @stdio.stdout.write(hash_hex + "\n")
    }
  }
}
