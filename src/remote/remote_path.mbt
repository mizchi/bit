///| Remote path helpers

///|
fn is_http_url(url : String) -> Bool {
  url.has_prefix("http://") || url.has_prefix("https://")
}

///|
fn strip_file_scheme(url : String) -> String? {
  if url.has_prefix("file://") {
    Some(
      decode_file_url_path(
        String::unsafe_substring(url, start=7, end=url.length()),
      ),
    )
  } else {
    None
  }
}

///|
fn hex_char_to_int(c : Char) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(10 + c.to_int() - 'a'.to_int())
  } else if c >= 'A' && c <= 'F' {
    Some(10 + c.to_int() - 'A'.to_int())
  } else {
    None
  }
}

///|
fn decode_file_url_path(path : String) -> String {
  let out = StringBuilder::new()
  let mut i = 0
  while i < path.length() {
    let c = path.unsafe_get(i).to_int().unsafe_to_char()
    if c == '%' && i + 2 < path.length() {
      let c1 = path.unsafe_get(i + 1).to_int().unsafe_to_char()
      let c2 = path.unsafe_get(i + 2).to_int().unsafe_to_char()
      match (hex_char_to_int(c1), hex_char_to_int(c2)) {
        (Some(hi), Some(lo)) => {
          out.write_char((hi * 16 + lo).unsafe_to_char())
          i += 3
          continue
        }
        _ => ()
      }
    }
    out.write_char(c)
    i += 1
  }
  out.to_string()
}

///|
fn strip_remote_helper_path(url : String) -> String? {
  match url.find("::") {
    Some(idx) => {
      let start = idx + 2
      if start >= url.length() {
        None
      } else {
        let path = String::unsafe_substring(url, start~, end=url.length())
        if path.length() == 0 {
          None
        } else {
          Some(path)
        }
      }
    }
    None => None
  }
}

///|
fn normalize_local_path(path : String) -> String {
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
fn decode_bytes_lossy(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn trim_string_internal(s : String) -> String {
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
pub fn resolve_local_repo_path(
  fs : &@git.RepoFileSystem,
  root : String,
  url : String,
) -> String? {
  let raw0 = match strip_file_scheme(url) {
    Some(path) => path
    None => url
  }
  let raw = match strip_remote_helper_path(raw0) {
    Some(path) => path
    None => raw0
  }
  if is_http_url(raw) || raw.has_prefix("git@") {
    return None
  }
  if raw.has_prefix("/") {
    if fs.is_dir(raw) {
      return Some(raw)
    }
    return None
  }
  let candidate = normalize_local_path(root + "/" + raw)
  if fs.is_dir(candidate) {
    return Some(candidate)
  }
  let parent = match root.rev_find("/") {
    Some(i) => String::unsafe_substring(root, start=0, end=i)
    None => "."
  }
  let parent_candidate = normalize_local_path(parent + "/" + raw)
  if fs.is_dir(parent_candidate) {
    return Some(parent_candidate)
  }
  {
    let base = match @gitio.env_current_dir() {
      Some(dir) => dir
      None =>
        match @gitio.env_get("PWD") {
          Some(dir) => dir
          None => @gitio.env_get("GIT_SHIM_PWD").unwrap_or(".")
        }
    }
    let alt = normalize_local_path(base + "/" + raw)
    if fs.is_dir(alt) {
      return Some(alt)
    }
  }
  if fs.is_dir(raw) {
    return raw |> normalize_local_path |> Some
  }
  None
}

///|
/// Resolve .git file to actual git directory (for submodules)
pub fn resolve_gitdir(fs : &@git.RepoFileSystem, git_path : String) -> String {
  if fs.is_dir(git_path) {
    return git_path
  }
  // It's a file with "gitdir: <path>" content
  let content = decode_bytes_lossy(fs.read_file(git_path)) catch {
    _ => return git_path
  }
  let trimmed = trim_string_internal(content)
  if trimmed.has_prefix("gitdir: ") {
    let target = String::unsafe_substring(
      trimmed,
      start=8,
      end=trimmed.length(),
    )
    // If relative path, resolve relative to parent of .git file
    if not(target.has_prefix("/")) {
      let parent = match git_path.rev_find("/") {
        Some(i) => String::unsafe_substring(git_path, start=0, end=i)
        None => "."
      }
      return parent + "/" + target
    }
    return target
  }
  git_path
}

///|
pub fn detect_git_dir(
  fs : &@git.RepoFileSystem,
  path : String,
) -> (String, Bool)? {
  let bare_head = fs.is_file(path + "/HEAD")
  let bare_objs = fs.is_dir(path + "/objects")
  if bare_head && bare_objs {
    return Some((path, true))
  }
  let git_path = path + "/.git"
  if fs.is_dir(git_path) || fs.is_file(git_path) {
    let resolved = resolve_gitdir(fs, git_path)
    return Some((resolved, false))
  }
  None
}

///|
pub fn is_bare_git_dir(git_dir : String) -> Bool {
  if git_dir == ".git" {
    return false
  }
  if git_dir.has_suffix("/.git") {
    return false
  }
  true
}
