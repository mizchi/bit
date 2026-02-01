///| Helper functions and utilities for git-shim

///|
fn io_error(err : @fs.IOError) -> @git.GitError {
  @git.GitError::IoError(err.to_string())
}

///|
fn bytes_from_array(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] }))
}

///|
fn str_to_bytes(s : String) -> Bytes {
  let arr : Array[Byte] = []
  for c in s {
    arr.push(c.to_int().to_byte())
  }
  bytes_from_array(arr)
}

///|
async fn print_line(s : String) -> Unit {
  @stdio.stdout.write(str_to_bytes(s + "\n"))
}

///|
async fn print_str(s : String) -> Unit {
  @stdio.stdout.write(str_to_bytes(s))
}

///|
async fn eprint_line(s : String) -> Unit {
  @stdio.stderr.write(str_to_bytes(s + "\n"))
}

///|
fn decode_bytes(data : Bytes) -> String {
  @encoding.decoder(@encoding.Encoding::UTF8).decode_lossy(data[:])
}

///|
fn trim_string(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn parent_dir(path : String) -> String {
  if path.length() == 0 || path == "/" {
    return "/"
  }
  let sep = @path.sep.to_string()
  match path.rev_find(sep) {
    None => ""
    Some(idx) => if idx == 0 { sep } else { (try! path[:idx]).to_string() }
  }
}

///|
fn ensure_dir(path : String) -> Unit raise @git.GitError {
  if path.length() == 0 || path == "/" || path == "." {
    return ()
  }
  if @fs.path_exists(path) {
    let is_dir = @fs.is_dir(path) catch { _ => false }
    if is_dir {
      return ()
    }
    raise @git.GitError::IoError("path exists and is not dir: " + path)
  }
  let parent = parent_dir(path)
  if parent.length() > 0 && parent != path {
    ensure_dir(parent)
  }
  @fs.create_dir(path) catch {
    err => raise io_error(err)
  }
}

///|
fn collect_args(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
fn prepend_arg(first : String, rest : Array[String]) -> Array[String] {
  let out : Array[String] = [first]
  out.append(rest)
  out
}

///|
async fn read_all_stdin() -> Bytes {
  let out : Array[Byte] = []
  while true {
    match @stdio.stdin.read_some(max_len=8192) {
      None => break
      Some(bytes) =>
        for b in bytes {
          out.push(b)
        }
    }
  }
  bytes_from_array(out)
}

///|
fn get_work_root() -> String {
  match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("GIT_WORK_TREE") {
        Some(dir) => dir
        None => "."
      }
  }
}

///|
fn normalize_repo_root(path : String) -> String {
  if path == ".git" {
    return "."
  }
  if path.has_suffix("/.git") && path.length() > 5 {
    return (try! path[:path.length() - 5]).to_string()
  }
  path
}

///|
fn get_author_string() -> String {
  match @sys.get_env_var("GIT_AUTHOR_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_AUTHOR_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u + " <" + u + "@localhost>"
        None => "Unknown <unknown@localhost>"
      }
  }
}

///|
fn get_commit_timestamp() -> Int64 {
  match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(s) => @strconv.parse_int64(s) catch { _ => get_current_timestamp() }
    None => get_current_timestamp()
  }
}
