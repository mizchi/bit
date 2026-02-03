///| Ref storage helpers (loose/packed refs)

///|
fn decode_bytes_lossy_refs(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn trim_string_refs(s : String) -> String {
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
pub fn collect_loose_ref_ids(
  fs : &@git.RepoFileSystem,
  dir : String,
  prefix : String,
  out : Map[String, @git.ObjectId],
  filter_prefix : String?,
) -> Unit {
  if not(fs.is_dir(dir)) {
    return ()
  }
  let entries = fs.readdir(dir) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let path = dir + "/" + entry
    let name = if prefix.length() == 0 { entry } else { prefix + "/" + entry }
    if fs.is_dir(path) {
      collect_loose_ref_ids(fs, path, name, out, filter_prefix)
    } else if fs.is_file(path) {
      if filter_prefix is Some(pfx) && not(name.has_prefix(pfx)) {
        continue
      }
      let content = decode_bytes_lossy_refs(fs.read_file(path) catch { _ => continue })
      let hex = trim_string_refs(content)
      if hex.length() == 0 {
        continue
      }
      let id = @git.ObjectId::from_hex(hex) catch { _ => continue }
      out[name] = id
    }
  }
}

///|
pub fn collect_packed_ref_ids(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  out : Map[String, @git.ObjectId],
  filter_prefix : String?,
) -> Unit {
  let packed_path = git_dir + "/packed-refs"
  if not(fs.is_file(packed_path)) {
    return ()
  }
  let packed = fs.read_file(packed_path) catch { _ => Bytes::default() }
  let text = @utf8.decode_lossy(packed[:])
  for line_view in text.split("\n") {
    let line = trim_string_refs(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if filter_prefix is Some(pfx) && not(refname.has_prefix(pfx)) {
          continue
        }
        if out.contains(refname) {
          continue
        }
        let id = @git.ObjectId::from_hex(id_hex) catch { _ => continue }
        out[refname] = id
      }
    }
  }
}

///|
pub fn list_refs_with_ids(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  filter_prefix : String?,
) -> Map[String, @git.ObjectId] {
  let out : Map[String, @git.ObjectId] = {}
  let refs_dir = git_dir + "/refs"
  collect_loose_ref_ids(fs, refs_dir, "refs", out, filter_prefix)
  collect_packed_ref_ids(fs, git_dir, out, filter_prefix)
  out
}

///|
pub fn rewrite_packed_refs(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  transform : (String) -> String?,
) -> Unit raise @git.GitError {
  let packed_path = git_dir + "/packed-refs"
  if not(rfs.is_file(packed_path)) {
    return ()
  }
  let data = rfs.read_file(packed_path) catch { _ => Bytes::default() }
  let text = @utf8.decode_lossy(data[:])
  let lines : Array[String] = []
  let mut skip_peeled = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") {
      lines.push(line)
      skip_peeled = false
      continue
    }
    if line.has_prefix("^") {
      if not(skip_peeled) {
        lines.push(line)
      }
      continue
    }
    let space = line.find(" ")
    match space {
      None => {
        lines.push(line)
        skip_peeled = false
      }
      Some(idx) => {
        if idx + 1 >= line.length() {
          lines.push(line)
          skip_peeled = false
          continue
        }
        let oid = String::unsafe_substring(line, start=0, end=idx)
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match transform(refname) {
          Some(new_ref) => {
            lines.push(oid + " " + new_ref)
            skip_peeled = false
          }
          None => {
            skip_peeled = true
          }
        }
      }
    }
  }
  if lines.length() == 0 {
    fs.remove_file(packed_path) catch {
      _ => ()
    }
  } else {
    fs.write_string(packed_path, lines.join("\n") + "\n")
  }
}

///|
pub fn remove_packed_ref(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Unit raise @git.GitError {
  rewrite_packed_refs(
    fs,
    rfs,
    git_dir,
    fn(name) { if name == refname { None } else { Some(name) } },
  )
}

///|
pub fn remove_packed_refs_with_prefix(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  prefix : String,
  exact : String,
) -> Unit raise @git.GitError {
  rewrite_packed_refs(
    fs,
    rfs,
    git_dir,
    fn(name) {
      if name == exact || name.has_prefix(prefix) {
        None
      } else {
        Some(name)
      }
    },
  )
}

///|
pub fn rename_packed_refs_prefix(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  old_prefix : String,
  new_prefix : String,
  old_exact : String,
  new_exact : String,
) -> Unit raise @git.GitError {
  rewrite_packed_refs(
    fs,
    rfs,
    git_dir,
    fn(name) {
      if name == old_exact {
        Some(new_exact)
      } else if name.has_prefix(old_prefix) {
        let suffix = String::unsafe_substring(
          name,
          start=old_prefix.length(),
          end=name.length(),
        )
        Some(new_prefix + suffix)
      } else {
        Some(name)
      }
    },
  )
}

///|
pub fn list_remote_tracking_refs(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  remote_name : String,
) -> Map[String, @git.ObjectId] {
  let prefix = "refs/remotes/" + remote_name + "/"
  let refs = list_refs_with_ids(fs, git_dir, Some(prefix))
  let out : Map[String, @git.ObjectId] = {}
  for refname, id in refs {
    if not(refname.has_prefix(prefix)) {
      continue
    }
    let name = String::unsafe_substring(
      refname,
      start=prefix.length(),
      end=refname.length(),
    )
    if name.length() == 0 || name == "HEAD" {
      continue
    }
    out[name] = id
  }
  out
}

///|
pub fn remove_remote_refs(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit {
  let refs_dir = git_dir + "/refs/remotes/" + name
  if rfs.is_dir(refs_dir) || rfs.is_file(refs_dir) {
    remove_tree_internal(fs, rfs, refs_dir)
  }
  let logs_dir = git_dir + "/logs/refs/remotes/" + name
  if rfs.is_dir(logs_dir) || rfs.is_file(logs_dir) {
    remove_tree_internal(fs, rfs, logs_dir)
  }
}

///|
fn remove_tree_internal(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  path : String,
) -> Unit {
  if rfs.is_dir(path) {
    let entries = rfs.readdir(path) catch { _ => [] }
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      remove_tree_internal(fs, rfs, path + "/" + entry)
    }
    fs.remove_dir(path) catch {
      _ => ()
    }
    return ()
  }
  if rfs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
  }
}
