///| Remote config parsing helpers

///|
pub(all) struct RemoteConfig {
  mut urls : Array[String]
  mut pushurls : Array[String]
  mut fetch : Array[String]
  mut push : Array[String]
  mut promisor : Bool
  mut partial_clone_filter : String?
  mut mirror : Bool
  mut tagopt : String?
}

///|
pub(all) struct BranchConfig {
  name : String
  mut remote : String?
  mut merges : Array[String]
  mut rebase : Bool?
}

///|
pub(all) struct FetchRefspec {
  negative : Bool
  src : String
  dst : String
}

///|
pub(all) struct PushRefspec {
  force : Bool
  src : String
  dst : String
}

///|
pub(all) struct ConfigBlock {
  mut header : String?
  mut section : String?
  mut name : String?
  mut lines : Array[String]
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
pub fn config_strip_quotes(s : String) -> String {
  let t = s.trim().to_string()
  if t.length() >= 2 && t.has_prefix("\"") && t.has_suffix("\"") {
    String::unsafe_substring(t, start=1, end=t.length() - 1)
  } else {
    t
  }
}

///|
pub fn parse_section_header(line : String) -> (String, String?) {
  let body = String::unsafe_substring(line, start=1, end=line.length() - 1)
  match body.find(" ") {
    Some(idx) => {
      let sec = String::unsafe_substring(body, start=0, end=idx).to_lower()
      let name_part = String::unsafe_substring(
        body,
        start=idx + 1,
        end=body.length(),
      )
      (sec, name_part |> config_strip_quotes |> Some)
    }
    None => (body.to_lower(), None)
  }
}

///|
pub fn parse_config_kv(line : String) -> (String, String)? {
  let trimmed = trim_string_internal(line)
  if trimmed.length() == 0 || trimmed.has_prefix("#") || trimmed.has_prefix(";") {
    return None
  }
  match trimmed.find("=") {
    Some(eq_idx) => {
      let key = trim_string_internal(
        String::unsafe_substring(trimmed, start=0, end=eq_idx),
      ).to_lower()
      let value = trim_string_internal(
        String::unsafe_substring(
          trimmed,
          start=eq_idx + 1,
          end=trimmed.length(),
        ),
      )
      Some((key, value))
    }
    None => None
  }
}

///|
pub fn parse_config_blocks(content : String) -> Array[ConfigBlock] {
  let blocks : Array[ConfigBlock] = []
  let current : ConfigBlock = {
    header: None,
    section: None,
    name: None,
    lines: [],
  }
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_string_internal(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      if current.header is Some(_) || current.lines.length() > 0 {
        let copied_lines : Array[String] = []
        for item in current.lines {
          copied_lines.push(item)
        }
        blocks.push({
          header: current.header,
          section: current.section,
          name: current.name,
          lines: copied_lines,
        })
      }
      let (section, name) = parse_section_header(trimmed)
      current.header = Some(trimmed)
      current.section = Some(section)
      current.name = name
      current.lines = []
      continue
    }
    current.lines.push(line)
  }
  if current.header is Some(_) || current.lines.length() > 0 {
    let copied_lines : Array[String] = []
    for item in current.lines {
      copied_lines.push(item)
    }
    blocks.push({
      header: current.header,
      section: current.section,
      name: current.name,
      lines: copied_lines,
    })
  }
  blocks
}

///|
pub fn render_config_blocks(blocks : Array[ConfigBlock]) -> String {
  let lines : Array[String] = []
  for block in blocks {
    if block.header is Some(h) {
      lines.push(h)
    }
    for line in block.lines {
      lines.push(line)
    }
  }
  let mut content = lines.join("\n")
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  content
}

///|
pub fn config_has_remote_section(
  blocks : Array[ConfigBlock],
  name : String,
) -> Bool {
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      return true
    }
  }
  false
}

