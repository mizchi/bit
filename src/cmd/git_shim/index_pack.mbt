///|
priv struct IndexPackConfig {
  stdin : Bool
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
            arg.has_prefix("--verify") ||
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
  if !stdin && pack_path is None {
    return IndexPackParse::Unsupported
  }
  IndexPackParse::Ok({ stdin, output_path, keep_msg, pack_path })
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
async fn handle_index_pack(args : Array[String]) -> Unit {
  match parse_index_pack_args(args) {
    IndexPackParse::Unsupported =>
      run_system_git(prepend_arg("index-pack", args))
    IndexPackParse::Error(msg) => {
      @stdio.stderr.write(msg + "\n")
      @sys.exit(1)
    }
    IndexPackParse::Ok(cfg) => {
      let fs = OsFs::new()
      if cfg.stdin {
        let pack = read_all_stdin()
        let hash_hex = pack_hash_hex(pack)
        let git_dir = git_dir_from_env()
        if !fs.is_dir(git_dir) {
          @stdio.stderr.write("fatal: not a git repository\n")
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
