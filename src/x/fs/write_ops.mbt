///| Write operations for Fs (FileSystem trait implementation)

///|
pub fn Fs::write_file(self : Fs, path : String, content : Bytes) -> Unit {
  let norm = normalize_path(path)
  ensure_parent_dirs(self.working, norm)
  self.working.files[norm] = content
  self.working.deleted.remove(norm)
  self.cache.invalidate_path(norm)
  self.working.dirty = true
}

///|
pub fn Fs::write_string(
  self : Fs,
  path : String,
  content : String,
) -> Unit {
  let bytes = string_to_bytes(content)
  self.write_file(path, bytes)
}

///|
pub fn Fs::mkdir_p(self : Fs, path : String) -> Unit {
  let norm = normalize_path(path)
  if norm.length() == 0 {
    return
  }
  let parts = split_path(norm)
  let mut current = ""
  for part in parts {
    current = if current.length() == 0 { part } else { current + "/" + part }
    self.working.dirs[current] = true
    self.working.deleted.remove(current)
  }
  self.working.dirty = true
}

///|
pub fn Fs::remove_file(self : Fs, path : String) -> Unit {
  let norm = normalize_path(path)
  self.working.files.remove(norm)
  self.working.deleted[norm] = true
  self.cache.invalidate_path(norm)
  self.working.dirty = true
}

///|
pub fn Fs::remove_dir(self : Fs, path : String) -> Unit {
  let norm = normalize_path(path)
  self.working.dirs.remove(norm)
  let prefix = norm + "/"
  let files_to_remove : Array[String] = []
  for item in self.working.files.to_array() {
    let (file_path, _) = item
    if file_path.has_prefix(prefix) {
      files_to_remove.push(file_path)
    }
  }
  for file_path in files_to_remove {
    self.working.files.remove(file_path)
    self.working.deleted[file_path] = true
  }
  let dirs_to_remove : Array[String] = []
  for item in self.working.dirs.to_array() {
    let (dir_path, _) = item
    if dir_path.has_prefix(prefix) || dir_path == norm {
      dirs_to_remove.push(dir_path)
    }
  }
  for dir_path in dirs_to_remove {
    self.working.dirs.remove(dir_path)
  }
  self.working.deleted[norm] = true
  self.cache.invalidate_path(norm)
  self.working.dirty = true
}

///|
fn string_to_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for c in s {
    out.push(c.to_int().to_byte())
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
impl @git.FileSystem for Fs with mkdir_p(self, path) {
  Fs::mkdir_p(self, path)
}

///|
impl @git.FileSystem for Fs with write_file(self, path, content) {
  Fs::write_file(self, path, content)
}

///|
impl @git.FileSystem for Fs with write_string(self, path, content) {
  Fs::write_string(self, path, content)
}

///|
impl @git.FileSystem for Fs with remove_file(self, path) {
  Fs::remove_file(self, path)
}

///|
impl @git.FileSystem for Fs with remove_dir(self, path) {
  Fs::remove_dir(self, path)
}
