///|
pub enum WorktreeKind {
  Regular
  Symlink(target~ : String)
}

///|
pub struct WorktreeEntry {
  kind : WorktreeKind
  mode : Int
  size : Int?
  mtime_sec : Int?
  mtime_nsec : Int?
}

///|
pub enum WorktreeKindMeta {
  Regular
  Symlink
}

///|
pub struct WorktreeEntryMeta {
  kind : WorktreeKindMeta
  mode : Int
  size : Int?
  mtime_sec : Int?
  mtime_nsec : Int?
}

///|
pub fn WorktreeKindMeta::regular() -> WorktreeKindMeta {
  Regular
}

///|
pub fn WorktreeKindMeta::symlink() -> WorktreeKindMeta {
  Symlink
}

///|
pub fn WorktreeEntryMeta::new(
  kind : WorktreeKindMeta,
  mode : Int,
  size : Int?,
  mtime_sec : Int?,
  mtime_nsec : Int?,
) -> WorktreeEntryMeta {
  { kind, mode, size, mtime_sec, mtime_nsec }
}

///|
pub struct WorktreeProbeProvider {
  entry_meta : async (&@git.RepoFileSystem, String) -> WorktreeEntryMeta? noraise
  symlink_target : (String) -> String?
}

///|
pub fn WorktreeProbeProvider::new(
  entry_meta : async (&@git.RepoFileSystem, String) -> WorktreeEntryMeta? noraise,
  symlink_target : (String) -> String?,
) -> WorktreeProbeProvider {
  { entry_meta, symlink_target }
}

///|
pub fn WorktreeProbeProvider::none() -> WorktreeProbeProvider {
  {
    entry_meta: async fn(
      fs : &@git.RepoFileSystem,
      path : String,
    ) -> WorktreeEntryMeta? noraise {
      if fs.is_file(path) {
        Some(
          WorktreeEntryMeta::new(
            WorktreeKindMeta::regular(),
            0o100644,
            None,
            None,
            None,
          ),
        )
      } else {
        None
      }
    },
    symlink_target: fn(_ : String) { None },
  }
}

///|
priv struct WorktreeProbeBox {
  mut value : WorktreeProbeProvider
}

///|
let worktree_probe_box : WorktreeProbeBox = {
  value: WorktreeProbeProvider::none(),
}

///|
pub fn set_worktree_probe(provider : WorktreeProbeProvider) -> Unit {
  worktree_probe_box.value = provider
}

///|
pub async fn worktree_entry_meta(
  fs : &@git.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntryMeta? noraise {
  (worktree_probe_box.value.entry_meta)(fs, abs_path)
}

///|
pub fn read_symlink_target_path(path : String) -> String? {
  (worktree_probe_box.value.symlink_target)(path)
}

///|
pub async fn worktree_entry(
  fs : &@git.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntry? noraise {
  let meta = worktree_entry_meta(fs, abs_path)
  match meta {
    None => None
    Some(info) =>
      match info.kind {
        WorktreeKindMeta::Regular =>
          Some({
            kind: WorktreeKind::Regular,
            mode: info.mode,
            size: info.size,
            mtime_sec: info.mtime_sec,
            mtime_nsec: info.mtime_nsec,
          })
        WorktreeKindMeta::Symlink =>
          match read_symlink_target_path(abs_path) {
            Some(target) =>
              Some({
                kind: WorktreeKind::Symlink(target~),
                mode: info.mode,
                size: info.size,
                mtime_sec: info.mtime_sec,
                mtime_nsec: info.mtime_nsec,
              })
            None => None
          }
      }
  }
}
