///| High-level push/pull over HTTP (async, native-only)

///|
/// Clone a remote repository via HTTP.
pub async fn clone_http(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  remote_url : String,
  dest : String,
  prefer_v2 : Bool,
) -> @git.ObjectId? raise @git.GitError {
  // 1. Create destination directory and init
  fs.mkdir_p(dest)
  @gitlib.init_repo(fs, dest)
  // 2. Save remote URL
  let git_dir = sync_join_path(dest, ".git")
  let config_path = sync_join_path(git_dir, "config")
  let config_content = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n[remote \"origin\"]\n\turl = \{remote_url}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
  fs.write_string(config_path, config_content)
  // 3. Fetch refs and packfile
  let (refs, _caps, _version, symrefs) = @gitnative.discover_upload_refs_http(
    remote_url, prefer_v2,
  )
  let default_ref = @protocol.select_default_ref(refs, symrefs)
  match default_ref {
    None => return None
    Some((refname, commit_id)) => {
      let pack = @gitnative.fetch_pack_http(remote_url, [commit_id], prefer_v2)
      let objects = @pack.parse_packfile(pack)
      @pack.write_packfile_with_index(fs, git_dir, pack, objects)
      // 4. Update refs
      // Set HEAD to point to default branch
      let branch_name = if refname.has_prefix("refs/heads/") {
        String::unsafe_substring(refname, start=11, end=refname.length())
      } else {
        "main"
      }
      let head_path = sync_join_path(git_dir, "HEAD")
      fs.write_string(head_path, "ref: refs/heads/\{branch_name}\n")
      // Create local branch
      let branch_ref_path = sync_join_path(git_dir, "refs/heads/\{branch_name}")
      let branch_dir = sync_parent_dir(branch_ref_path)
      fs.mkdir_p(branch_dir)
      fs.write_string(branch_ref_path, commit_id.to_hex() + "\n")
      // Create remote tracking ref
      let remote_ref = sync_remote_refname(refname)
      let remote_path = sync_join_path(git_dir, remote_ref)
      let remote_dir = sync_parent_dir(remote_path)
      fs.mkdir_p(remote_dir)
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      // 5. Checkout working tree
      @gitlib.fast_forward_to(fs, rfs, dest, commit_id)
      Some(commit_id)
    }
  }
}

///|
pub async fn pull_http(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  remote : String,
  prefer_v2 : Bool,
  rebase? : Bool = false,
) -> @git.ObjectId? raise @git.GitError {
  let (refs, _caps, _version, symrefs) = @gitnative.discover_upload_refs_http(
    remote, prefer_v2,
  )
  let default_ref = @protocol.select_default_ref(refs, symrefs)
  match default_ref {
    None => return None
    Some((refname, commit_id)) => {
      let pack = @gitnative.fetch_pack_http(remote, [commit_id], prefer_v2)
      let objects = @pack.parse_packfile(pack)
      let git_dir = sync_join_path(root, ".git")
      @pack.write_packfile_with_index(fs, git_dir, pack, objects)
      // update remote tracking ref
      let remote_ref = sync_remote_refname(refname)
      let remote_path = sync_join_path(git_dir, remote_ref)
      let dir = sync_parent_dir(remote_path)
      fs.mkdir_p(dir)
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      if rebase {
        let _ = @gitlib.rebase_onto(fs, rfs, root, commit_id)

      } else {
        let head = @gitlib.resolve_head_commit(rfs, git_dir)
        match head {
          None => @gitlib.fast_forward_to(fs, rfs, root, commit_id)
          Some(h) =>
            if sync_is_ancestor(rfs, git_dir, h, commit_id) {
              @gitlib.fast_forward_to(fs, rfs, root, commit_id)
            } else {
              raise @git.GitError::InvalidObject("Non-fast-forward pull")
            }
        }
      }
      Some(commit_id)
    }
  }
}

///|
pub async fn push_http(
  rfs : &@git.RepoFileSystem,
  root : String,
  remote_url : String,
  refname : String,
  force~ : Bool = false,
) -> String raise @git.GitError {
  let git_dir = sync_join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let head = @gitlib.resolve_head_commit(rfs, actual_git_dir)
  match head {
    None => raise @git.GitError::InvalidObject("HEAD not found")
    Some(head_id) => {
      let db = @gitlib.ObjectDb::load(rfs, actual_git_dir)
      let objects = @gitlib.collect_reachable_objects(db, rfs, head_id)
      let pack = @pack.create_packfile(objects)
      let remote = @protocol.Remote::new(remote_url)
      let refs = @gitnative.discover_receive_refs_http(remote)
      let old_id = sync_find_ref(refs, refname)
      // Check fast-forward unless force
      if not(force) && old_id != @git.ObjectId::zero() {
        if not(sync_is_ancestor(rfs, actual_git_dir, old_id, head_id)) {
          raise @git.GitError::InvalidObject(
            "Updates were rejected because the tip of your current branch is behind\nits remote counterpart. If you want to force the update, use 'git push --force'.",
          )
        }
      }
      let req = @protocol.PushRequest::new(old_id, head_id, refname, pack)
      @gitnative.push(remote, req)
    }
  }
}

///|
/// Push from a specific commit (not HEAD) - used for subdir-clone push
pub async fn push_http_from_commit(
  rfs : &@git.RepoFileSystem,
  root : String,
  remote_url : String,
  commit_id : @git.ObjectId,
  refname : String,
) -> String raise @git.GitError {
  let git_dir = sync_join_path(root, ".git")
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let objects = @gitlib.collect_reachable_objects(db, rfs, commit_id)
  let pack = @pack.create_packfile(objects)
  let remote = @protocol.Remote::new(remote_url)
  let refs = @gitnative.discover_receive_refs_http(remote)
  let old_id = sync_find_ref(refs, refname)
  let req = @protocol.PushRequest::new(old_id, commit_id, refname, pack)
  @gitnative.push(remote, req)
}

///|
/// Push a single commit without parent history - used for subdir-clone push
/// where parent commits already exist on remote.
/// Only includes objects that don't exist in the base commit.
pub async fn push_http_tree_only(
  rfs : &@git.RepoFileSystem,
  root : String,
  remote_url : String,
  commit_id : @git.ObjectId,
  old_commit_id : @git.ObjectId,
  refname : String,
) -> String raise @git.GitError {
  let git_dir = sync_join_path(root, ".git")
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  // Collect only the diff objects (new/modified since base)
  let objects = @gitlib.collect_diff_objects(db, rfs, old_commit_id, commit_id)
  let pack = @pack.create_packfile(objects)
  let remote = @protocol.Remote::new(remote_url)
  let req = @protocol.PushRequest::new(old_commit_id, commit_id, refname, pack)
  @gitnative.push(remote, req)
}

///|
fn sync_find_ref(
  refs : Array[(@git.ObjectId, String)],
  name : String,
) -> @git.ObjectId {
  for item in refs {
    let (id, refname) = item
    if refname == name {
      return id
    }
  }
  @git.ObjectId::zero()
}

///|
fn sync_is_ancestor(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  base : @git.ObjectId,
  target : @git.ObjectId,
) -> Bool raise @git.GitError {
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let mut current = target
  while true {
    if current == base {
      return true
    }
    let obj = db.get(fs, current)
    match obj {
      None => return false
      Some(o) => {
        if o.obj_type != @git.ObjectType::Commit {
          return false
        }
        let info = @git.parse_commit(o.data)
        if info.parents.length() == 0 {
          return false
        }
        current = info.parents[0]
      }
    }
  }
  false
}

///|
fn sync_remote_refname(refname : String) -> String {
  if refname.has_prefix("refs/heads/") {
    let name = String::unsafe_substring(refname, start=11, end=refname.length())
    "refs/remotes/origin/" + name
  } else if refname == "HEAD" {
    "refs/remotes/origin/HEAD"
  } else {
    "refs/remotes/origin/" + refname
  }
}

///|
fn sync_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

///|
fn sync_join_path(root : String, path : String) -> String {
  if root.has_suffix("/") {
    root + path
  } else {
    root + "/" + path
  }
}
