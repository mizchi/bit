///|
fn git_dir_from_env() -> String {
  let base = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(cwd) => Some(cwd)
    None => @sys.get_env_var("GIT_SHIM_PWD")
  }
  match @sys.get_env_var("GIT_DIR") {
    Some(path) =>
      if path.has_prefix("/") {
        path
      } else {
        match base {
          None => path
          Some(cwd) => cwd + "/" + path
        }
      }
    None =>
      match base {
        None => ".git"
        Some(cwd) => cwd + "/.git"
      }
  }
}

///|
fn shim_cwd_from_env() -> String? {
  @sys.get_env_var("GIT_SHIM_CWD")
}

///|
fn resolve_in_cwd(path : String) -> String {
  let base = match shim_cwd_from_env() {
    Some(cwd) => Some(cwd)
    None => @sys.get_env_var("GIT_SHIM_PWD")
  }
  match base {
    None => path
    Some(cwd) => if path.has_prefix("/") { path } else { cwd + "/" + path }
  }
}

///|
fn pack_hash_id(pack : Bytes) -> @git.ObjectId raise @git.GitError {
  if pack.length() < 20 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  let start = pack.length() - 20
  let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i = 0; i < 20; i = i + 1 {
    bytes[i] = pack[start + i]
  }
  @git.ObjectId::new(bytes)
}

///|
fn pack_hash_hex(pack : Bytes) -> String raise @git.GitError {
  pack_hash_id(pack).to_hex()
}

///|
/// Parse git config file and get value for section.key
fn git_config_get(git_dir : String, section : String, key : String) -> String? {
  let config_path = git_dir + "/config"
  let content = @fs.read_file_to_string(config_path) catch { _ => return None }
  parse_git_config_value(content, section, key)
}

///|
/// Parse INI-style git config content
fn parse_git_config_value(
  content : String,
  target_section : String,
  target_key : String,
) -> String? {
  let lines = content.split("\n")
  let mut current_section = ""
  let target_section_lower = target_section.to_lower()
  let target_key_lower = target_key.to_lower()
  for line_iter in lines {
    let line = line_iter.to_string().trim().to_string()
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") {
      // Section header: [section] or [section "subsection"]
      match line.find("]") {
        Some(idx) => {
          let section_part = (try! line[1:idx]).to_string()
          // Handle subsection: [remote "origin"] -> remote.origin
          match section_part.find(" ") {
            Some(si) => {
              let main_sec = (try! section_part[:si]).to_string()
              let sub_sec = (try! section_part[si + 1:])
                .to_string()
                .trim()
                .to_string()
                .replace(old="\"", new="")
              current_section = main_sec.to_lower() + "." + sub_sec.to_lower()
            }
            None => current_section = section_part.to_lower()
          }
        }
        None => ()
      }
      continue
    }
    // Key = value
    match line.find("=") {
      Some(idx) => {
        let k = (try! line[:idx]).to_string().trim().to_string()
        let v = (try! line[idx + 1:]).to_string().trim().to_string()
        if current_section == target_section_lower &&
          k.to_lower() == target_key_lower {
          return Some(v)
        }
      }
      None => ()
    }
  }
  None
}

///|
/// Parse size value like "3m", "1k", "1g", "1024"
fn parse_size_value(value : String) -> Int64? {
  let trimmed = value.trim().to_string().to_lower()
  if trimmed.length() == 0 {
    return None
  }
  let len = trimmed.length()
  let last_char = trimmed[len - 1]
  let (num_str, multiplier) : (String, Int64) = if last_char >= '0' &&
    last_char <= '9' {
    (trimmed, 1L)
  } else {
    let num_part = (try! trimmed[:len - 1]).to_string()
    let mult : Int64 = match last_char {
      'k' => 1024L
      'm' => 1024L * 1024L
      'g' => 1024L * 1024L * 1024L
      _ => return None
    }
    (num_part, mult)
  }
  let num = @strconv.parse_int64(num_str) catch { _ => return None }
  Some(num * multiplier)
}

///|
/// Get pack.packSizeLimit from git config
fn get_pack_size_limit(git_dir : String) -> Int64? {
  match git_config_get(git_dir, "pack", "packSizeLimit") {
    None => None
    Some(value) => parse_size_value(value)
  }
}

///|
/// Check if repository uses SHA256 (returns true if SHA256, false if SHA1)
fn is_sha256_repo(git_dir : String) -> Bool {
  // Check extensions.objectFormat in config
  match git_config_get(git_dir, "extensions", "objectFormat") {
    Some(format) => format.to_lower() == "sha256"
    None => false
  }
}
