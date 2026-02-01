///| Git-backed Virtual Filesystem types

///|
pub struct FsConfig {
  max_cache_bytes : Int
  max_cache_entries : Int
  lazy_load : Bool // If true, defer object/pack loading until first access
  enable_promisor : Bool // If true, enable on-demand fetch from promisor remote
}

///|
pub fn FsConfig::default() -> FsConfig {
  {
    max_cache_bytes: 64 * 1024 * 1024,
    max_cache_entries: 1000,
    lazy_load: true,
    enable_promisor: true,
  }
}

///|
/// Create config with eager loading (load all packs upfront)
pub fn FsConfig::eager() -> FsConfig {
  {
    max_cache_bytes: 64 * 1024 * 1024,
    max_cache_entries: 1000,
    lazy_load: false,
    enable_promisor: true,
  }
}

///|
/// Create config for local-only access (no network fetches)
pub fn FsConfig::local_only() -> FsConfig {
  {
    max_cache_bytes: 64 * 1024 * 1024,
    max_cache_entries: 1000,
    lazy_load: true,
    enable_promisor: false,
  }
}

///|
pub struct Fs {
  git_dir : String
  mut base_tree : @git.ObjectId
  mut base_commit : @git.ObjectId?
  working : WorkingLayer
  layers : Array[Layer]
  cache : ObjectCache
  config : FsConfig
  mut cached_db : @lib.ObjectDb?
  mut cached_promisor_db : @lib.PromisorDb?
  lazy_mode : Bool // If true, use lazy object loading
}

///|
pub(all) struct WorkingLayer {
  files : Map[String, Bytes]
  deleted : Map[String, Bool]
  dirs : Map[String, Bool]
  mut dirty : Bool
}

///|
pub fn WorkingLayer::new() -> WorkingLayer {
  { files: {}, deleted: {}, dirs: {}, dirty: false }
}

///|
pub fn WorkingLayer::clear(self : WorkingLayer) -> Unit {
  self.files.clear()
  self.deleted.clear()
  self.dirs.clear()
  self.dirty = false
}

///|
pub fn WorkingLayer::is_dirty(self : WorkingLayer) -> Bool {
  self.dirty
}

///|
pub(all) struct Layer {
  tree_id : @git.ObjectId
  commit_id : @git.ObjectId?
  name : String
}

///|
pub(all) struct ObjectCache {
  blob_cache : LruCache[Bytes] // Two-generation LRU for blobs
  trees : Map[@git.ObjectId, Array[@git.TreeEntry]] // ObjectId as key (no hex conversion)
  path_cache : Map[String, @git.ObjectId?]
}

///|
pub fn ObjectCache::new(max_bytes : Int) -> ObjectCache {
  {
    blob_cache: LruCache::new(max_bytes, fn(b : Bytes) { b.length() }),
    trees: {},
    path_cache: {},
  }
}

///|
pub(all) struct Snapshot {
  commit_id : @git.ObjectId
  tree_id : @git.ObjectId
  message : String
  author : String
  timestamp : Int64
}

///|
pub fn Snapshot::new(
  commit_id : @git.ObjectId,
  tree_id : @git.ObjectId,
  message : String,
  author : String,
  timestamp : Int64,
) -> Snapshot {
  { commit_id, tree_id, message, author, timestamp }
}