///|
pub fn parse_remote_config(
  content : String,
) -> (Map[String, RemoteConfig], Map[String, BranchConfig]) {
  let remotes : Map[String, RemoteConfig] = {}
  let branches : Map[String, BranchConfig] = {}
  let mut current_section : String? = None
  let mut current_name : String? = None
  for line_view in content.split("\n") {
    let line = trim_string_internal(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let body = String::unsafe_substring(line, start=1, end=line.length() - 1)
      match body.find(" ") {
        Some(idx) => {
          let sec = String::unsafe_substring(body, start=0, end=idx).to_lower()
          let name_part = String::unsafe_substring(
            body,
            start=idx + 1,
            end=body.length(),
          )
          let name = config_strip_quotes(name_part)
          current_section = Some(sec)
          current_name = Some(name)
        }
        None => {
          current_section = Some(body.to_lower())
          current_name = None
        }
      }
      continue
    }
    match line.find("=") {
      Some(eq_idx) => {
        let key = trim_string_internal(
          String::unsafe_substring(line, start=0, end=eq_idx),
        ).to_lower()
        let value = trim_string_internal(
          String::unsafe_substring(line, start=eq_idx + 1, end=line.length()),
        )
        match (current_section, current_name) {
          (Some("remote"), Some(name)) => {
            let rc = remotes
              .get(name)
              .unwrap_or({
                urls: [],
                pushurls: [],
                fetch: [],
                push: [],
                promisor: false,
                partial_clone_filter: None,
                mirror: false,
                tagopt: None,
              })
            match key {
              "url" => rc.urls.push(value)
              "pushurl" => rc.pushurls.push(value)
              "fetch" => rc.fetch.push(value)
              "push" => rc.push.push(value)
              "promisor" => {
                let v = value.to_lower()
                rc.promisor = v == "true" || v == "1" || v == "yes"
              }
              "partialclonefilter" => rc.partial_clone_filter = Some(value)
              "mirror" => {
                let v = value.to_lower()
                rc.mirror = v == "true" || v == "1" || v == "yes"
              }
              "tagopt" => rc.tagopt = Some(value)
              _ => ()
            }
            remotes[name] = rc
          }
          (Some("branch"), Some(name)) => {
            let bc = branches
              .get(name)
              .unwrap_or({ name, remote: None, merges: [], rebase: None })
            match key {
              "remote" => bc.remote = Some(value)
              "merge" => {
                let parts = value.split(" ").collect()
                for p_view in parts {
                  let p = p_view.to_string().trim().to_string()
                  if p.length() > 0 {
                    bc.merges.push(p)
                  }
                }
              }
              "rebase" => {
                let v = value.to_lower()
                if v == "true" || v == "1" || v == "yes" {
                  bc.rebase = Some(true)
                } else if v == "false" || v == "0" || v == "no" {
                  bc.rebase = Some(false)
                }
              }
              _ => ()
            }
            branches[name] = bc
          }
          _ => ()
        }
      }
      None => ()
    }
  }
  (remotes, branches)
}

///|
pub fn split_config_key(
  full_key : String,
  section : String,
) -> (String, String)? {
  let prefix = section + "."
  if not(full_key.has_prefix(prefix)) {
    return None
  }
  let rest = String::unsafe_substring(
    full_key,
    start=prefix.length(),
    end=full_key.length(),
  )
  match rest.rev_find(".") {
    None => None
    Some(idx) => {
      let name = String::unsafe_substring(rest, start=0, end=idx)
      let key = String::unsafe_substring(rest, start=idx + 1, end=rest.length())
      Some((name, key))
    }
  }
}

///|
pub fn parse_config_override_pairs() -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let overrides = @gitio.env_get("GIT_CONFIG_OVERRIDES")
  guard overrides is Some(env_value) else { return out }
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
        out.push((key, value))
      }
      None => out.push((line.to_lower(), ""))
    }
  }
  out
}

