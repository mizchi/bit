///|
async fn handle_config(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let normalized_args = normalize_config_args(args)
  // Parse arguments
  let mut get_mode = false
  let mut get_all_mode = false
  let mut get_bool = false
  let mut list_mode = false
  let mut unset_mode = false
  let mut unset_all = false
  let mut add_mode = false
  let mut remove_section_mode = false
  let mut fixed_value_mode = false
  let mut local_mode = false
  let mut global_mode = false
  let mut system_mode = false
  let mut config_path_override : String? = None
  let mut expect_config_path = false
  let mut key : String? = None
  let mut value : String? = None
  for arg in normalized_args {
    if expect_config_path {
      config_path_override = Some(arg)
      expect_config_path = false
      continue
    }
    match arg {
      "--local" => local_mode = true
      "--global" => global_mode = true
      "--system" => system_mode = true
      "-f" | "--file" => expect_config_path = true
      _ if arg.has_prefix("--file=") =>
        config_path_override = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
        )
      "--get" => get_mode = true
      "--get-all" => {
        get_mode = true
        get_all_mode = true
      }
      "--bool" => get_bool = true
      "--list" | "-l" => list_mode = true
      "--unset" => unset_mode = true
      "--unset-all" => unset_all = true
      "--add" => add_mode = true
      "--remove-section" => remove_section_mode = true
      "--fixed-value" => fixed_value_mode = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("config", arg)
      _ =>
        if key is None {
          key = Some(arg)
        } else if value is None {
          value = Some(arg)
        }
    }
  }
  if expect_config_path {
    raise @git.GitError::InvalidObject("option '-f' requires a value")
  }
  if global_mode && system_mode {
    raise @git.GitError::InvalidObject("only one config scope can be specified")
  }
  if local_mode && (global_mode || system_mode) {
    raise @git.GitError::InvalidObject(
      "--local cannot be used with --global or --system",
    )
  }
  let config_path = match config_path_override {
    Some(path) => path
    None =>
      if global_mode {
        match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
          Some(path) => path
          None =>
            match @sys.get_env_var("HOME") {
              Some(home) => home + "/.gitconfig"
              None => ".gitconfig"
            }
        }
      } else if system_mode {
        @sys.get_env_var("GIT_CONFIG_SYSTEM").unwrap_or("/etc/gitconfig")
      } else {
        let rfs : &@git.RepoFileSystem = fs
        let root = get_work_root()
        let git_dir = resolve_git_dir(rfs, root)
        git_dir + "/config"
      }
  }
  // Handle --list
  if list_mode {
    if fs.is_file(config_path) {
      list_config(fs, config_path)
    }
    return
  }
  if remove_section_mode {
    guard key is Some(section_key) else {
      raise @git.GitError::InvalidObject("section name required")
    }
    remove_config_section_file(fs, config_path, section_key)
    return
  }
  guard key is Some(k) else {
    raise @git.GitError::InvalidObject("key required")
  }
  // Handle --unset / --unset-all
  if unset_mode || unset_all {
    if fixed_value_mode && value is None {
      raise @git.GitError::InvalidObject("value required for --fixed-value")
    }
    let fixed = if fixed_value_mode { value } else { None }
    unset_config(fs, config_path, k, fixed, unset_all)
    return
  }
  if get_mode || value is None {
    // Read config - check overrides first
    let result = match get_config_override(k) {
      Some(v) => Some(v)
      None =>
        if fs.is_file(config_path) {
          get_config_value(fs, config_path, k)
        } else {
          (None : String?)
        }
    }
    match result {
      Some(val) =>
        if get_all_mode {
          print_line(val)
        } else if get_bool {
          print_line(
            if val == "true" || val == "1" || val == "yes" {
              "true"
            } else {
              "false"
            },
          )
        } else {
          print_line(val)
        }
      None =>
        // Key not found - exit silently with code 1 (git behavior)
        @sys.exit(1)
    }
  } else {
    // Write config
    guard value is Some(v) else { return }
    set_config(fs, config_path, k, v, add_mode)
  }
}

