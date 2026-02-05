///| Gitignore integration for git worktree operations (async, native)

///|
/// List files under root, excluding ignored paths and .git.
pub async fn list_working_files_async(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[String] raise @git.GitError {
  let cache_enabled = false
  let matcher = @ignore.Matcher::new()
  let out : Array[String] = []
  let dirs : Array[PathMtime] = []
  let ignores : Array[PathMtime] = []
  walk_dir_async(fs, root, "", matcher, out, cache_enabled, dirs, ignores)
  if cache_enabled {
    write_cache(root, dirs, ignores, out)
  }
  out
}

///|
pub fn working_files_cache(root : String) -> Array[String]? noraise {
  let cache_enabled = cache_enabled_by_env() && cache_available(root)
  if not(cache_enabled) || cache_clear_requested() {
    return None
  }
  match try_read_cache(root) {
    Some(cache) =>
      if validate_cache(root, cache) {
        Some(cache.files)
      } else {
        None
      }
    None => None
  }
}

///|
async fn walk_dir_async(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
  matcher : @ignore.Matcher,
  out : Array[String],
  cache_enabled : Bool,
  dirs : Array[PathMtime],
  ignores : Array[PathMtime],
) -> Unit raise @git.GitError {
  let dir = if rel == "" { root } else { join_path(root, rel) }
  // Skip submodules (directories containing .git file or directory)
  if rel != "" {
    let git_marker = join_path(dir, ".git")
    if fs.is_file(git_marker) {
      return ()
    }
  }
  let entries = fs.readdir(dir)
  let mut has_git = false
  let mut has_gitignore = false
  for name in entries {
    if name == ".git" {
      has_git = true
    }
    if name == ".gitignore" {
      has_gitignore = true
    }
    if has_git && has_gitignore {
      break
    }
  }
  if rel != "" && has_git {
    return ()
  }
  let prev_len = matcher.len()
  if has_gitignore {
    let ignore_path = join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for name in entries {
    if name == "." || name == ".." || name == ".git" || name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = join_path(root, child_rel)
    let is_symlink = read_symlink_target_path(child_path) is Some(_)
    let is_dir = if is_symlink { false } else { fs.is_dir(child_path) }
    if matcher.is_ignored(child_rel, is_dir) {
      if is_dir && matcher.has_negation() {
        walk_dir_async(
          fs, root, child_rel, matcher, out, cache_enabled, dirs, ignores,
        )
      }
      continue
    }
    if is_dir {
      walk_dir_async(
        fs, root, child_rel, matcher, out, cache_enabled, dirs, ignores,
      )
    } else {
      out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}

///|
priv struct PathMtime {
  path : String
  sec : Int
  nsec : Int
}

///|
priv struct WorkingFilesCache {
  dirs : Array[PathMtime]
  ignores : Array[PathMtime]
  files : Array[String]
}

///|
fn cache_enabled_by_env() -> Bool {
  false
}

///|
fn cache_clear_requested() -> Bool {
  false
}

///|
fn cache_available(root : String) -> Bool noraise {
  let _ = root
  let _ = cache_file_path
  let _ = parse_cache
  let _ = encode_cache
  false
}

///|
fn cache_file_path(root : String) -> String {
  join_path(join_path(root, ".git/bit"), "untracked.cache")
}

///|
fn try_read_cache(root : String) -> WorkingFilesCache? noraise {
  let _ = root
  None
}

///|
fn parse_cache(text : String) -> WorkingFilesCache? {
  let it = text.split("\n").iterator()
  match it.next() {
    Some(v) if v.to_string() == "v1" => ()
    _ => return None
  }
  let dirs_line = match it.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let dirs_count = parse_count(dirs_line, "dirs ")
  guard dirs_count is Some(dir_len) else { return None }
  let dirs : Array[PathMtime] = Array::new(capacity=dir_len)
  for _ in 0..<dir_len {
    let line = match it.next() {
      Some(v) => v
      None => return None
    }
    match parse_mtime_line(line) {
      Some(v) => dirs.push(v)
      None => return None
    }
  }
  let ignores_line = match it.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let ignores_count = parse_count(ignores_line, "ignores ")
  guard ignores_count is Some(ignore_len) else { return None }
  let ignores : Array[PathMtime] = Array::new(capacity=ignore_len)
  for _ in 0..<ignore_len {
    let line = match it.next() {
      Some(v) => v
      None => return None
    }
    match parse_mtime_line(line) {
      Some(v) => ignores.push(v)
      None => return None
    }
  }
  let files_line = match it.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let files_count = parse_count(files_line, "files ")
  guard files_count is Some(file_len) else { return None }
  let files : Array[String] = Array::new(capacity=file_len)
  for _ in 0..<file_len {
    let line = match it.next() {
      Some(v) => v.to_string()
      None => return None
    }
    if line.length() == 0 {
      return None
    }
    files.push(line)
  }
  Some({ dirs, ignores, files })
}

///|
fn parse_count(line : String, prefix : String) -> Int? {
  if not(line.has_prefix(prefix)) {
    return None
  }
  let num = String::unsafe_substring(
    line,
    start=prefix.length(),
    end=line.length(),
  )
  let parsed = try? @strconv.parse_int(num)
  match parsed {
    Ok(v) => Some(v)
    Err(_) => None
  }
}

///|
fn parse_mtime_line(line : StringView) -> PathMtime? {
  let parts = line.split("\t").iterator()
  let path = match parts.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let sec_str = match parts.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let nsec_str = match parts.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let sec_res = try? @strconv.parse_int(sec_str)
  let nsec_res = try? @strconv.parse_int(nsec_str)
  match sec_res {
    Ok(sec) =>
      match nsec_res {
        Ok(nsec) => Some({ path, sec, nsec })
        Err(_) => None
      }
    Err(_) => None
  }
}

///|
fn validate_cache(
  root : String,
  cache : WorkingFilesCache,
) -> Bool noraise {
  let _ = root
  let _ = cache.dirs
  let _ = cache.ignores
  false
}

///|
fn write_cache(
  root : String,
  dirs : Array[PathMtime],
  ignores : Array[PathMtime],
  files : Array[String],
) -> Unit noraise {
  let _ = root
  let _ = dirs
  let _ = ignores
  let _ = files
}

///|
fn encode_cache(
  dirs : Array[PathMtime],
  ignores : Array[PathMtime],
  files : Array[String],
) -> String {
  let sb = StringBuilder::new()
  sb.write_string("v1\n")
  sb.write_string("dirs " + dirs.length().to_string() + "\n")
  for d in dirs {
    sb.write_string(
      d.path + "\t" + d.sec.to_string() + "\t" + d.nsec.to_string() + "\n",
    )
  }
  sb.write_string("ignores " + ignores.length().to_string() + "\n")
  for d in ignores {
    sb.write_string(
      d.path + "\t" + d.sec.to_string() + "\t" + d.nsec.to_string() + "\n",
    )
  }
  sb.write_string("files " + files.length().to_string() + "\n")
  let mut i = 0
  while i < files.length() {
    sb.write_string(files[i])
    if i + 1 < files.length() {
      sb.write_char('\n')
    }
    i += 1
  }
  sb.to_string()
}
