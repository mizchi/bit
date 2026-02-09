///| Remote helpers for CLI/core sharing

///|
fn remote_decode_bytes_lossy(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn remote_trim_string(s : String) -> String {
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
pub fn is_valid_remote_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  if name.has_suffix("/") || name.has_suffix(".lock") {
    return false
  }
  if name.contains("..") || name.contains("@{") {
    return false
  }
  let invalid = [" ", "\t", "\n", "\r", "~", "^", ":", "?", "*", "[", "\\"]
  for bad in invalid {
    if name.contains(bad) {
      return false
    }
  }
  true
}

///|
fn compare_strings_lex(a : String, b : String) -> Int {
  if a == b {
    return 0
  }
  let a_chars : Array[Char] = []
  for c in a {
    a_chars.push(c)
  }
  let b_chars : Array[Char] = []
  for c in b {
    b_chars.push(c)
  }
  let mut i = 0
  let alen = a_chars.length()
  let blen = b_chars.length()
  while i < alen && i < blen {
    let ac = a_chars[i]
    let bc = b_chars[i]
    if ac < bc {
      return -1
    }
    if ac > bc {
      return 1
    }
    i += 1
  }
  if alen < blen {
    -1
  } else if alen > blen {
    1
  } else {
    0
  }
}

///|
pub fn sort_strings_lex(items : Array[String]) -> Unit {
  let n = items.length()
  if n < 2 {
    return ()
  }
  for i in 0..<n {
    for j in (i + 1)..<n {
      if compare_strings_lex(items[i], items[j]) > 0 {
        let tmp = items[i]
        items[i] = items[j]
        items[j] = tmp
      }
    }
  }
}

///|
pub fn sort_branch_configs_by_name(items : Array[BranchConfig]) -> Unit {
  let n = items.length()
  if n < 2 {
    return ()
  }
  for i in 0..<n {
    for j in (i + 1)..<n {
      if compare_strings_lex(items[i].name, items[j].name) > 0 {
        let tmp = items[i]
        items[i] = items[j]
        items[j] = tmp
      }
    }
  }
}

///|
pub fn collect_local_branches(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] {
  let out : Array[String] = []
  let refs = list_refs_with_ids(fs, git_dir, Some("refs/heads/"))
  for name, _ in refs {
    let short = String::unsafe_substring(name, start=11, end=name.length())
    out.push(short)
  }
  out.sort()
  out
}

///|
pub fn is_remote_namespace(dst : String, remote_name : String) -> Bool {
  let prefix = "refs/remotes/" + remote_name + "/"
  dst.has_prefix(prefix) || dst == "refs/remotes/" + remote_name
}

///|
pub fn format_remove_warning(branches : Array[String]) -> String {
  if branches.length() == 0 {
    return ""
  }
  let lines : Array[String] = []
  if branches.length() == 1 {
    lines.push(
      "Note: A branch outside the refs/remotes/ hierarchy was not removed;",
    )
    lines.push("to delete it, use:")
  } else {
    lines.push(
      "Note: Some branches outside the refs/remotes/ hierarchy were not removed;",
    )
    lines.push("to delete them, use:")
  }
  for name in branches {
    lines.push("  git branch -d " + name)
  }
  lines.join("\n") + "\n"
}

///|
pub fn split_whitespace_all(s : String) -> Array[String] {
  let result : Array[String] = []
  let current = StringBuilder::new()
  let mut in_word = false
  for c in s {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      if in_word {
        result.push(current.to_string())
        current.reset()
        in_word = false
      }
    } else {
      current.write_char(c)
      in_word = true
    }
  }
  if in_word {
    result.push(current.to_string())
  }
  result
}

///|
fn parse_bool_value(value : String) -> Bool? {
  let lower = value.to_lower()
  if lower == "true" || lower == "1" || lower == "yes" {
    Some(true)
  } else if lower == "false" || lower == "0" || lower == "no" {
    Some(false)
  } else {
    None
  }
}

///|
pub fn remote_skip_default_update(
  blocks : Array[ConfigBlock],
  name : String,
) -> Bool {
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      for line in block.lines {
        match parse_config_kv(line) {
          Some((key, value)) if key == "skipdefaultupdate" =>
            return parse_bool_value(value).unwrap_or(false)
          _ => ()
        }
      }
    }
  }
  false
}

///|
pub enum RemoteHeadState {
  Missing
  Detached(String)
  Symref(String)
  Other(String)
}

