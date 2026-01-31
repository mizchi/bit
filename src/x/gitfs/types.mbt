///| Git-backed Virtual Filesystem types

///|
pub struct GitFsConfig {
  max_cache_bytes : Int
  max_cache_entries : Int
}

///|
pub fn GitFsConfig::default() -> GitFsConfig {
  { max_cache_bytes: 64 * 1024 * 1024, max_cache_entries: 1000 }
}

///|
pub struct GitFs {
  git_dir : String
  mut base_tree : @git.ObjectId
  mut base_commit : @git.ObjectId?
  working : WorkingLayer
  layers : Array[Layer]
  cache : ObjectCache
  config : GitFsConfig
  mut cached_db : @lib.ObjectDb?
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
  blobs : Map[String, Bytes]
  trees : Map[@git.ObjectId, Array[@git.TreeEntry]] // ObjectId as key (no hex conversion)
  path_cache : Map[String, @git.ObjectId?]
  max_blob_bytes : Int
  mut blob_bytes : Int
  blob_order : Array[String]
}

///|
pub fn ObjectCache::new(max_bytes : Int) -> ObjectCache {
  {
    blobs: {},
    trees: {},
    path_cache: {},
    max_blob_bytes: max_bytes,
    blob_bytes: 0,
    blob_order: [],
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
