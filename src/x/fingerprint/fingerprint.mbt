///|
pub(all) enum FingerprintMode {
  Fast
  GitCompat
} derive(Eq, Show)

///|
pub fn parse_fingerprint_mode(raw : String) -> FingerprintMode? {
  match raw {
    "fast" => Some(FingerprintMode::Fast)
    "git" | "git-compat" | "git_compat" => Some(FingerprintMode::GitCompat)
    _ => None
  }
}

///|
pub fn fingerprint_mode_name(mode : FingerprintMode) -> String {
  match mode {
    FingerprintMode::Fast => "fast"
    FingerprintMode::GitCompat => "git"
  }
}

///|
fn fingerprint_ignore_entry(
  name : String,
  ignore_entries : Array[String],
) -> Bool {
  for candidate in ignore_entries {
    if name == candidate {
      return true
    }
  }
  false
}

///|
fn collect_fast_hash_files(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
  ignore_entries : Array[String],
  out : Array[String],
) -> Unit {
  let dir_path = if rel.length() == 0 { root } else { root + "/" + rel }
  let entries = fs.readdir(dir_path) catch { _ => [] }
  entries.sort_by((a, b) => String::lexical_compare(a, b))
  for entry in entries {
    if fingerprint_ignore_entry(entry, ignore_entries) {
      continue
    }
    let child_rel = if rel.length() == 0 { entry } else { rel + "/" + entry }
    let child_path = root + "/" + child_rel
    if fs.is_dir(child_path) {
      collect_fast_hash_files(fs, root, child_rel, ignore_entries, out)
    } else if fs.is_file(child_path) {
      out.push(child_rel)
    }
  }
}

///|
pub fn fast_directory_fingerprint(
  fs : &@git.RepoFileSystem,
  root : String,
  ignore_entries? : Array[String] = [".", "..", ".git", ".bit"],
) -> String {
  if not(fs.is_dir(root)) {
    return @git.hash_blob_string("missing").to_hex()
  }
  let files : Array[String] = []
  collect_fast_hash_files(fs, root, "", ignore_entries, files)
  let buf = StringBuilder::new()
  for rel in files {
    let file_path = root + "/" + rel
    let content = fs.read_file(file_path) catch { _ => Bytes::from_array([]) }
    let file_hash = @git.sha1(content).to_hex()
    buf.write_string(rel)
    buf.write_string("\t")
    buf.write_string(file_hash)
    buf.write_string("\n")
  }
  @git.hash_blob_string(buf.to_string()).to_hex()
}

///|
fn fingerprint_path_ignored(
  rel_path : String,
  ignore_entries : Array[String],
) -> Bool {
  for entry in ignore_entries {
    if entry == "." || entry == ".." {
      continue
    }
    if rel_path == entry || rel_path.has_prefix(entry + "/") {
      return true
    }
  }
  false
}