///|
pub fn apply_config_overrides(
  remotes : Map[String, RemoteConfig],
  branches : Map[String, BranchConfig],
  overrides : Array[(String, String)],
) -> Unit {
  for pair in overrides {
    let (raw_key, value) = pair
    let mut handled = false
    match split_config_key(raw_key, "remote") {
      Some((name, key)) => {
        let rc = remotes
          .get(name)
          .unwrap_or({
            urls: [],
            pushurls: [],
            fetch: [],
            push: [],
            promisor: false,
            partial_clone_filter: None,
            mirror: false,
            tagopt: None,
          })
        match key {
          "url" =>
            if value.length() == 0 {
              rc.urls = []
            } else {
              rc.urls.push(value)
            }
          "pushurl" =>
            if value.length() == 0 {
              rc.pushurls = []
            } else {
              rc.pushurls.push(value)
            }
          "fetch" =>
            if value.length() == 0 {
              rc.fetch = []
            } else {
              rc.fetch.push(value)
            }
          "push" =>
            if value.length() == 0 {
              rc.push = []
            } else {
              rc.push.push(value)
            }
          "promisor" =>
            if value.length() > 0 {
              let v = value.to_lower()
              rc.promisor = v == "true" || v == "1" || v == "yes"
            }
          "partialclonefilter" =>
            rc.partial_clone_filter = if value.length() == 0 {
              None
            } else {
              Some(value)
            }
          "mirror" =>
            if value.length() > 0 {
              let v = value.to_lower()
              rc.mirror = v == "true" || v == "1" || v == "yes"
            }
          "tagopt" =>
            rc.tagopt = if value.length() == 0 { None } else { Some(value) }
          _ => ()
        }
        remotes[name] = rc
        handled = true
      }
      None => ()
    }
    if handled {
      continue
    }
    match split_config_key(raw_key, "branch") {
      Some((name, key)) => {
        let bc = branches
          .get(name)
          .unwrap_or({ name, remote: None, merges: [], rebase: None })
        match key {
          "remote" =>
            bc.remote = if value.length() == 0 { None } else { Some(value) }
          "merge" =>
            if value.length() == 0 {
              bc.merges = []
            } else {
              bc.merges.push(value)
            }
          "rebase" =>
            if value.length() > 0 {
              let v = value.to_lower()
              if v == "true" || v == "1" || v == "yes" {
                bc.rebase = Some(true)
              } else if v == "false" || v == "0" || v == "no" {
                bc.rebase = Some(false)
              }
            }
          _ => ()
        }
        branches[name] = bc
      }
      None => ()
    }
  }
}

///|
pub fn read_repo_config(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> (Map[String, RemoteConfig], Map[String, BranchConfig]) {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return ({}, {})
  }
  let content = decode_bytes_lossy(
    fs.read_file(config_path) catch {
      _ => return ({}, {})
    },
  )
  let (remotes, branches) = parse_remote_config(content)
  let overrides = parse_config_override_pairs()
  if overrides.length() > 0 {
    apply_config_overrides(remotes, branches, overrides)
  }
  (remotes, branches)
}

///|
pub fn list_remotes(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] {
  let (remotes, _) = read_repo_config(fs, git_dir)
  let out : Array[String] = []
  for name, _ in remotes {
    out.push(name)
  }
  out.sort()
  out
}