///|
fn normalize_config_args(args : Array[String]) -> Array[String] {
  if args.length() == 0 {
    return args
  }
  // Support modern "git config set ..." by mapping it to the legacy form
  // that this handler already implements.
  if args[0] != "set" {
    return args
  }
  let normalized : Array[String] = []
  for i in 1..<args.length() {
    let arg = args[i]
    if arg == "--append" {
      normalized.push("--add")
    } else {
      normalized.push(arg)
    }
  }
  normalized
}

///|
fn trim_chars(s : String, chars : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if code_in_string(c, chars) {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if code_in_string(c, chars) {
      end -= 1
    } else {
      break
    }
  }
  String::unsafe_substring(s, start~, end~)
}

///|
fn code_in_string(c : UInt16, s : String) -> Bool {
  for i in 0..<s.length() {
    if s.unsafe_get(i) == c {
      return true
    }
  }
  false
}

///|
async fn list_config(
  fs : &@git.RepoFileSystem,
  config_path : String,
) -> Unit raise Error {
  if not(fs.is_file(config_path)) {
    return
  }
  let content = decode_bytes(fs.read_file(config_path))
  let mut current_section = ""
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      current_section = String::unsafe_substring(
        line,
        start=1,
        end=line.length() - 1,
      )
      // Handle subsections like [remote "origin"]
      let space_idx = current_section.find(" ")
      match space_idx {
        Some(i) => {
          let main = String::unsafe_substring(current_section, start=0, end=i)
          let sub = trim_chars(
            String::unsafe_substring(
              current_section,
              start=i + 1,
              end=current_section.length(),
            ),
            "\" ",
          )
          current_section = main + "." + sub
        }
        None => ()
      }
      continue
    }
    // Parse key=value or key = value
    let eq_idx = line.find("=")
    match eq_idx {
      Some(i) => {
        let key_part = trim_chars(
          String::unsafe_substring(line, start=0, end=i),
          " \t",
        )
        let val_part = parse_config_value(
          String::unsafe_substring(line, start=i + 1, end=line.length()),
        )
        print_line("\{current_section}.\{key_part}=\{val_part}")
      }
      None => ()
    }
  }
}

