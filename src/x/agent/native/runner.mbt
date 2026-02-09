///| Native I/O adapter for agent workflow

///|
priv struct FsWorkingTree {
  fs : @bitfs.Fs
  backing_fs : &@git.FileSystem
  rfs : &@git.RepoFileSystem
}

///|
impl @lib.WorkingTree for FsWorkingTree with read_file(self, path) {
  self.fs.read_file(self.rfs, path)
}

///|
impl @lib.WorkingTree for FsWorkingTree with write_file(self, path, content) {
  self.fs.write_file(path, content)
}

///|
impl @lib.WorkingTree for FsWorkingTree with remove_file(self, path) {
  self.fs.remove_file(path)
}

///|
impl @lib.WorkingTree for FsWorkingTree with is_file(self, path) {
  self.fs.is_file(self.rfs, path)
}

///|
impl @lib.WorkingTree for FsWorkingTree with is_dir(self, path) {
  self.fs.is_dir(self.rfs, path)
}

///|
impl @lib.WorkingTree for FsWorkingTree with readdir(self, path) {
  self.fs.readdir(self.rfs, path)
}

///|
impl @lib.WorkingTree for FsWorkingTree with is_dirty(self) {
  self.fs.is_dirty()
}

///|
impl @lib.WorkingTree for FsWorkingTree with rollback(self) {
  self.fs.rollback()
}

///|
impl @lib.WorkingTree for FsWorkingTree with get_working_files(self) {
  self.fs.get_working_files()
}

///|
impl @lib.WorkingTree for FsWorkingTree with snapshot(
  self,
  message,
  author,
  timestamp,
) {
  let snap = self.fs.snapshot(
    self.backing_fs,
    self.rfs,
    message,
    author,
    timestamp,
  )
  snap.commit_id
}

///|
impl @lib.WorkingTree for FsWorkingTree with checkout(self, commit_id) {
  self.fs.checkout_snapshot(self.rfs, commit_id)
}