///|
pub fn list_remotes_verbose(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[(String, String)] {
  let (remotes, _) = read_repo_config(fs, git_dir)
  let out : Array[(String, String)] = []
  let names = list_remotes(fs, git_dir)
  for name in names {
    match remotes.get(name) {
      Some(rc) => {
        if rc.urls.length() == 0 {
          continue
        }
        let url = rc.urls[0]
        let filter = if rc.promisor && rc.partial_clone_filter is Some(f) {
          " [" + f + "]"
        } else {
          ""
        }
        out.push((name, url + " (fetch)" + filter))
        let push_urls = if rc.pushurls.length() > 0 {
          rc.pushurls
        } else {
          rc.urls
        }
        for pu in push_urls {
          out.push((name, pu + " (push)"))
        }
      }
      None => ()
    }
  }
  out
}

///|
pub fn get_remote_url(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> String? {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes_lossy(
    fs.read_file(config_path) catch {
      _ => return None
    },
  )
  let target_section = "[remote \"\{name}\"]"
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = trim_string_internal(line_view.to_string())
    if line == target_section {
      in_section = true
      continue
    }
    if line.has_prefix("[") {
      in_section = false
      continue
    }
    if in_section && line.has_prefix("url = ") {
      return Some(String::unsafe_substring(line, start=6, end=line.length()))
    }
  }
  None
}

///|
pub fn parse_refspec_pair(spec : String) -> (String, String) {
  match spec.find(":") {
    Some(idx) => {
      let src = if idx == 0 {
        ""
      } else {
        String::unsafe_substring(spec, start=0, end=idx)
      }
      let dst = if idx + 1 >= spec.length() {
        ""
      } else {
        String::unsafe_substring(spec, start=idx + 1, end=spec.length())
      }
      (src, dst)
    }
    None => (spec, spec)
  }
}

///|
pub fn parse_fetch_refspecs(specs : Array[String]) -> Array[FetchRefspec] {
  let out : Array[FetchRefspec] = []
  for raw in specs {
    let mut negative = false
    let mut s = raw
    if s.has_prefix("^") {
      negative = true
      s = String::unsafe_substring(s, start=1, end=s.length())
    }
    if s.has_prefix("+") {
      s = String::unsafe_substring(s, start=1, end=s.length())
    }
    let (src, dst) = parse_refspec_pair(s)
    out.push({ negative, src, dst })
  }
  out
}

///|
pub fn parse_push_refspecs(specs : Array[String]) -> Array[PushRefspec] {
  let out : Array[PushRefspec] = []
  for raw in specs {
    let mut force = false
    let mut s = raw
    if s.has_prefix("+") {
      force = true
      s = String::unsafe_substring(s, start=1, end=s.length())
    }
    let (src, dst) = parse_refspec_pair(s)
    out.push({ force, src, dst })
  }
  out
}

///|
pub fn normalize_track_ref(track : String) -> String {
  if track.has_prefix("refs/") {
    return track
  }
  if track.has_prefix("heads/") {
    return "refs/heads/" +
      String::unsafe_substring(track, start=6, end=track.length())
  }
  "refs/heads/" + track
}

///|
pub fn refspec_capture(pattern : String, refname : String) -> String? {
  match pattern.find("*") {
    None => if pattern == refname { Some("") } else { None }
    Some(idx) => {
      let prefix = String::unsafe_substring(pattern, start=0, end=idx)
      let suffix = String::unsafe_substring(
        pattern,
        start=idx + 1,
        end=pattern.length(),
      )
      if refname.has_prefix(prefix) &&
        refname.has_suffix(suffix) &&
        refname.length() >= prefix.length() + suffix.length() {
        let mid = String::unsafe_substring(
          refname,
          start=prefix.length(),
          end=refname.length() - suffix.length(),
        )
        Some(mid)
      } else {
        None
      }
    }
  }
}

///|
pub fn refspec_map_dst(
  src_pat : String,
  dst_pat : String,
  refname : String,
) -> String? {
  match refspec_capture(src_pat, refname) {
    Some(mid) =>
      if dst_pat.find("*") is Some(idx) {
        let prefix = String::unsafe_substring(dst_pat, start=0, end=idx)
        let suffix = String::unsafe_substring(
          dst_pat,
          start=idx + 1,
          end=dst_pat.length(),
        )
        Some(prefix + mid + suffix)
      } else {
        Some(dst_pat)
      }
    None => None
  }
}

///|
pub fn update_fetch_refspec(
  spec : String,
  old_name : String,
  new_name : String,
) -> String {
  let mut prefix = ""
  let mut body = spec
  if body.has_prefix("^") {
    prefix = prefix + "^"
    body = String::unsafe_substring(body, start=1, end=body.length())
  }
  if body.has_prefix("+") {
    prefix = prefix + "+"
    body = String::unsafe_substring(body, start=1, end=body.length())
  }
  let has_colon = body.find(":") is Some(_)
  let (src, dst) = parse_refspec_pair(body)
  let old_prefix = "refs/remotes/" + old_name + "/"
  if dst.has_prefix(old_prefix) {
    let suffix = String::unsafe_substring(
      dst,
      start=old_prefix.length(),
      end=dst.length(),
    )
    let new_dst = "refs/remotes/" + new_name + "/" + suffix
    let new_body = if has_colon { src + ":" + new_dst } else { new_dst }
    prefix + new_body
  } else {
    spec
  }
}

///|
pub fn normalize_remote_branch_name(refname : String) -> String {
  if refname.has_prefix("refs/heads/") {
    String::unsafe_substring(refname, start=11, end=refname.length())
  } else {
    refname
  }
}

///|
pub fn is_mirror_fetch_config(rc : RemoteConfig) -> Bool {
  for raw in rc.fetch {
    let mut spec = raw
    if spec.has_prefix("^") {
      spec = String::unsafe_substring(spec, start=1, end=spec.length())
    }
    if spec.has_prefix("+") {
      spec = String::unsafe_substring(spec, start=1, end=spec.length())
    }
    let (_src, dst) = parse_refspec_pair(spec)
    if dst == "refs/*" {
      return true
    }
    if dst.has_prefix("refs/") && not(dst.has_prefix("refs/remotes/")) {
      return true
    }
  }
  false
}

///|
pub fn remote_set_branches(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  branches : Array[String],
  add : Bool,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  if not(rfs.is_file(config_path)) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let content = decode_bytes_lossy(rfs.read_file(config_path))
  let (remotes, _) = parse_remote_config(content)
  let rc = match remotes.get(name) {
    Some(cfg) => cfg
    None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let mirror_fetch = is_mirror_fetch_config(rc)
  let updated_specs : Array[String] = []
  if add {
    for spec in rc.fetch {
      updated_specs.push(spec)
    }
  }
  for branch in branches {
    let src_ref = normalize_track_ref(branch)
    let short = normalize_remote_branch_name(src_ref)
    let dst_ref = if mirror_fetch {
      src_ref
    } else {
      "refs/remotes/" + name + "/" + short
    }
    let spec = "+" + src_ref + ":" + dst_ref
    let mut exists = false
    for existing in updated_specs {
      if existing == spec {
        exists = true
        break
      }
    }
    if not(exists) {
      updated_specs.push(spec)
    }
  }
  let blocks = parse_config_blocks(content)
  let new_blocks : Array[ConfigBlock] = []
  let mut found = false
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      found = true
      let updated = block
      let other_lines : Array[String] = []
      for line in updated.lines {
        match parse_config_kv(line) {
          Some((key, _)) if key == "fetch" => ()
          _ => other_lines.push(line)
        }
      }
      let final_lines : Array[String] = []
      for line in other_lines {
        final_lines.push(line)
      }
      for spec in updated_specs {
        final_lines.push("\tfetch = " + spec)
      }
      updated.lines = final_lines
      new_blocks.push(updated)
    } else {
      new_blocks.push(block)
    }
  }
  if not(found) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  fs.write_string(config_path, render_config_blocks(new_blocks))
}

