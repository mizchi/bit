///|
priv struct IndexPackConfig {
  stdin : Bool
  verify : Bool
  verify_stat_only : Bool
  fix_thin : Bool
  output_path : String?
  keep_msg : String?
  pack_path : String?
  object_format : String?
  strict : Bool
  fsck_objects : Bool
  ignore_missing_email : Bool
  delegate_to_real_git : Bool
}

///|
priv enum IndexPackParse {
  Ok(IndexPackConfig)
  Unsupported
  Error(String)
}

///|
fn normalize_object_format(value : String) -> String? {
  let lower = value.to_lower()
  match lower {
    "sha1" => Some("sha1")
    "sha256" => Some("sha256")
    _ => None
  }
}

///|
fn parse_index_pack_args(args : Array[String]) -> IndexPackParse {
  let mut stdin = false
  let mut verify = false
  let mut verify_stat_only = false
  let mut fix_thin = false
  let mut output_path : String? = None
  let mut keep_msg : String? = None
  let mut pack_path : String? = None
  let mut object_format : String? = None
  let mut strict = false
  let mut fsck_objects = false
  let mut ignore_missing_email = false
  let mut delegate_to_real_git = false
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
        "--verify-stat-only" => verify_stat_only = true
        "--fix-thin" => fix_thin = true
        "--keep" => keep_msg = Some("")
        "--strict" => {
          strict = true
          delegate_to_real_git = true
        }
        "--fsck-objects" => {
          fsck_objects = true
          delegate_to_real_git = true
        }
        "--index-version" => {
          delegate_to_real_git = true
          if i + 1 < args.length() {
            i += 1
          }
        }
        "--max-input-size" => {
          delegate_to_real_git = true
          if i + 1 < args.length() {
            i += 1
          }
        }
        "-v" => delegate_to_real_git = true
        "--verbose" => delegate_to_real_git = true
        "--object-format" => {
          if i + 1 >= args.length() {
            return IndexPackParse::Unsupported
          }
          object_format = normalize_object_format(args[i + 1])
          if object_format is None {
            return IndexPackParse::Unsupported
          }
          i += 1
        }
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
          } else if arg.has_prefix("--object-format=") {
            object_format = normalize_object_format((try! arg[16:]).to_string())
            if object_format is None {
              return IndexPackParse::Unsupported
            }
          } else if arg.has_prefix("--strict=") {
            strict = true
            delegate_to_real_git = true
            if arg.contains("missingEmail=ignore") {
              ignore_missing_email = true
            }
          } else if arg.has_prefix("--fsck-objects=") {
            fsck_objects = true
            delegate_to_real_git = true
            if arg.contains("missingEmail=ignore") {
              ignore_missing_email = true
            }
          } else if arg.has_prefix("--verify-stat-only") {
            return IndexPackParse::Unsupported
          } else if arg.has_prefix("--index-version=") {
            delegate_to_real_git = true
          } else if arg.has_prefix("--max-input-size=") {
            delegate_to_real_git = true
          } else if arg.has_prefix("--threads") {
            delegate_to_real_git = true
          } else if arg.has_prefix("--object-format") ||
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
  if !delegate_to_real_git {
    if extra_args > 0 {
      return IndexPackParse::Error("fatal: too many arguments")
    }
    if verify && verify_stat_only {
      return IndexPackParse::Error("fatal: --verify-stat-only cannot be used with --verify")
    }
    if !stdin && !verify && !verify_stat_only && pack_path is None {
      return IndexPackParse::Unsupported
    }
    if verify && pack_path is None {
      return IndexPackParse::Error("fatal: --verify requires a pack file")
    }
    if verify_stat_only && pack_path is None {
      return IndexPackParse::Error("fatal: --verify-stat-only requires a pack file")
    }
  }
  IndexPackParse::Ok({
    stdin,
    verify,
    verify_stat_only,
    fix_thin,
    output_path,
    keep_msg,
    pack_path,
    object_format,
    strict,
    fsck_objects,
    ignore_missing_email,
    delegate_to_real_git,
  })
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
fn real_git_path() -> String? {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) => Some(path)
    None => @sys.get_env_var("GIT_SHIM_REAL_GIT")
  }
}