///|
priv struct NativeObjectStore {
  rfs : &@git.RepoFileSystem
  fs : &@git.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for NativeObjectStore with get(self, id) {
  let db = @lib.ObjectDb::load_lazy(self.rfs, self.git_dir)
  db.get(self.rfs, id)
}

///|
impl @lib.ObjectStore for NativeObjectStore with put(self, obj_type, content) {
  let (id, compressed) = @git.create_object(obj_type, content)
  @hub.write_object_bytes(self.fs, self.git_dir, id, compressed)
  id
}

///|
impl @lib.ObjectStore for NativeObjectStore with has(self, id) {
  let db = @lib.ObjectDb::load_lazy(self.rfs, self.git_dir)
  let obj = db.get(self.rfs, id)
  obj is Some(_)
}

///|
priv struct NativeRefStore {
  fs : &@git.FileSystem
  rfs : &@git.RepoFileSystem
  git_dir : String
}

///|
impl @lib.RefStore for NativeRefStore with resolve(self, ref_name) {
  @lib.resolve_ref(self.rfs, self.git_dir, ref_name)
}

///|
impl @lib.RefStore for NativeRefStore with update(self, ref_name, id) {
  match id {
    Some(commit_id) => {
      let ref_path = self.git_dir + "/" + ref_name
      let dir = native_parent_path(ref_path)
      self.fs.mkdir_p(dir)
      self.fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    None => ()
  }
}

///|
impl @lib.RefStore for NativeRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
priv struct NativeClock {
  _dummy : Int
}

///|
impl @lib.Clock for NativeClock with now(_self) {
  @async.now()
}

///|
fn native_parent_path(path : String) -> String {
  match path.rev_find("/") {
    None => "."
    Some(0) => "/"
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
  }
}

///|
fn make_native_stores(
  git_dir : String,
) -> (
  &@git.FileSystem,
  &@git.RepoFileSystem,
  &@lib.ObjectStore,
  &@lib.RefStore,
  &@lib.Clock,
) {
  let osfs = @osfs.OsFs::new()
  let fs : &@git.FileSystem = osfs
  let rfs : &@git.RepoFileSystem = osfs
  let objects : NativeObjectStore = { rfs, fs, git_dir }
  let refs : NativeRefStore = { fs, rfs, git_dir }
  let clock : NativeClock = { _dummy: 0 }
  (fs, rfs, objects, refs, clock)
}

///|
fn[X] return_or_raise_cancellation(err : Error, fallback : X) -> X raise {
  if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
    raise err
  }
  fallback
}

///|
/// Run a task: create sandbox Fs, apply edits, snapshot, create PR, push.
pub async fn run_task(
  task : @agent.AgentTask,
  config : @agent.AgentConfig,
  git_dir : String,
) -> @agent.TaskResult {
  let (fs, rfs, objects, refs, clock) = make_native_stores(git_dir)
  // 1. Create sandbox Fs from target branch
  let sandbox = @bitfs.Fs::from_branch(rfs, git_dir, config.target_branch) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      return return_or_raise_cancellation(
        err,
        @agent.TaskResult::Error(err.to_string()),
      )
    }
  }
  let tree : FsWorkingTree = { fs: sandbox, backing_fs: fs, rfs }
  let working_tree : &@lib.WorkingTree = tree
  // 2. Load or init hub
  let hub = @hub.Hub::load(objects, refs) catch {
    _ =>
      @hub.Hub::init(objects, refs) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          return return_or_raise_cancellation(
            err,
            @agent.TaskResult::Error(err.to_string()),
          )
        }
      }
  }
  // 3. Execute pure workflow
  let result = @agent.execute_task(
    task, config, hub, objects, refs, clock, working_tree,
  )
  // 4. Push branch and hub notes to remote
  match result {
    @agent.TaskResult::PrCreated(_) => {
      // Push the source branch
      let source_ref = "refs/heads/" + task.source_branch
      let commit_id = refs.resolve(source_ref) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          return return_or_raise_cancellation(
            err,
            @agent.TaskResult::Error(err.to_string()),
          )
        }
      }
      match commit_id {
        Some(id) => {
          let db = @lib.ObjectDb::load(rfs, git_dir) catch {
            err => {
              if @async.is_being_cancelled() ||
                @async.is_cancellation_error(err) {
                raise err
              }
              return return_or_raise_cancellation(
                err,
                @agent.TaskResult::Error(err.to_string()),
              )
            }
          }
          let reachable = @lib.collect_reachable_objects(db, rfs, id)
          let pack = @pack.create_packfile(reachable)
          let remote = @protocol.Remote::new(config.remote_url)
          let req = @protocol.PushRequest::new(
            @git.ObjectId::zero(),
            id,
            source_ref,
            pack,
          )
          ignore(
            @gitnative.push(remote, req) catch {
              err => {
                if @async.is_being_cancelled() ||
                  @async.is_cancellation_error(err) {
                  raise err
                }
                return return_or_raise_cancellation(
                  err,
                  @agent.TaskResult::Error(err.to_string()),
                )
              }
            },
          )
          // Push hub notes
          ignore(
            @hub_native.hub_push(hub, rfs, git_dir, config.remote_url) catch {
              err => {
                if @async.is_being_cancelled() ||
                  @async.is_cancellation_error(err) {
                  raise err
                }
                return return_or_raise_cancellation(
                  err,
                  @agent.TaskResult::Error(err.to_string()),
                )
              }
            },
          )
        }
        None => ()
      }
    }
    _ => ()
  }
  result
}

///|
/// Validate a PR by running the validation command on a checkout of its source commit.
pub async fn validate_pr(
  pr : @hub.PullRequest,
  config : @agent.AgentConfig,
  git_dir : String,
) -> @agent.ReviewResult {
  if config.validation_cmd == "" {
    return @agent.ReviewResult::Approved
  }
  let (_fs, rfs, _objects, _refs, _clock) = make_native_stores(git_dir)
  // Checkout PR source commit into sandbox
  let sandbox = @bitfs.Fs::from_commit(rfs, git_dir, pr.source_commit()) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      return return_or_raise_cancellation(
        err,
        @agent.ReviewResult::ValidationError(err.to_string()),
      )
    }
  }
  ignore(sandbox)
  // Run validation command
  let (exit_code, stdout, stderr) = @process.collect_output(
    "sh",
    ["-c", config.validation_cmd],
    inherit_env=true,
  ) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      return return_or_raise_cancellation(
        err,
        @agent.ReviewResult::ValidationError(err.to_string()),
      )
    }
  }
  let out = stdout.text() catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      return_or_raise_cancellation(err, "")
    }
  }
  let err_text = stderr.text() catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      return_or_raise_cancellation(err, "")
    }
  }
  let output = if out.length() > 0 { out } else { err_text }
  @agent.evaluate_validation(exit_code, output)
}
