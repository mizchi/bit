///| Helper functions and utilities for git-shim

///|
fn io_error(err : @fs.IOError) -> @git.GitError {
  @git.GitError::IoError(err.to_string())
}

///|
fn bytes_from_array(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), i => arr[i]))
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
async fn warn_unimplemented_arg(cmd : String, arg : String) -> Unit {
  if arg == "--" {
    return
  }
  let msg = "warning: " + cmd + ": unsupported option '" + arg + "'\n"
  @stdio.stderr.write(str_to_bytes(msg))
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
fn is_hex_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
fn is_hex_string(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if (c |> is_hex_char |> not) {
      return false
    }
  }
  true
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
fn normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()

      } else if not(path.has_prefix("/")) {
        parts.push(part)
      }
    } else {
      parts.push(part)
    }
  }
  let result = parts.join("/")
  if path.has_prefix("/") {
    if result.length() == 0 {
      "/"
    } else {
      "/" + result
    }
  } else if result.length() == 0 {
    "."
  } else {
    result
  }
}

///|
fn is_bare_repo_dir(path : String) -> Bool {
  let head_ok = @fs.is_file(path + "/HEAD") catch { _ => false }
  let objs_ok = @fs.is_dir(path + "/objects") catch { _ => false }
  head_ok && objs_ok
}

///|
fn find_repo_root(start : String) -> String? {
  let mut current = normalize_path(start)
  if current.length() == 0 {
    current = "."
  }
  let ceiling_dirs : Array[String] = []
  match @sys.get_env_var("GIT_CEILING_DIRECTORIES") {
    Some(raw) =>
      for view in raw.split(":") {
        let dir = view.to_string()
        if dir.length() == 0 {
          continue
        }
        ceiling_dirs.push(normalize_path(dir))
      }
    None => ()
  }
  let mut last = ""
  while true {
    if ceiling_dirs.length() > 0 {
      for ceiling in ceiling_dirs {
        if current == ceiling {
          return None
        }
      }
    }
    let git_path = if current == "/" {
      "/.git"
    } else if current == "." {
      ".git"
    } else {
      current + "/.git"
    }
    let is_git_dir = @fs.is_dir(git_path) catch { _ => false }
    let is_git_file = if is_git_dir {
      false
    } else {
      @fs.is_file(git_path) catch {
        _ => false
      }
    }
    if is_git_dir || is_git_file {
      return Some(current)
    }
    let parent = parent_dir(current)
    let next = if parent.length() == 0 { "." } else { parent }
    if next == current || next == last {
      break
    }
    last = current
    current = next
  }
  None
}

///|
fn get_work_root() -> String {
  if @env.current_dir() is Some(dir) {
    if is_bare_repo_dir(dir) {
      return dir
    }
  }
  if is_bare_repo_dir(".") {
    return "."
  }
  if @sys.get_env_var("PWD") is Some(pwd) {
    if is_bare_repo_dir(pwd) {
      return pwd
    }
  }
  match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("GIT_WORK_TREE") {
        Some(dir) => dir
        None =>
          match @sys.get_env_var("GIT_DIR") {
            Some(dir) => normalize_repo_root(dir)
            None =>
              match @sys.get_env_var("GIT_SHIM_PWD") {
                Some(pwd) =>
                  if is_bare_repo_dir(pwd) {
                    pwd
                  } else {
                    find_repo_root(pwd).unwrap_or(".")
                  }
                None => "."
              }
          }
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
fn resolve_git_dir(fs : &@git.RepoFileSystem, root : String) -> String {
  let default_git_dir = root + "/.git"
  match @sys.get_env_var("GIT_DIR") {
    Some(dir) => {
      let resolved = if dir.has_prefix("/") {
        dir
      } else {
        match @sys.get_env_var("GIT_SHIM_CWD") {
          Some(base) => normalize_path(base + "/" + dir)
          None =>
            @sys.get_env_var("GIT_SHIM_PWD")
            .map(base => normalize_path(base + "/" + dir))
            .unwrap_or(dir)
        }
      }
      if fs.is_file(resolved) {
        @gitlib.resolve_gitdir(fs, resolved)
      } else if fs.is_dir(resolved) {
        resolved
      } else if is_bare_repo_dir(root) {
        root
      } else {
        resolved
      }
    }
    None =>
      if fs.is_file(default_git_dir) {
        @gitlib.resolve_gitdir(fs, default_git_dir)
      } else if fs.is_dir(default_git_dir) {
        default_git_dir
      } else if is_bare_repo_dir(root) {
        root
      } else {
        default_git_dir
      }
  }
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