///|
fn check_sha1_collisions_with_repo(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  objects : Array[@git.PackObject],
) -> Unit raise @git.GitError {
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  for obj in objects {
    let existing = db.get(fs, obj.id) catch {
      @git.GitError::HashMismatch(_, _) =>
        raise @git.GitError::PackfileError("SHA1 COLLISION FOUND")
      err => raise err
    }
    match existing {
      Some(base) =>
        if base.obj_type != obj.obj_type ||
          not(Bytes::equal(base.data, obj.data)) {
          raise @git.GitError::PackfileError("SHA1 COLLISION FOUND")
        }
      None => ()
    }
  }
}

///|
fn commit_has_missing_email(content : Bytes) -> Bool {
  let text = @utf8.decode_lossy(content[:])
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("author ") || line.has_prefix("committer ") {
      let lt = line.find("<")
      let gt = line.find(">")
      match (lt, gt) {
        (Some(li), Some(gi)) => if li >= gi { return true }
        _ => return true
      }
    }
  }
  false
}

///|
fn parse_tag_object_id(data : Bytes) -> @git.ObjectId? raise @git.GitError {
  let text = @utf8.decode_lossy(data[:])
  let mut object_hex : String? = None
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("object ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      object_hex = Some(hex)
      break
    }
  }
  match object_hex {
    None => None
    Some(hex) => Some(@git.ObjectId::from_hex(hex))
  }
}

///|
fn ensure_object_exists(
  fs : &@git.RepoFileSystem,
  db : @gitlib.ObjectDb?,
  pack_ids : Map[String, Bool],
  repo_cache : Map[String, Bool],
  id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  if pack_ids.contains(hex) {
    return
  }
  match db {
    None => raise @git.GitError::PackfileError("missing object " + hex)
    Some(objdb) => {
      if repo_cache.contains(hex) {
        if repo_cache[hex] {
          return
        }
        raise @git.GitError::PackfileError("missing object " + hex)
      }
      let exists = match objdb.get(fs, id) {
        Some(_) => true
        None => false
      }
      repo_cache[hex] = exists
      if !exists {
        raise @git.GitError::PackfileError("missing object " + hex)
      }
    }
  }
}

