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
fn build_git_tree_id(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
  ignore_entries : Array[String],
) -> @git.ObjectId? {
  let dir_path = if rel.length() == 0 { root } else { root + "/" + rel }
  let names = fs.readdir(dir_path) catch { _ => [] }
  names.sort_by((a, b) => String::lexical_compare(a, b))
  let entries : Array[@git.TreeEntry] = []
  for name in names {
    if fingerprint_ignore_entry(name, ignore_entries) {
      continue
    }
    let child_rel = if rel.length() == 0 { name } else { rel + "/" + name }
    let child_path = root + "/" + child_rel
    if fs.is_dir(child_path) {
      match build_git_tree_id(fs, root, child_rel, ignore_entries) {
        Some(subtree_id) =>
          entries.push(@git.TreeEntry::new("40000", name, subtree_id))
        None => ()
      }
    } else if fs.is_file(child_path) {
      let content = fs.read_file(child_path) catch {
        _ => Bytes::from_array([])
      }
      let blob_id = @git.hash_blob(content)
      entries.push(@git.TreeEntry::new("100644", name, blob_id))
    }
  }
  if entries.length() == 0 {
    None
  } else {
    Some(@git.create_tree(entries).0)
  }
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
  match build_git_tree_id(fs, root, "", ignore_entries) {
    Some(tree_id) => tree_id.to_hex()
    None => @git.create_tree([]).0.to_hex()
  }
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