///|
fn decode_bytes(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
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
fn resolve_git_dir(fs : &@git.RepoFileSystem, root : String) -> String {
  let git_path = root + "/.git"
  if fs.is_file(git_path) {
    let bytes = fs.read_file(git_path) catch { _ => return git_path }
    let text = decode_bytes(bytes)
    for line_view in text.split("\n") {
      let line = trim_string(line_view.to_string())
      if not(line.has_prefix("gitdir:")) {
        continue
      }
      let raw = trim_string(
        String::unsafe_substring(line, start=7, end=line.length()),
      )
      if raw.length() == 0 {
        return git_path
      }
      if raw.has_prefix("/") {
        return raw
      }
      return root + "/" + raw
    }
    git_path
  } else {
    git_path
  }
}

///|
fn split_first(path : String) -> (String, String?) {
  match path.find("/") {
    None => (path, None)
    Some(idx) => {
      let name = String::unsafe_substring(path, start=0, end=idx)
      let rest = String::unsafe_substring(
        path,
        start=idx + 1,
        end=path.length(),
      )
      (name, Some(rest))
    }
  }
}

///|
fn compare_strings_lexicographic(a : String, b : String) -> Int {
  let a_len = a.length()
  let b_len = b.length()
  let min_len = if a_len < b_len { a_len } else { b_len }
  for i in 0..<min_len {
    let a_char = a.unsafe_get(i).to_int()
    let b_char = b.unsafe_get(i).to_int()
    if a_char < b_char {
      return -1
    } else if a_char > b_char {
      return 1
    }
  }
  if a_len < b_len {
    -1
  } else if a_len > b_len {
    1
  } else {
    0
  }
}

///|
fn to_octal_string(value : Int) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = []
  let mut v = value
  while v > 0 {
    let d = v % 8
    digits.push((d + '0'.to_int()).unsafe_to_char())
    v = v / 8
  }
  let rev = digits.rev()
  let sb = StringBuilder::new()
  for c in rev {
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn mode_to_string(mode : Int) -> String {
  if mode == 33188 {
    "100644"
  } else {
    to_octal_string(mode)
  }
}

///|
fn tree_id_from_entries(entries : Array[@gitlib.IndexEntry]) -> @git.ObjectId {
  if entries.length() == 0 {
    return @git.create_tree([]).0
  }
  let file_entries : Array[@git.TreeEntry] = []
  let dir_map : Map[String, Array[@gitlib.IndexEntry]] = {}
  for e in entries {
    match split_first(e.path) {
      (name, None) => {
        let mode = mode_to_string(e.mode)
        file_entries.push(@git.TreeEntry::new(mode, name, e.id))
      }
      (name, Some(rest)) =>
        match dir_map.get(name) {
          Some(list) =>
            list.push(
              @gitlib.IndexEntry::new(
                rest,
                e.id,
                e.mode,
                e.size,
                mtime_sec=e.mtime_sec,
                mtime_nsec=e.mtime_nsec,
              ),
            )
          None =>
            dir_map[name] = [
              @gitlib.IndexEntry::new(
                rest,
                e.id,
                e.mode,
                e.size,
                mtime_sec=e.mtime_sec,
                mtime_nsec=e.mtime_nsec,
              ),
            ]
        }
    }
  }
  for item in dir_map.to_array() {
    let (dir_name, list) = item
    let sub_id = tree_id_from_entries(list)
    file_entries.push(@git.TreeEntry::new("40000", dir_name, sub_id))
  }
  file_entries.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    compare_strings_lexicographic(a_key, b_key)
  })
  @git.create_tree(file_entries).0
}

///|
fn index_entries_after_add_all(
  fs : &@git.RepoFileSystem,
  root : String,
  ignore_entries : Array[String],
) -> Array[@gitlib.IndexEntry] {
  let git_dir = resolve_git_dir(fs, root)
  let existing = @gitlib.read_index_entries(fs, git_dir) catch { _ => [] }
  let staged : Map[String, @gitlib.IndexEntry] = {}
  for e in existing {
    if fingerprint_path_ignored(e.path, ignore_entries) {
      continue
    }
    staged[e.path] = e
  }
  let working_files = @gitignore.list_working_files(fs, root) catch { _ => [] }
  let present : Map[String, Bool] = {}
  for rel in working_files {
    if fingerprint_path_ignored(rel, ignore_entries) {
      continue
    }
    let abs = root + "/" + rel
    if fs.is_file(abs) {
      let content = fs.read_file(abs) catch { _ => Bytes::from_array([]) }
      let id = @git.hash_blob(content)
      let mode = staged.get(rel).map(e => e.mode).unwrap_or(33188)
      staged[rel] = @gitlib.IndexEntry::new(rel, id, mode, content.length())
      present[rel] = true
    }
  }
  let removed_paths : Array[String] = []
  for path, _ in staged {
    if present.get(path) is None {
      removed_paths.push(path)
    }
  }
  for path in removed_paths {
    staged.remove(path)
  }
  let out : Array[@gitlib.IndexEntry] = []
  for _, entry in staged {
    out.push(entry)
  }
  out
}

///|
pub fn git_compat_directory_fingerprint(
  fs : &@git.RepoFileSystem,
  root : String,
  ignore_entries? : Array[String] = [".", "..", ".git", ".bit"],
) -> String {
  if not(fs.is_dir(root)) {
    return @git.hash_blob_string("missing").to_hex()
  }
  let entries = index_entries_after_add_all(fs, root, ignore_entries)
  tree_id_from_entries(entries).to_hex()
}

///|
pub fn directory_fingerprint(
  fs : &@git.RepoFileSystem,
  root : String,
  mode : FingerprintMode,
  ignore_entries? : Array[String] = [".", "..", ".git", ".bit"],
) -> String {
  match mode {
    FingerprintMode::Fast =>
      fast_directory_fingerprint(fs, root, ignore_entries~)
    FingerprintMode::GitCompat =>
      git_compat_directory_fingerprint(fs, root, ignore_entries~)
  }
}
