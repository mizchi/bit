///| File-system tree helpers

///|
fn ensure_dir(fs : &@git.FileSystem, path : String) -> Unit raise @git.GitError {
  if path.length() == 0 || path == "/" || path == "." {
    return ()
  }
  fs.mkdir_p(path)
}

///|
pub fn copy_tree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  src : String,
  dest : String,
) -> Unit raise @git.GitError {
  let is_dir = rfs.is_dir(src)
  if is_dir {
    ensure_dir(fs, dest)
    let entries = rfs.readdir(src) catch { _ => return () }
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      let src_path = src + "/" + entry
      let dest_path = dest + "/" + entry
      copy_tree(fs, rfs, src_path, dest_path)
    }
    return ()
  }
  let is_file = rfs.is_file(src)
  if is_file {
    let data = rfs.read_file(src)
    if rfs.is_file(dest) {
      return ()
    }
    let parent = parent_dir(dest)
    if parent.length() > 0 {
      ensure_dir(fs, parent)
    }
    fs.write_file(dest, data)
  }
}

///|
pub fn remove_tree(
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
      remove_tree(fs, rfs, path + "/" + entry)
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

///|
pub fn move_tree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  src : String,
  dest : String,
) -> Unit raise @git.GitError {
  copy_tree(fs, rfs, src, dest)
  remove_tree(fs, rfs, src)
}

///|
pub fn move_tree_safe(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  src : String,
  dest : String,
) -> Unit raise @git.GitError {
  if not(rfs.is_dir(src)) {
    return ()
  }
  if dest.has_prefix(src + "/") {
    let tmp = src + ".rename_tmp"
    if rfs.is_dir(tmp) {
      remove_tree(fs, rfs, tmp)
    }
    move_tree(fs, rfs, src, tmp)
    move_tree(fs, rfs, tmp, dest)
  } else {
    move_tree(fs, rfs, src, dest)
  }
}

///|
pub fn remove_ref_path(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  path : String,
) -> Unit {
  if rfs.is_dir(path) {
    remove_tree(fs, rfs, path)
  } else if rfs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
  }
}
