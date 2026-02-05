///|
pub fn init_worktree_probe() -> Unit {
  let provider = @gitlib.WorktreeProbeProvider::new(
    async fn(
      fs : &@git.RepoFileSystem,
      abs_path : String,
    ) -> @gitlib.WorktreeEntryMeta? noraise {
      let kind_result : Result[@afs.FileKind, Error] = try? @afs.kind(
        abs_path,
        follow_symlink=false,
      )
      match kind_result {
        Ok(@afs.FileKind::SymLink) => {
          let mut mtime_sec : Int? = None
          let mut mtime_nsec : Int? = None
          let mtime_result : Result[(Int64, Int), Error] = try? @afs.mtime(
            abs_path,
            follow_symlink=false,
          )
          match mtime_result {
            Ok((sec, nsec)) => {
              mtime_sec = Some(sec.to_int())
              mtime_nsec = Some(nsec)
            }
            Err(_) => ()
          }
          Some(
            @gitlib.WorktreeEntryMeta::new(
              @gitlib.WorktreeKindMeta::symlink(),
              0o120000,
              None,
              mtime_sec,
              mtime_nsec,
            ),
          )
        }
        Ok(@afs.FileKind::Regular) => {
          Some(native_regular_meta(abs_path, true))
        }
        Ok(_) => None
        Err(_) =>
          if fs.is_file(abs_path) {
            Some(native_regular_meta(abs_path, false))
          } else {
            None
          }
      }
    },
    fn(path : String) { native_read_symlink_target_path(path) },
  )
  @gitlib.set_worktree_probe(provider)
}

///|
async fn native_regular_meta(
  abs_path : String,
  use_os : Bool,
) -> @gitlib.WorktreeEntryMeta noraise {
  if not(use_os) {
    return @gitlib.WorktreeEntryMeta::new(
      @gitlib.WorktreeKindMeta::regular(),
      0o100644,
      None,
      None,
      None,
    )
  }
  let exec = @afs.can_execute(abs_path) catch { _ => false }
  let mode = if exec { 0o100755 } else { 0o100644 }
  let mut size : Int? = None
  let mut mtime_sec : Int? = None
  let mut mtime_nsec : Int? = None
  let open_result : Result[@afs.File, Error] = try? @afs.open(
    abs_path,
    mode=@afs.Mode::ReadOnly,
  )
  match open_result {
    Ok(file) => {
      let size_result : Result[Int64, Error] = try? file.size()
      match size_result {
        Ok(s) => size = Some(s.to_int())
        Err(_) => ()
      }
      let mtime_result : Result[(Int64, Int), Error] = try? file.mtime()
      match mtime_result {
        Ok((sec, nsec)) => {
          mtime_sec = Some(sec.to_int())
          mtime_nsec = Some(nsec)
        }
        Err(_) => ()
      }
      file.close()
    }
    Err(_) => ()
  }
  @gitlib.WorktreeEntryMeta::new(
    @gitlib.WorktreeKindMeta::regular(),
    mode,
    size,
    mtime_sec,
    mtime_nsec,
  )
}

///|
fn native_read_symlink_target_path(path : String) -> String? {
  native_try_readlink(path)
}

///|
fn native_try_readlink(path : String) -> String? {
  let path_buf = native_string_to_cstring(path)
  let mut buf_len = 256
  while buf_len <= 131072 {
    let buf = Bytes::new(buf_len)
    let read_len = readlink(path_buf, buf, buf.length())
    if read_len < 0 {
      return None
    }
    if read_len < buf.length() {
      return Some(@utf8.decode_lossy(buf[:read_len]))
    }
    buf_len *= 2
  }
  let buf = Bytes::new(131072)
  let read_len = readlink(path_buf, buf, buf.length())
  if read_len < 0 {
    None
  } else {
    Some(@utf8.decode_lossy(buf[:read_len]))
  }
}

///|
fn native_string_to_cstring(path : String) -> Bytes {
  let encoded = @utf8.encode(path.to_string_view())
  Bytes::add(encoded, Bytes::make(1, b'\x00'))
}

///|
#borrow(path_buf, buf)
extern "c" fn readlink(path_buf : Bytes, buf : Bytes, size : Int) -> Int = "readlink"
