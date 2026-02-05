///|
fn parse_object_id_hex(text : String) -> @git.ObjectId? {
  let parsed : Result[@git.ObjectId, Error] = try? @git.ObjectId::from_hex(text)
  match parsed {
    Ok(id) => Some(id)
    Err(_) => None
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
    if not(is_hex_char(c)) {
      return false
    }
  }
  true
}

///|
fn lower_hex_string(s : String) -> String {
  let out = StringBuilder::new()
  for c in s {
    if c >= 'A' && c <= 'F' {
      out.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Resolve refspec (branch, tag, HEAD, or hash) into commit id and optional branch name.
pub async fn resolve_remote_ref_id(
  remote_url : String,
  ref_spec : String,
) -> (@git.ObjectId, String?)? raise @git.GitError {
  match parse_object_id_hex(ref_spec) {
    Some(id) => return Some((id, None))
    None => ()
  }
  let (refs, _caps, _version, symrefs) = @gitnative.discover_upload_refs_http(
    remote_url, true,
  )
  if is_hex_string(ref_spec) && ref_spec.length() >= 4 {
    let needle = lower_hex_string(ref_spec)
    let matches : Array[@git.ObjectId] = []
    for item in refs {
      let (id, _name) = item
      if id.to_hex().has_prefix(needle) {
        matches.push(id)
      }
    }
    if matches.length() == 1 {
      return Some((matches[0], None))
    }
    if matches.length() > 1 {
      raise @git.GitError::InvalidObject("short hash is ambiguous: " + ref_spec)
    }
  }
  if ref_spec == "HEAD" {
    match @git.select_default_ref(refs, symrefs) {
      Some((refname, id)) =>
        if refname.has_prefix("refs/heads/") {
          let branch = String::unsafe_substring(
            refname,
            start=11,
            end=refname.length(),
          )
          return Some((id, Some(branch)))
        } else {
          return Some((id, None))
        }
      None => return None
    }
  }
  let candidates : Array[String] = []
  if ref_spec.has_prefix("refs/") {
    candidates.push(ref_spec)
  } else {
    candidates.push("refs/heads/" + ref_spec)
    candidates.push("refs/tags/" + ref_spec)
    candidates.push(ref_spec)
  }
  for cand in candidates {
    for item in refs {
      let (id, name) = item
      if name == cand {
        if name.has_prefix("refs/heads/") {
          let branch = String::unsafe_substring(
            name,
            start=11,
            end=name.length(),
          )
          return Some((id, Some(branch)))
        }
        return Some((id, None))
      }
    }
  }
  None
}