///|
pub fn set_config_key(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  section : String,
  name : String,
  key : String,
  value : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  let target_section = "[\{section} \"\{name}\"]"
  let content = if rfs.is_file(config_path) {
    decode_bytes_lossy(rfs.read_file(config_path))
  } else {
    ""
  }
  let lines : Array[String] = []
  let mut in_section = false
  let mut found_section = false
  let mut key_set = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_string_internal(line)
    if trimmed == target_section {
      in_section = true
      found_section = true
      lines.push(line)
      continue
    }
    if in_section && trimmed.has_prefix("[") {
      if not(key_set) {
        lines.push("\t\{key} = \{value}")
        key_set = true
      }
      in_section = false
    }
    if in_section && trimmed.has_prefix("\{key} = ") {
      lines.push("\t\{key} = \{value}")
      key_set = true
      continue
    }
    lines.push(line)
  }
  if found_section {
    if in_section && not(key_set) {
      lines.push("\t\{key} = \{value}")
    }
  } else {
    if lines.length() > 0 &&
      trim_string_internal(lines[lines.length() - 1]) != "" {
      lines.push("")
    }
    lines.push(target_section)
    lines.push("\t\{key} = \{value}")
  }
  let new_content = lines
    .iter()
    .fold(init="", fn(acc, line) {
      if acc == "" {
        line
      } else {
        acc + "\n" + line
      }
    })
  fs.write_string(config_path, new_content)
}