///|
fn get_config_value(
  fs : &@git.RepoFileSystem,
  config_path : String,
  key : String,
) -> String? raise Error {
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes(fs.read_file(config_path))
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  // Handle section.subsection.key format (e.g., remote.origin.url)
  let (section, subsection, name) = if parts.length() == 2 {
    (parts[0], (None : String?), parts[1])
  } else {
    // section.subsection.key
    let sub : Array[String] = []
    for i in 1..<(parts.length() - 1) {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")), parts[parts.length() - 1])
  }
  let section_l = section.to_lower()
  let subsection_l = subsection.map(sub => sub.to_lower())
  let name_l = name.to_lower()
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[") && line.has_suffix("]") {
      let sec_content = String::unsafe_substring(
        line,
        start=1,
        end=line.length() - 1,
      )
      let sec_content_l = sec_content.to_lower()
      match subsection {
        Some(_) => {
          // Looking for [section "subsection"]
          let sub_l = subsection_l.unwrap_or("")
          let expected = section_l + " \"" + sub_l + "\""
          in_section = sec_content_l == expected ||
            sec_content_l == section_l + " " + sub_l
        }
        None =>
          in_section = sec_content_l == section_l ||
            sec_content_l.has_prefix(section_l + " ") ||
            sec_content_l.has_prefix(section_l + "\t")
      }
      continue
    }
    if in_section {
      // Check for key = value
      let eq_idx = line.find("=")
      match eq_idx {
        Some(i) => {
          let key_part = trim_chars(
            String::unsafe_substring(line, start=0, end=i),
            " \t",
          )
          if key_part.to_lower() == name_l {
            return Some(
              parse_config_value(
                String::unsafe_substring(line, start=i + 1, end=line.length()),
              ),
            )
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
fn is_horizontal_space(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
fn decode_config_escape(c : Char) -> Char {
  match c {
    'n' => '\n'
    't' => '\t'
    'r' => '\r'
    _ => c
  }
}

///|
fn parse_config_value(raw : String) -> String {
  let sb = StringBuilder::new()
  let mut in_single = false
  let mut in_double = false
  let mut escape = false
  let mut started = false
  let mut trailing_ws = 0
  for c in raw {
    if escape {
      sb.write_char(decode_config_escape(c))
      started = true
      trailing_ws = 0
      escape = false
      continue
    }
    if in_double {
      if c == '\\' {
        escape = true
        continue
      }
      if c == '"' {
        in_double = false
        started = true
        trailing_ws = 0
        continue
      }
      sb.write_char(c)
      started = true
      trailing_ws = 0
      continue
    }
    if in_single {
      if c == '\'' {
        in_single = false
        started = true
        trailing_ws = 0
        continue
      }
      sb.write_char(c)
      started = true
      trailing_ws = 0
      continue
    }
    if not(started) && is_horizontal_space(c) {
      continue
    }
    if c == '"' {
      in_double = true
      started = true
      continue
    }
    if c == '\'' {
      in_single = true
      started = true
      continue
    }
    if c == '\\' {
      escape = true
      started = true
      trailing_ws = 0
      continue
    }
    if c == '#' || c == ';' {
      if not(started) || trailing_ws > 0 {
        break
      }
    }
    sb.write_char(c)
    started = true
    if is_horizontal_space(c) {
      trailing_ws += 1
    } else {
      trailing_ws = 0
    }
  }
  let parsed = sb.to_string()
  if trailing_ws > 0 && parsed.length() >= trailing_ws {
    String::unsafe_substring(parsed, start=0, end=parsed.length() - trailing_ws)
  } else {
    parsed
  }
}

///|
fn set_config(
  fs : OsFs,
  config_path : String,
  key : String,
  value : String,
  add_mode : Bool,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return
  }
  let (section, subsection, name) = if parts.length() == 2 {
    (parts[0], (None : String?), parts[1])
  } else {
    let sub : Array[String] = []
    for i in 1..<(parts.length() - 1) {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")), parts[parts.length() - 1])
  }
  let section_l = section.to_lower()
  let subsection_l = subsection.map(sub => sub.to_lower())
  let name_l = name.to_lower()
  let section_header = match subsection {
    Some(sub) => "[\{section} \"\{sub}\"]"
    None => "[\{section}]"
  }
  let slash_parts : Array[String] = []
  for part in value.split("\\") {
    slash_parts.push(part.to_string())
  }
  let escaped_backslash = slash_parts.join("\\\\")
  let quote_parts : Array[String] = []
  for part in escaped_backslash.split("\"") {
    quote_parts.push(part.to_string())
  }
  let encoded_value = quote_parts.join("\\\"")
  if not(rfs.is_file(config_path)) {
    // Create new config file
    wfs.write_string(
      config_path,
      ensure_trailing_newline(
        section_header + "\n\t" + name + " = " + encoded_value + "\n",
      ),
    )
    return
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let lines : Array[String] = []
  for line_view in content.split("\n") {
    lines.push(line_view.to_string())
  }
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  let mut in_section = false
  let mut found = false
  let mut section_end = -1
  let result : Array[String] = []
  for i, line in lines {
    let trimmed = trim_string(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      if in_section && not(found) {
        // Insert at end of previous section
        result.push("\t" + name + " = " + encoded_value)
        found = true
      }
      let sec_content = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      let sec_content_l = sec_content.to_lower()
      match subsection {
        Some(_) => {
          let sub_l = subsection_l.unwrap_or("")
          let expected = section_l + " \"" + sub_l + "\""
          in_section = sec_content_l == expected ||
            sec_content_l == section_l + " " + sub_l
        }
        None => in_section = sec_content_l == section_l
      }
      if in_section {
        section_end = i
      }
      result.push(line)
      continue
    }
    if in_section && not(add_mode) {
      let eq_idx = trimmed.find("=")
      match eq_idx {
        Some(idx) => {
          let key_part = trim_chars(
            String::unsafe_substring(trimmed, start=0, end=idx),
            " \t",
          )
          if key_part.to_lower() == name_l {
            result.push("\t" + name + " = " + encoded_value)
            found = true
            continue
          }
        }
        None => ()
      }
      if trimmed.length() > 0 {
        section_end = i
      }
    }
    result.push(line)
  }
  if not(found) {
    if section_end >= 0 {
      // Insert after section header
      let new_result : Array[String] = []
      for i, line in result {
        new_result.push(line)
        if i == section_end && not(found) {
          new_result.push("\t" + name + " = " + encoded_value)
          found = true
        }
      }
      wfs.write_string(
        config_path,
        ensure_trailing_newline(new_result.join("\n")),
      )
      return
    }
    // Add new section at end
    result.push(section_header)
    result.push("\t" + name + " = " + encoded_value)
  }
  wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
}

///|
fn unset_config(
  fs : OsFs,
  config_path : String,
  key : String,
  fixed_value : String?,
  unset_all : Bool,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  if not(rfs.is_file(config_path)) {
    return
  }
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return
  }
  let (section, subsection, name) = if parts.length() == 2 {
    (parts[0], (None : String?), parts[1])
  } else {
    let sub : Array[String] = []
    for i in 1..<(parts.length() - 1) {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")), parts[parts.length() - 1])
  }
  let section_l = section.to_lower()
  let subsection_l = subsection.map(sub => sub.to_lower())
  let name_l = name.to_lower()
  let content = decode_bytes(rfs.read_file(config_path))
  let lines : Array[String] = []
  for line_view in content.split("\n") {
    lines.push(line_view.to_string())
  }
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  let mut in_section = false
  let mut removed = false
  let result : Array[String] = []
  for line in lines {
    let trimmed = trim_string(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      let sec_content = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      let sec_content_l = sec_content.to_lower()
      match subsection {
        Some(_) => {
          let sub_l = subsection_l.unwrap_or("")
          let expected = section_l + " \"" + sub_l + "\""
          in_section = sec_content_l == expected ||
            sec_content_l == section_l + " " + sub_l
        }
        None => in_section = sec_content_l == section_l
      }
      result.push(line)
      continue
    }
    if in_section {
      let eq_idx = trimmed.find("=")
      match eq_idx {
        Some(idx) => {
          let key_part = trim_chars(
            String::unsafe_substring(trimmed, start=0, end=idx),
            " \t",
          )
          if key_part.to_lower() == name_l {
            let value_part = trim_chars(
              String::unsafe_substring(
                trimmed,
                start=idx + 1,
                end=trimmed.length(),
              ),
              " \t",
            )
            if fixed_value is Some(fv) && value_part != fv {
              ()
            } else if unset_all {
              continue
            } else if not(removed) {
              removed = true
              continue
            }
          }
        }
        None => ()
      }
    }
    result.push(line)
  }
  wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
}

///|
fn remove_config_section_file(
  fs : OsFs,
  config_path : String,
  section_key : String,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  if not(rfs.is_file(config_path)) {
    return
  }
  let parts : Array[String] = []
  for p in section_key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() == 0 {
    return
  }
  let (section, subsection) = if parts.length() == 1 {
    (parts[0], (None : String?))
  } else {
    let sub : Array[String] = []
    for i in 1..<parts.length() {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")))
  }
  let section_l = section.to_lower()
  let subsection_l = subsection.map(sub => sub.to_lower())
  let content = decode_bytes(rfs.read_file(config_path))
  let lines : Array[String] = []
  for line_view in content.split("\n") {
    lines.push(line_view.to_string())
  }
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  let mut in_section = false
  let result : Array[String] = []
  for line in lines {
    let trimmed = trim_string(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      let sec_content = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      let sec_content_l = sec_content.to_lower()
      let matched = match subsection {
        Some(_) => {
          let sub_l = subsection_l.unwrap_or("")
          let expected = section_l + " \"" + sub_l + "\""
          sec_content_l == expected || sec_content_l == section_l + " " + sub_l
        }
        None => sec_content_l == section_l
      }
      in_section = matched
      if matched {
        continue
      }
      result.push(line)
      continue
    }
    if in_section {
      continue
    }
    result.push(line)
  }
  wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
}

///|
fn ensure_trailing_newline(content : String) -> String {
  if content.length() == 0 || content.has_suffix("\n") {
    content
  } else {
    content + "\n"
  }
}

///|
