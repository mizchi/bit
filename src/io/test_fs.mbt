///| Test filesystem for git tests (in-memory)

///|
pub struct TestFs {
  files : Map[String, Bytes]
  dirs : Map[String, Bool]
}

///|
pub fn TestFs::new() -> TestFs {
  let fs : TestFs = { files: {}, dirs: {} }
  fs.dirs.set("/", true)
  fs
}

///|
pub fn TestFs::exists(self : TestFs, path : String) -> Bool {
  self.files.contains(path) || self.dirs.contains(path)
}

///|
pub fn TestFs::read_file(
  self : TestFs,
  path : String,
) -> Bytes raise @types.GitError {
  match self.files.get(path) {
    Some(data) => data
    None => raise @types.GitError::IoError("File not found: \{path}")
  }
}

///|
pub fn TestFs::read_string(
  self : TestFs,
  path : String,
) -> String raise @types.GitError {
  let data = self.read_file(path)
  @utf8.decode_lossy(data[:])
}

///|
pub fn TestFs::mkdir_p(self : TestFs, path : String) -> Unit {
  if path.length() == 0 {
    return
  }
  TestFs::ensure_dirs(self, path)
}

///|
pub fn TestFs::write_file(
  self : TestFs,
  path : String,
  content : Bytes,
) -> Unit {
  let parent = testfs_parent_dir(path)
  TestFs::ensure_dirs(self, parent)
  self.files.set(path, content)
}

///|
pub fn TestFs::write_string(
  self : TestFs,
  path : String,
  content : String,
) -> Unit {
  self.write_file(path, string_to_bytes(content))
}

///|
pub fn TestFs::remove_file(
  self : TestFs,
  path : String,
) -> Unit raise @types.GitError {
  if self.files.contains(path) {
    self.files.remove(path)
    return
  }
  raise @types.GitError::IoError("File not found: \{path}")
}

///|
pub fn TestFs::remove_dir(
  self : TestFs,
  path : String,
) -> Unit raise @types.GitError {
  if not(self.dirs.contains(path)) {
    raise @types.GitError::IoError("Directory not found: \{path}")
  }
  // Check if directory is empty
  let children = self.readdir(path)
  if children.length() > 0 {
    raise @types.GitError::IoError("Directory not empty: \{path}")
  }
  self.dirs.remove(path)
}

///|
pub fn TestFs::readdir(
  self : TestFs,
  path : String,
) -> Array[String] raise @types.GitError {
  if not(self.dirs.contains(path)) {
    raise @types.GitError::IoError("Directory not found: \{path}")
  }
  let entries : Map[String, Bool] = {}
  for item in self.files.to_array() {
    let (file_path, _) = item
    if testfs_parent_dir(file_path) == path {
      entries[testfs_base_name(file_path)] = true
    }
  }
  for item in self.dirs.to_array() {
    let (dir_path, _) = item
    if dir_path != path && testfs_parent_dir(dir_path) == path {
      entries[testfs_base_name(dir_path)] = true
    }
  }
  let out : Array[String] = []
  for item in entries.to_array() {
    let (name, _) = item
    out.push(name)
  }
  out.sort()
  out
}

///|
pub fn TestFs::is_dir(self : TestFs, path : String) -> Bool {
  self.dirs.contains(path)
}

///|
pub fn TestFs::is_file(self : TestFs, path : String) -> Bool {
  self.files.contains(path)
}

///|
pub impl FileSystem for TestFs with mkdir_p(self, path) {
  TestFs::mkdir_p(self, path)
}

///|
pub impl FileSystem for TestFs with write_file(self, path, content) {
  TestFs::write_file(self, path, content)
}

///|
pub impl FileSystem for TestFs with write_string(self, path, content) {
  TestFs::write_string(self, path, content)
}

///|
pub impl FileSystem for TestFs with remove_file(self, path) {
  TestFs::remove_file(self, path)
}

///|
pub impl FileSystem for TestFs with remove_dir(self, path) {
  TestFs::remove_dir(self, path)
}

///|
pub impl RepoFileSystem for TestFs with read_file(self, path) {
  TestFs::read_file(self, path)
}

///|
pub impl RepoFileSystem for TestFs with readdir(self, path) {
  TestFs::readdir(self, path)
}

///|
pub impl RepoFileSystem for TestFs with is_dir(self, path) {
  TestFs::is_dir(self, path)
}

///|
pub impl RepoFileSystem for TestFs with is_file(self, path) {
  TestFs::is_file(self, path)
}

///|
fn string_to_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for c in s {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
}

///|
fn TestFs::ensure_dirs(self : TestFs, path : String) -> Unit {
  if path.length() == 0 {
    return
  }
  let mut current = ""
  let parts = testfs_split_path(path)
  for part in parts {
    current = if current == "" { "/" + part } else { current + "/" + part }
    self.dirs.set(current, true)
  }
  if path == "/" {
    self.dirs.set("/", true)
  }
}

///|
fn testfs_split_path(path : String) -> Array[String] {
  let out : Array[String] = []
  if path.length() == 0 {
    return out
  }
  let mut p = path
  if p.has_prefix("/") {
    p = String::unsafe_substring(p, start=1, end=p.length())
  }
  if p.length() == 0 {
    return out
  }
  for part_view in p.split("/") {
    let part = part_view.to_string()
    if part.length() == 0 {
      continue
    }
    out.push(part)
  }
  out
}

///|
fn testfs_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

///|
fn testfs_base_name(path : String) -> String {
  match path.rev_find("/") {
    None => path
    Some(i) => String::unsafe_substring(path, start=i + 1, end=path.length())
  }
}