///|
fn check_pack_strict_and_fsck(
  fs : &@git.RepoFileSystem,
  git_dir : String?,
  objects : Array[@git.PackObject],
  strict : Bool,
  fsck_objects : Bool,
  ignore_missing_email : Bool,
) -> Unit raise @git.GitError {
  if !strict && !fsck_objects {
    return
  }
  let pack_ids : Map[String, Bool] = {}
  for obj in objects {
    pack_ids[obj.id.to_hex()] = true
  }
  let db = match git_dir {
    Some(dir) =>
      if fs.is_dir(dir) {
        Some(@gitlib.ObjectDb::load(fs, dir))
      } else {
        None
      }
    None => None
  }
  let repo_cache : Map[String, Bool] = {}
  for obj in objects {
    if (strict || fsck_objects) &&
      !ignore_missing_email &&
      obj.obj_type == @git.ObjectType::Commit {
      if commit_has_missing_email(obj.data) {
        raise @git.GitError::InvalidObject("missingEmail")
      }
    }
    if strict {
      match obj.obj_type {
        @git.ObjectType::Commit => {
          let info = @git.parse_commit(obj.data)
          ensure_object_exists(fs, db, pack_ids, repo_cache, info.tree)
          for parent in info.parents {
            ensure_object_exists(fs, db, pack_ids, repo_cache, parent)
          }
        }
        @git.ObjectType::Tree => {
          let entries = @git.parse_tree(obj.data)
          for entry in entries {
            ensure_object_exists(fs, db, pack_ids, repo_cache, entry.id)
          }
        }
        @git.ObjectType::Tag =>
          match parse_tag_object_id(obj.data) {
            None => raise @git.GitError::InvalidObject("invalid tag object")
            Some(target) =>
              ensure_object_exists(fs, db, pack_ids, repo_cache, target)
          }
        _ => ()
      }
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
      if cfg.delegate_to_real_git {
        match real_git_path() {
          Some(real_git) => {
            let real_args = real_git_args_from_cli()
            let code = @process.run(real_git, real_args)
            @sys.exit(code)
          }
          None => {
            @stdio.stderr.write("bit: unsupported index-pack options\n")
            @sys.exit(1)
          }
        }
      }
      let fs = OsFs::new()
      let git_dir = find_git_dir(fs)
      let wants_sha256 = cfg.object_format is Some(format) && format == "sha256"
      let repo_is_sha256 = is_sha256_repo_from_env()
      if wants_sha256 || repo_is_sha256 {
        match real_git_path() {
          Some(real_git) => {
            let real_args = real_git_args_from_cli()
            let code = @process.run(real_git, real_args)
            @sys.exit(code)
          }
          None => {
            @stdio.stderr.write("bit: SHA256 object format is not supported\n")
            @sys.exit(1)
          }
        }
      }

      if cfg.verify_stat_only {
        let pack_path = match cfg.pack_path {
          Some(path) => resolve_in_cwd(path)
          None => {
            @stdio.stderr.write("fatal: --verify-stat-only requires a pack file\n")
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
        let max_depth = @git.max_delta_chain_length(pack) catch {
          err => {
            @stdio.stderr.write("fatal: " + err.to_string() + "\n")
            @sys.exit(1)
            0
          }
        }
        @stdio.stdout.write("chain length = " + max_depth.to_string() + ":\n")
        return
      }

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
        if !fs.is_dir(git_dir) {
          @stdio.stderr.write("fatal: not a git repository\n")
          @sys.exit(1)
        }
        let bases = if cfg.fix_thin {
          @gitlib.load_all_objects_from_fs(fs, git_dir) catch { _ => [] }
        } else {
          []
        }
        let objects = if cfg.fix_thin {
          @git.parse_packfile_with_bases(pack, bases)
        } else {
          @git.parse_packfile(pack)
        }
        check_sha1_collisions_with_repo(fs, git_dir, objects)
        check_pack_strict_and_fsck(
          fs,
          Some(git_dir),
          objects,
          cfg.strict,
          cfg.fsck_objects,
          cfg.ignore_missing_email,
        )
        let pack_dir = git_dir + "/objects/pack"
        ensure_dir(pack_dir)
        let pack_path = pack_dir + "/pack-" + hash_hex + ".pack"
        let idx_path = match cfg.output_path {
          Some(path) => resolve_in_cwd(path)
          None => pack_dir + "/pack-" + hash_hex + ".idx"
        }
        fs.write_file(pack_path, pack)
        @git.write_pack_index_from_objects(fs, idx_path, pack, objects)
        let keep_path = pack_dir + "/pack-" + hash_hex + ".keep"
        write_keep_file(fs, keep_path, cfg.keep_msg)
        @stdio.stdout.write(hash_hex + "\n")
        return ()
      }
      // For file mode, check if current repo is SHA256
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
      let objects = @git.parse_packfile(pack)
      let git_dir_opt = if fs.is_dir(git_dir) { Some(git_dir) } else { None }
      match git_dir_opt {
        Some(dir) => check_sha1_collisions_with_repo(fs, dir, objects)
        None => ()
      }
      check_pack_strict_and_fsck(
        fs,
        git_dir_opt,
        objects,
        cfg.strict,
        cfg.fsck_objects,
        cfg.ignore_missing_email,
      )
      @git.write_pack_index_from_objects(fs, idx_path, pack, objects)
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