///|
pub fn read_local_remote_head_state(
  fs : &@git.RepoFileSystem,
  head_path : String,
  remote_name : String,
) -> RemoteHeadState {
  if not(fs.is_file(head_path)) {
    return RemoteHeadState::Missing
  }
  let content = try? fs.read_file(head_path)
  match content {
    Err(_) => RemoteHeadState::Missing
    Ok(data) => {
      let line = data |> remote_decode_bytes_lossy |> remote_trim_string
      if line.has_prefix("ref: ") {
        let target = String::unsafe_substring(line, start=5, end=line.length())
        let prefix = "refs/remotes/" + remote_name + "/"
        if target.has_prefix(prefix) {
          let branch = String::unsafe_substring(
            target,
            start=prefix.length(),
            end=target.length(),
          )
          RemoteHeadState::Symref(branch)
        } else {
          RemoteHeadState::Other(target)
        }
      } else {
        RemoteHeadState::Detached(line)
      }
    }
  }
}

///|
pub fn read_remote_head_branch(
  fs : &@git.RepoFileSystem,
  remote_git_dir : String,
) -> String? {
  let head_path = remote_git_dir + "/HEAD"
  if not(fs.is_file(head_path)) {
    return None
  }
  let content = try? fs.read_file(head_path)
  match content {
    Err(_) => None
    Ok(data) => {
      let line = data |> remote_decode_bytes_lossy |> remote_trim_string
      if line.has_prefix("ref: ") {
        let refname = String::unsafe_substring(line, start=5, end=line.length())
        if refname.has_prefix("refs/heads/") {
          Some(
            String::unsafe_substring(refname, start=11, end=refname.length()),
          )
        } else {
          None
        }
      } else {
        None
      }
    }
  }
}

///|
pub fn update_follow_remote_head(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  guard rfs.is_file(config_path) else { return () }
  let content = remote_decode_bytes_lossy(rfs.read_file(config_path))
  let blocks = parse_config_blocks(content)
  let new_blocks : Array[ConfigBlock] = []
  let mut changed = false
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      let updated = block
      let lines : Array[String] = []
      for line in updated.lines {
        match parse_config_kv(line) {
          Some((key, value)) if key == "followremotehead" =>
            if value.to_lower() == "always" {
              lines.push("\tfollowRemoteHEAD = warn")
              changed = true
            } else {
              lines.push(line)
            }
          _ => lines.push(line)
        }
      }
      updated.lines = lines
      new_blocks.push(updated)
    } else {
      new_blocks.push(block)
    }
  }
  if changed {
    fs.write_string(config_path, render_config_blocks(new_blocks))
  }
}

