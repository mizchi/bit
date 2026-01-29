///|
priv struct PackObjectsConfig {
  revs : Bool
  stdout : Bool
  all : Bool
  delta_mode : @git.PackDeltaMode
  base_name : String?
  progress : Bool
  path_walk : Bool
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
  let mut base_name : String? = None
  let mut progress = false
  let mut path_walk = false
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
        "--path-walk" => path_walk = true
        "--no-path-walk" => ()
        "--thin" => ()
        "--progress" => progress = true
        "--no-progress" => ()
        "--quiet" => ()
        "-q" => ()
        "--stdin" =>
          return PackObjectsParse::Error(
            "fatal: disallowed abbreviated or ambiguous option 'stdin'",
          )
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
        _ =>
          if arg.has_prefix("--window=") {
            let value = (try! arg[9:]).to_string()
            let parsed = @strconv.parse_int(value) catch {
              _ => return PackObjectsParse::Unsupported
            }
            window = parsed
          } else if arg.has_prefix("--index-version") ||
            arg.has_prefix("--stdin-packs") ||
            arg.has_prefix("--write-bitmap-index") ||
            arg.has_prefix("--filter") ||
            arg.has_prefix("--name-hash-version") ||
            arg.has_prefix("--threads") ||
            arg.has_prefix("--revs=") ||
            arg.has_prefix("--keep") ||
            arg.has_prefix("--no-reuse") ||
            arg.has_prefix("--reuse") ||
            arg.has_prefix("--delta-islands") {
            return PackObjectsParse::Unsupported
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
  if window <= 0 {
    delta_mode = @git.PackDeltaMode::NoDelta
  }
  if !stdout && base_name is None {
    return PackObjectsParse::Unsupported
  }
  PackObjectsParse::Ok({
    revs,
    stdout,
    all,
    delta_mode,
    base_name,
    progress,
    path_walk,
  })
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
  if trimmed.length() < 40 {
    return None
  }
  if trimmed.length() > 40 {
    if !is_space_byte(trimmed[40]) {
      return None
    }
  }
  let bytes = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    let hi = hex_byte_to_int(trimmed[i * 2])
    let lo = hex_byte_to_int(trimmed[i * 2 + 1])
    match (hi, lo) {
      (Some(h), Some(l)) => bytes[i] = ((h << 4) | l).to_byte()
      _ => return None
    }
  }
  Some(@git.ObjectId::new(bytes))
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
async fn handle_pack_objects(args : Array[String]) -> Unit {
  match parse_pack_objects_args(args) {
    PackObjectsParse::Unsupported =>
      run_system_git(prepend_arg("pack-objects", args))
    PackObjectsParse::Error(msg) => {
      @stdio.stderr.write(msg + "\n")
      @sys.exit(1)
    }
    PackObjectsParse::Ok(cfg) => {
      let fs = OsFs::new()
      let git_dir = git_dir_from_env()
      if !fs.is_dir(git_dir) && !(cfg.all || cfg.revs) {
        @stdio.stderr.write("fatal: not a git repository\n")
        @sys.exit(1)
      }
      let db = @gitlib.ObjectDb::load(fs, git_dir)
      let mut objects : Array[@git.PackObject] = []
      if cfg.all {
        let refs = @gitlib.show_ref(fs, git_dir)
        let commits : Array[@git.ObjectId] = []
        for pair in refs {
          let (_name, id) = pair
          commits.push(id)
        }
        objects = @gitlib.collect_reachable_objects_from_commits(
          db, fs, commits,
        )
      } else if cfg.revs {
        let input = read_all_stdin()
        let lines = split_lines_bytes(input)
        let include_commits : Array[@git.ObjectId] = []
        let exclude_commits : Array[@git.ObjectId] = []
        for line in lines {
          let trimmed = trim_line_bytes(line)
          if trimmed.length() == 0 {
            continue
          }
          let text = line_to_string(trimmed)
          let (negated, spec) = if text.has_prefix("^") {
            (true, (try! text[1:]).to_string())
          } else {
            (false, text)
          }
          match @gitlib.rev_parse(fs, git_dir, spec) {
            None => {
              @stdio.stderr.write("fatal: bad revision '" + spec + "'\n")
              @sys.exit(1)
            }
            Some(id) =>
              if negated {
                exclude_commits.push(id)
              } else {
                include_commits.push(id)
              }
          }
        }
        let include_objects = @gitlib.collect_reachable_objects_from_commits(
          db, fs, include_commits,
        )
        if exclude_commits.length() == 0 {
          objects = include_objects
        } else {
          let exclude_objects = @gitlib.collect_reachable_objects_from_commits(
            db, fs, exclude_commits,
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
      } else {
        let input = read_all_stdin()
        let lines = split_lines_bytes(input)
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
                invalid_object_line_message(line_to_string(line)),
              )
              @sys.exit(1)
            }
            Some(id) =>
              match db.get(fs, id) {
                None => {
                  @stdio.stderr.write("fatal: bad object " + id.to_hex() + "\n")
                  @sys.exit(1)
                }
                Some(obj) => objects.push(obj)
              }
          }
        }
      }
      if cfg.path_walk {
        @stdio.stderr.write("Compressing objects by path\n")
      }
      let (pack, delta_count) = @git.create_packfile_with_delta_stats(
        objects,
        cfg.delta_mode,
      )
      if cfg.progress {
        @stdio.stderr.write(
          "Total " +
          objects.length().to_string() +
          " (delta " +
          delta_count.to_string() +
          ")\n",
        )
      }
      if cfg.stdout {
        @stdio.stdout.write(pack)
        @sys.exit(0)
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
      let pack_path = base_name + "-" + hash_hex + ".pack"
      let idx_path = base_name + "-" + hash_hex + ".idx"
      fs.write_file(pack_path, pack)
      @git.write_pack_index_from_objects(fs, idx_path, pack, objects)
      @stdio.stdout.write(hash_hex + "\n")
    }
  }
}
