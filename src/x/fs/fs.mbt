///| Fs construction and initialization

///|
/// Create Fs from a commit.
/// Uses config.lazy_load to determine loading strategy (default: lazy).
pub fn Fs::from_commit(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  config? : FsConfig = FsConfig::default(),
) -> Fs raise @git.GitError {
  let db = if config.lazy_load {
    @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  } else {
    @lib.ObjectDb::load(backing_fs, git_dir)
  }
  let obj = db.get(backing_fs, commit_id)
  guard obj is Some(commit_obj) else {
    raise @git.GitError::InvalidObject("Commit not found: \{commit_id}")
  }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Object is not a commit")
  }
  let info = @git.parse_commit(commit_obj.data)
  {
    git_dir,
    base_tree: info.tree,
    base_commit: Some(commit_id),
    working: WorkingLayer::new(),
    layers: [],
    cache: ObjectCache::new(config.max_cache_bytes),
    config,
    cached_db: Some(db),
    cached_promisor_db: None,
    lazy_mode: config.lazy_load,
  }
}

///|
/// Create Fs from a tree ID.
/// Uses config.lazy_load to determine loading strategy (default: lazy).
pub fn Fs::from_tree(
  git_dir : String,
  tree_id : @git.ObjectId,
  config? : FsConfig = FsConfig::default(),
) -> Fs {
  {
    git_dir,
    base_tree: tree_id,
    base_commit: None,
    working: WorkingLayer::new(),
    layers: [],
    cache: ObjectCache::new(config.max_cache_bytes),
    config,
    cached_db: None,
    cached_promisor_db: None,
    lazy_mode: config.lazy_load,
  }
}

///|
/// Create Fs from a branch name.
/// Uses config.lazy_load to determine loading strategy (default: lazy).
pub fn Fs::from_branch(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  branch : String,
  config? : FsConfig = FsConfig::default(),
) -> Fs raise @git.GitError {
  let commit_id = @lib.resolve_ref(backing_fs, git_dir, "refs/heads/" + branch)
  match commit_id {
    Some(id) => Fs::from_commit(backing_fs, git_dir, id, config~)
    None =>
      raise @git.GitError::InvalidObject(
        "Branch not found: refs/heads/" + branch,
      )
  }
}

///|
/// Create an empty Fs (no base tree).
/// Uses config.lazy_load to determine loading strategy (default: lazy).
pub fn Fs::empty(
  git_dir : String,
  config? : FsConfig = FsConfig::default(),
) -> Fs {
  {
    git_dir,
    base_tree: @git.ObjectId::zero(),
    base_commit: None,
    working: WorkingLayer::new(),
    layers: [],
    cache: ObjectCache::new(config.max_cache_bytes),
    config,
    cached_db: None,
    cached_promisor_db: None,
    lazy_mode: config.lazy_load,
  }
}

///|
/// Get or load the ObjectDb (cached for performance).
/// Respects lazy_mode: uses lazy loading when true, eager loading when false.
pub fn Fs::get_db(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
) -> @lib.ObjectDb raise @git.GitError {
  match self.cached_db {
    Some(db) => db
    None => {
      let db = if self.lazy_mode {
        @lib.ObjectDb::load_lazy(backing_fs, self.git_dir)
      } else {
        @lib.ObjectDb::load(backing_fs, self.git_dir)
      }
      self.cached_db = Some(db)
      db
    }
  }
}

///|
/// Get or load the PromisorDb (cached for performance).
/// Returns None if promisor support is disabled in config.
pub fn Fs::get_promisor_db(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
) -> @libnative.PromisorDb? raise @git.GitError {
  if not(self.config.enable_promisor) {
    return None
  }
  match self.cached_promisor_db {
    Some(db) => Some(db)
    None => {
      let db = @libnative.PromisorDb::new(
        backing_fs,
        self.git_dir,
        lazy_load=self.lazy_mode,
      )
      self.cached_promisor_db = Some(db)
      Some(db)
    }
  }
}

///|
/// Check if this Fs is backed by a partial clone with promisor remote
pub fn Fs::has_promisor(self : Fs, backing_fs : &@git.RepoFileSystem) -> Bool {
  if not(self.config.enable_promisor) {
    return false
  }
  @libnative.is_partial_clone(backing_fs, self.git_dir)
}

///|
/// Get the promisor remote URL if available
pub fn Fs::get_promisor_remote(
  self : Fs,
  backing_fs : &@git.RepoFileSystem,
) -> String? {
  if not(self.config.enable_promisor) {
    return None
  }
  @libnative.read_promisor_remote(backing_fs, self.git_dir)
}

///|
pub fn Fs::is_dirty(self : Fs) -> Bool {
  self.working.is_dirty()
}

///|
pub fn Fs::git_dir(self : Fs) -> String {
  self.git_dir
}

///|
pub fn Fs::base_tree(self : Fs) -> @git.ObjectId {
  self.base_tree
}

///|
pub fn Fs::base_commit(self : Fs) -> @git.ObjectId? {
  self.base_commit
}

///|
/// Check if lazy loading is enabled
pub fn Fs::is_lazy(self : Fs) -> Bool {
  self.lazy_mode
}

///|
/// Check if promisor support is enabled
pub fn Fs::is_promisor_enabled(self : Fs) -> Bool {
  self.config.enable_promisor
}