///|
pub fn read_config_content(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> String {
  let config_path = git_dir + "/config"
  if rfs.is_file(config_path) {
    let content = try? rfs.read_file(config_path)
    match content {
      Ok(data) => remote_decode_bytes_lossy(data)
      Err(_) => ""
    }
  } else {
    ""
  }
}

///|
pub fn legacy_remote_exists(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Bool {
  rfs.is_file(git_dir + "/remotes/" + name) ||
  rfs.is_file(git_dir + "/branches/" + name)
}

///|
pub fn match_url_pattern(pattern : String, value : String) -> Bool {
  if pattern == value {
    return true
  }
  let value_chars : Array[Char] = []
  for c in value {
    value_chars.push(c)
  }
  let tokens : Array[(Char, Bool)] = []
  for c in pattern {
    if c == '+' && tokens.length() > 0 {
      let (ch, _repeat) = tokens.pop().unwrap_or(('.', false))
      tokens.push((ch, true))
    } else {
      tokens.push((c, false))
    }
  }
  let mut vi = 0
  for token in tokens {
    let (ch, repeat) = token
    if repeat {
      if vi >= value_chars.length() {
        return false
      }
      let mut matched = false
      while vi < value_chars.length() {
        let vc = value_chars[vi]
        if vc != ch {
          break
        }
        matched = true
        vi += 1
      }
      if not(matched) {
        return false
      }
    } else {
      if vi >= value_chars.length() || value_chars[vi] != ch {
        return false
      }
      vi += 1
    }
  }
  vi == value_chars.length()
}

///|
fn split_by_newline(s : String) -> Array[String] {
  let result : Array[String] = []
  let mut start = 0
  let len = s.length()
  for i in 0..<len {
    if s[i] == '\n' {
      result.push(String::unsafe_substring(s, start~, end=i))
      start = i + 1
    }
  }
  if start < len {
    result.push(String::unsafe_substring(s, start~, end=len))
  }
  result
}

///|
pub fn read_config_value(
  fs : &@git.RepoFileSystem,
  config_path : String,
  section : String,
  name : String,
) -> String? {
  guard fs.is_file(config_path) else { return None }
  let content = try? fs.read_file(config_path)
  guard content is Ok(content) else { return None }
  let content_str = remote_decode_bytes_lossy(content)
  // Simple config parsing - look for key = value in section
  let section_lower = section.to_lower()
  let name_lower = name.to_lower()
  let mut in_section = false
  let lines = split_by_newline(content_str)
  for line in lines {
    let trimmed = remote_trim_string(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      let sec = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      in_section = sec.to_lower() == section_lower
    } else if in_section {
      match trimmed.find("=") {
        Some(idx) => {
          let k = remote_trim_string(
            String::unsafe_substring(trimmed, start=0, end=idx),
          )
          let v = remote_trim_string(
            String::unsafe_substring(
              trimmed,
              start=idx + 1,
              end=trimmed.length(),
            ),
          )
          if k.to_lower() == name_lower {
            return Some(v)
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
pub fn read_config_bool(
  fs : &@git.RepoFileSystem,
  config_path : String,
  section : String,
  name : String,
) -> Bool? {
  match read_config_value(fs, config_path, section, name) {
    Some(v) => {
      let lower = v.to_lower()
      if lower == "true" || lower == "1" || lower == "yes" {
        Some(true)
      } else if lower == "false" || lower == "0" || lower == "no" {
        Some(false)
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// Parse config overrides from GIT_CONFIG_OVERRIDES environment variable
pub fn parse_config_overrides() -> Map[String, String] {
  let config : Map[String, String] = {}
  let overrides = @gitio.env_get("GIT_CONFIG_OVERRIDES")
  guard overrides is Some(env_value) else { return config }
  // Parse key=value pairs separated by newlines
  for line in split_by_newline(env_value) {
    if line.length() == 0 {
      continue
    }
    match line.find("=") {
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx).to_lower()
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        config[key] = value
      }
      None =>
        // Key without = means the key is present but with no value
        config[line.to_lower()] = ""
    }
  }
  config
}

///|
pub fn get_protocol_version() -> Int {
  // Check GIT_PROTOCOL environment variable for version=2
  let git_protocol = @gitio.env_get("GIT_PROTOCOL")
  match git_protocol {
    Some(val) => if val.contains("version=2") { 2 } else { 1 }
    None => 1
  }
}

///|
pub fn build_upload_pack_config_with_overrides(
  fs : &@git.RepoFileSystem,
  root : String,
  overrides : Map[String, String],
) -> UploadPackConfig {
  let git_dir = if root.has_suffix(".git") { root } else { root + "/.git" }
  let config_path = git_dir + "/config"

  // Read allow_filter from file, then check cmdline override
  let allow_filter = match overrides.get("uploadpack.allowfilter") {
    Some(v) => {
      let lower = v.to_lower()
      lower == "true" || lower == "1" || lower == "yes"
    }
    None =>
      read_config_bool(fs, config_path, "uploadpack", "allowfilter").unwrap_or(
        true,
      )
  }

  // Read allow_ref_in_want from file, then check cmdline override
  let allow_ref_in_want = match overrides.get("uploadpack.allowrefinwant") {
    Some(v) => {
      let lower = v.to_lower()
      lower == "true" || lower == "1" || lower == "yes"
    }
    None =>
      read_config_bool(fs, config_path, "uploadpack", "allowrefinwant").unwrap_or(
        false,
      )
  }

  // Read blobpackfileuri from cmdline first, then file
  // Note: -c uploadpack.blobpackfileuri (without =) means key is present but empty
  // -c uploadpack.blobpackfileuri=anything means key has value
  let blob_packfile_uri = match overrides.get("uploadpack.blobpackfileuri") {
    Some(v) =>
      if v.length() > 0 {
        Some(v)
      } else {
        // Empty value means key was present but no value - still enable the feature
        // Actually git requires a non-empty value, so empty means disabled
        None
      }
    None =>
      match
        read_config_value(fs, config_path, "uploadpack", "blobpackfileuri") {
        Some(v) => if v.length() > 0 { Some(v) } else { None }
        None => None
      }
  }
  UploadPackConfig::new(allow_filter, blob_packfile_uri, allow_ref_in_want)
}
