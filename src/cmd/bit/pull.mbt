///|
async fn handle_pull(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  if real_git_delegate_is_available(rfs) {
    delegate_to_real_git("pull", args)
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  if rfs.is_file(git_dir) {
    let gitfile = decode_bytes(
      rfs.read_file(git_dir) catch {
        _ => Bytes::default()
      },
    )
    ignore(gitfile)
  }
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let (remotes, branches) = @gitlib.read_repo_config(fs, git_dir)
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_name = "origin"
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  let mut rebase = false
  let mut arg_remote : String? = None
  let mut arg_refspec : String? = None
  let mut pull_adhoc_remote = false
  for arg in args {
    match arg {
      "--rebase" | "-r" => rebase = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("pull", arg)
      _ =>
        if arg_remote is None {
          arg_remote = Some(arg)
        } else if arg_refspec is None {
          arg_refspec = Some(arg)
        }
    }
  }
  // Apply explicit remote argument
  match arg_remote {
    Some(r) =>
      match remotes.get(r) {
        Some(rc) => {
          remote_name = r
          pull_adhoc_remote = false
          if rc.urls.length() > 0 {
            remote_url = Some(rc.urls[0])
          }
        }
        None => {
          // `git pull <url> ...` should not overwrite origin tracking refs.
          remote_name = "__pull_tmp__"
          remote_url = Some(r)
          pull_adhoc_remote = true
        }
      }
    None => ()
  }
  // Resolve upstream from branch config when available
  let head_ref = @gitlib.read_head_ref(fs, git_dir)
  let mut merge_ref : String? = None
  match head_ref {
    @gitlib.HeadRef::Branch(branch) => {
      match branches.get(branch) {
        Some(cfg) => {
          if cfg.remote is Some(r) && arg_remote is None {
            remote_name = r
            pull_adhoc_remote = false
            match @gitlib.get_remote_url(fs, git_dir, r) {
              Some(u) => remote_url = Some(u)
              None => ()
            }
          }
          if cfg.merges.length() > 0 {
            merge_ref = Some(cfg.merges[0])
          }
        }
        None => ()
      }
      if merge_ref is None && arg_refspec is None {
        merge_ref = Some("refs/heads/" + branch)
      }
    }
    _ => ()
  }
  // Apply explicit refspec argument
  match arg_refspec {
    Some(r) =>
      if r.has_prefix("refs/") {
        merge_ref = Some(r)
      } else {
        merge_ref = Some("refs/heads/" + r)
      }
    None => ()
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  print_line("Fetching from \{url}...")
  fetch_from_remote(fs, git_dir, root, remote_name, url, [])
  let target_ref = match merge_ref {
    Some(r) =>
      if r.has_prefix("refs/remotes/") {
        r
      } else if r.has_prefix("refs/heads/") {
        let name = String::unsafe_substring(r, start=11, end=r.length())
        "refs/remotes/" + remote_name + "/" + name
      } else if r.has_prefix("refs/") {
        r
      } else {
        "refs/remotes/" + remote_name + "/" + r
      }
    None => "refs/remotes/" + remote_name + "/HEAD"
  }
  let upstream_ref = match merge_ref {
    Some(r) => {
      let remote_prefix = "refs/remotes/" + remote_name + "/"
      if r.has_prefix("refs/heads/") {
        r
      } else if r.has_prefix(remote_prefix) {
        let name = String::unsafe_substring(
          r,
          start=remote_prefix.length(),
          end=r.length(),
        )
        "refs/heads/" + name
      } else if r.has_prefix("refs/") {
        r
      } else {
        "refs/heads/" + r
      }
    }
    None => "HEAD"
  }
  let mut target_id = @gitlib.resolve_ref(fs, git_dir, target_ref)
  if target_id is None {
    match @gitlib.resolve_local_repo_path(fs, root, url) {
      Some(src_path) =>
        match @gitlib.detect_git_dir(fs, src_path) {
          Some((src_git_dir, _)) =>
            match @gitlib.resolve_ref(fs, src_git_dir, upstream_ref) {
              Some(id) => {
                @gitlib.copy_tree(
                  fs,
                  fs,
                  src_git_dir + "/objects",
                  git_dir + "/objects",
                )
                write_ref_file(fs, git_dir, target_ref, id)
                target_id = Some(id)
              }
              None => ()
            }
          None => ()
        }
      None =>
        match resolve_remote_ref_id(url, upstream_ref) {
          Some((id, _)) => {
            let pack = @gitionative.fetch_pack_http(url, [id], true)
            let objects = @pack.parse_packfile(pack)
            @pack.write_packfile_with_index(fs, git_dir, pack, objects)
            write_ref_file(fs, git_dir, target_ref, id)
            target_id = Some(id)
          }
          None => ()
        }
    }
  }
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("Unknown ref: " + target_ref)
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let target_modes = collect_commit_tree_modes(db, fs, tid)
  let current_head = @gitlib.resolve_ref(fs, git_dir, "HEAD")
  match current_head {
    Some(head_id) => {
      let head_modes = collect_commit_tree_modes(db, fs, head_id)
      match
        find_submodule_replaced_with_non_submodule(head_modes, target_modes) {
        Some(path) =>
          raise @git.GitError::InvalidObject(
            "Refusing to replace submodule '\{path}' with non-submodule entry",
          )
        None => ()
      }
    }
    None => ()
  }
  if current_head is None {
    let head_target = match @gitlib.read_head_ref(fs, git_dir) {
      @gitlib.HeadRef::Branch(branch) =>
        resolve_initial_pull_head_target(Some(branch))
      @gitlib.HeadRef::Detached(_) => resolve_initial_pull_head_target(None)
    }
    if head_target == "HEAD" {
      fs.write_string(git_dir + "/HEAD", tid.to_hex() + "\n")
    } else {
      write_ref_file(fs, git_dir, head_target, tid)
    }
    if not(@gitlib.is_bare_git_dir(git_dir)) {
      if head_target.has_prefix("refs/heads/") {
        let branch = String::unsafe_substring(
          head_target,
          start="refs/heads/".length(),
          end=head_target.length(),
        )
        ignore(@gitlib.checkout(fs, fs, root, branch))
      } else {
        ignore(@gitlib.checkout(fs, fs, root, tid.to_hex()))
      }
    }
    print_line("Fast-forward")
    if pull_adhoc_remote {
      @gitlib.remove_remote_refs(fs, fs, git_dir, remote_name)
    }
    return
  }
  if rebase {
    let id = @gitlib.rebase_onto(fs, fs, root, tid)
    print_line("Updated to \{id.to_hex()}")
    return
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let msg = "Merge " + target_ref
  let result = @gitlib.merge(fs, fs, root, tid, msg, author, timestamp)
  match result.status {
    @gitlib.MergeStatus::AlreadyUpToDate => print_line("Already up to date.")
    @gitlib.MergeStatus::FastForward =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Fast-forward to \{short}")
        }
        None => print_line("Fast-forward")
      }
    @gitlib.MergeStatus::Merged =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Merge made by the 'ort' strategy. [\{short}]")
        }
        None => print_line("Merged")
      }
    @gitlib.MergeStatus::Conflicted => {
      print_line("CONFLICT (content): Merge conflict in the following files:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("Automatic merge failed; fix conflicts and then commit.")
    }
  }
  if pull_adhoc_remote {
    @gitlib.remove_remote_refs(fs, fs, git_dir, remote_name)
  }
}

///|
enum PushDefaultMode {
  Upstream
  Current
  Matching
  Simple
  Nothing
}

///|
struct PushTargetPlan {
  remote_name : String
  source_ref : String
  dest_ref : String
  auto_set_upstream : Bool
  delete_ref : Bool
}

///|
enum PushSourceKind {
  Branch
  Tag
  Other
}

///|
struct PushRefPlan {
  source_ref : String
  dest_ref : String
  delete_ref : Bool
  force : Bool
}

///|
struct PushParsedRefspec {
  force : Bool
  src : String
  dst : String
  has_explicit_destination : Bool
}

///|
struct PushPorcelainLine {
  flag : String
  src : String
  dst : String
  status : String
}

///|
fn format_push_porcelain_line(
  flag : String,
  src : String,
  dst : String,
  status : String,
) -> String {
  flag + "\t" + src + ":" + dst + "\t" + status
}

///|
fn classify_push_porcelain_success(
  old_id : @git.ObjectId,
  new_id : @git.ObjectId,
  delete_ref : Bool,
  force_update : Bool,
) -> (String, String) {
  if delete_ref {
    if old_id == @git.ObjectId::zero() {
      ("=", "[up to date]")
    } else {
      ("-", "[deleted]")
    }
  } else if old_id == new_id {
    ("=", "[up to date]")
  } else if old_id == @git.ObjectId::zero() {
    ("*", "[new reference]")
  } else if force_update {
    ("+", "[forced update]")
  } else {
    (" ", "[updated]")
  }
}

///|
fn select_push_rejection_status(
  non_fast_forward : Bool,
  tag_conflict : Bool,
  deny_current_branch : Bool,
  hidden_ref : Bool,
) -> String? {
  if hidden_ref {
    Some("[remote rejected] (deny updating a hidden ref)")
  } else if non_fast_forward {
    Some("[rejected] (non-fast-forward)")
  } else if tag_conflict {
    Some("[rejected] (already exists)")
  } else if deny_current_branch {
    Some("[remote rejected] (branch is currently checked out)")
  } else {
    None
  }
}

///|
fn hidden_pattern_matches_ref(refname : String, pattern : String) -> Bool {
  if pattern.length() == 0 {
    return false
  }
  if pattern.has_suffix("/") {
    return refname.has_prefix(pattern)
  }
  refname == pattern || refname.has_prefix(pattern + "/")
}

///|
fn is_hidden_ref(refname : String, patterns : Array[String]) -> Bool {
  let mut hidden = false
  for raw_pattern in patterns {
    let pattern = trim_string(raw_pattern)
    if pattern.length() == 0 {
      continue
    }
    if pattern.has_prefix("!") {
      let unhide_pattern = String::unsafe_substring(
        pattern,
        start=1,
        end=pattern.length(),
      )
      if hidden_pattern_matches_ref(refname, unhide_pattern) {
        hidden = false
      }
      continue
    }
    if hidden_pattern_matches_ref(refname, pattern) {
      hidden = true
    }
  }
  hidden
}

///|
fn read_config_values(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  section : String,
  key : String,
) -> Array[String] {
  let values : Array[String] = []
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return values
  }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => Bytes::default()
    },
  )
  let section_lower = section.to_lower()
  let key_lower = key.to_lower()
  let blocks = @gitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some(section_lower) {
      continue
    }
    for line in block.lines {
      match @gitlib.parse_config_kv(line) {
        Some((parsed_key, parsed_value)) =>
          if parsed_key == key_lower {
            values.push(parsed_value)
          }
        None => ()
      }
    }
  }
  values
}

///|
fn read_hide_refs(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  sections : Array[String],
) -> Array[String] {
  let patterns : Array[String] = []
  for section in sections {
    let values = read_config_values(fs, git_dir, section, "hiderefs")
    for value in values {
      patterns.push(value)
    }
  }
  patterns
}

///|
fn prune_source_ref_for_destination(
  src_pattern : String,
  dst_pattern : String,
  dst_ref : String,
) -> String? {
  @gitlib.refspec_map_dst(dst_pattern, src_pattern, dst_ref)
}

///|
fn parse_push_default_mode(value : String?) -> PushDefaultMode {
  match value {
    Some(v) =>
      match v.to_lower() {
        "upstream" => PushDefaultMode::Upstream
        "current" => PushDefaultMode::Current
        "matching" => PushDefaultMode::Matching
        "nothing" => PushDefaultMode::Nothing
        _ => PushDefaultMode::Simple
      }
    None => PushDefaultMode::Simple
  }
}

///|
fn resolve_remote_push_refmap_destination(
  source_token : String,
  source_ref : String,
  current_branch : String,
  remote_push_specs : Array[String],
) -> String? {
  let source_candidates = fetch_source_candidates(source_token)
  if not(source_candidates.contains(source_ref)) {
    source_candidates.push(source_ref)
  }
  if source_ref == "HEAD" {
    let current_ref = "refs/heads/" + current_branch
    if not(source_candidates.contains(current_ref)) {
      source_candidates.push(current_ref)
    }
  }
  let parsed_specs = @gitlib.parse_push_refspecs(remote_push_specs)
  for spec in parsed_specs {
    if spec.src.length() == 0 || spec.dst.length() == 0 {
      continue
    }
    for source_candidate in source_candidates {
      match @gitlib.refspec_map_dst(spec.src, spec.dst, source_candidate) {
        Some(mapped) => return Some(mapped)
        None => ()
      }
    }
  }
  None
}

///|
fn infer_colonless_push_destination_token(
  source_token : String,
  source_ref : String,
  source_kind : PushSourceKind,
  current_branch : String,
  push_default_mode : PushDefaultMode,
  branch_merge : String?,
  remote_push_specs : Array[String],
) -> String {
  match
    resolve_remote_push_refmap_destination(
      source_token, source_ref, current_branch, remote_push_specs,
    ) {
    Some(mapped) => mapped
    None => {
      let source_is_current_branch = source_ref == "HEAD" ||
        source_ref == "refs/heads/" + current_branch
      let source_is_branch = match source_kind {
        PushSourceKind::Branch => true
        _ => false
      }
      let mode_is_upstream = match push_default_mode {
        PushDefaultMode::Upstream => true
        _ => false
      }
      if mode_is_upstream && source_is_branch && source_is_current_branch {
        match branch_merge {
          Some(merge_ref) => merge_ref
          None => source_token
        }
      } else {
        source_token
      }
    }
  }
}

///|
fn parse_config_bool_string(value : String?) -> Bool {
  match value {
    Some(v) => {
      let lower = v.to_lower()
      lower == "true" || lower == "1" || lower == "yes"
    }
    None => false
  }
}

///|
fn looks_like_object_id(token : String) -> Bool {
  ignore(@git.ObjectId::from_hex(token) catch { _ => return false })
  true
}

///|
fn fetch_source_candidates(source : String) -> Array[String] {
  let candidates : Array[String] = [source]
  if source.length() == 0 ||
    source.contains("*") ||
    source.has_prefix("refs/") ||
    source == "HEAD" ||
    source == "@" ||
    looks_like_object_id(source) {
    return candidates
  }
  candidates.push("refs/heads/" + source)
  candidates.push("refs/tags/" + source)
  candidates
}

///|
fn normalize_push_ref_token(
  token : String,
  current_branch : String,
  for_destination : Bool,
) -> String {
  if token == "HEAD" || token == "@" {
    if for_destination {
      "refs/heads/" + current_branch
    } else {
      "HEAD"
    }
  } else if token.has_prefix("refs/") {
    token
  } else if not(for_destination) &&
    (token.contains("^") || token.contains("~") || looks_like_object_id(token)) {
    token
  } else {
    "refs/heads/" + token
  }
}

///|
fn select_current_like_remote(
  remotes : Array[String],
  branch_remote : String?,
  remote_pushdefault : String?,
) -> String raise @git.GitError {
  match remote_pushdefault {
    Some(name) => name
    None =>
      match branch_remote {
        Some(name) => name
        None =>
          if remotes.length() == 1 {
            remotes[0]
          } else if remotes.contains("origin") {
            "origin"
          } else {
            raise @git.GitError::InvalidObject("No such remote: origin")
          }
      }
  }
}

///|
fn parse_remote_helper_url(url : String) -> (String, String)? {
  match url.find("::") {
    Some(idx) =>
      if idx == 0 || idx + 2 >= url.length() {
        None
      } else {
        Some(
          (
            String::unsafe_substring(url, start=0, end=idx),
            String::unsafe_substring(url, start=idx + 2, end=url.length()),
          ),
        )
      }
    None => None
  }
}

///|
fn read_url_rewrite_rules(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[(String, String, Bool)] {
  let config_path = git_dir + "/config"
  let rules : Array[(String, String, Bool)] = []
  if not(fs.is_file(config_path)) {
    return rules
  }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => Bytes::default()
    },
  )
  let blocks = @gitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some("url") {
      continue
    }
    guard block.name is Some(base) else { continue }
    for line in block.lines {
      match @gitlib.parse_config_kv(line) {
        Some((key, value)) =>
          if key == "insteadof" {
            rules.push((base, value, false))
          } else if key == "pushinsteadof" {
            rules.push((base, value, true))
          }
        None => ()
      }
    }
  }
  rules
}

///|
fn rewrite_url_by_rules(
  url : String,
  rules : Array[(String, String, Bool)],
  for_push : Bool,
) -> String {
  let mut best_base : String? = None
  let mut best_prefix_len = -1
  let mut best_push_only = false
  for i in 0..<rules.length() {
    let (base, prefix, push_only) = rules[i]
    if push_only && not(for_push) {
      continue
    }
    if not(url.has_prefix(prefix)) {
      continue
    }
    let prefix_len = prefix.length()
    if prefix_len > best_prefix_len ||
      (prefix_len == best_prefix_len && push_only && not(best_push_only)) {
      best_base = Some(base)
      best_prefix_len = prefix_len
      best_push_only = push_only
    }
  }
  match best_base {
    Some(base) =>
      if best_prefix_len < 0 || best_prefix_len >= url.length() {
        base
      } else {
        base +
        String::unsafe_substring(url, start=best_prefix_len, end=url.length())
      }
    None => url
  }
}

///|
fn branch_name_from_head_ref(refname : String) -> String? {
  if refname.has_prefix("refs/heads/") {
    Some(String::unsafe_substring(refname, start=11, end=refname.length()))
  } else {
    None
  }
}

///|
fn resolve_push_target_plan(
  explicit_remote : String?,
  explicit_refspec : String?,
  current_branch : String,
  remotes : Array[String],
  branch_remote : String?,
  branch_merge : String?,
  push_default : String?,
  remote_pushdefault : String?,
  auto_setup_remote : Bool,
) -> PushTargetPlan raise @git.GitError {
  let mode = parse_push_default_mode(push_default)
  let mode_is_upstream = match mode {
    PushDefaultMode::Upstream => true
    _ => false
  }
  let mode_is_nothing = match mode {
    PushDefaultMode::Nothing => true
    _ => false
  }
  let current_ref = "refs/heads/" + current_branch
  let triangular = match (remote_pushdefault, branch_remote) {
    (Some(pushdefault), Some(upstream_remote)) => pushdefault != upstream_remote
    _ => false
  }
  if explicit_refspec is Some(spec) {
    let remote_name = match explicit_remote {
      Some(name) => name
      None =>
        match mode {
          PushDefaultMode::Upstream =>
            match branch_remote {
              Some(name) => name
              None =>
                raise @git.GitError::InvalidObject(
                  "No upstream configured for current branch",
                )
            }
          PushDefaultMode::Simple if not(triangular) =>
            match branch_remote {
              Some(name) => name
              None =>
                raise @git.GitError::InvalidObject(
                  "No upstream configured for current branch",
                )
            }
          PushDefaultMode::Nothing =>
            raise @git.GitError::InvalidObject(
              "push.default is set to nothing; specify a refspec",
            )
          _ =>
            select_current_like_remote(
              remotes, branch_remote, remote_pushdefault,
            )
        }
    }
    if mode_is_upstream &&
      explicit_remote is Some(requested) &&
      branch_remote is Some(upstream_remote) &&
      requested != upstream_remote {
      raise @git.GitError::InvalidObject(
        "Cannot push to remote '\{requested}' because branch tracks '\{upstream_remote}'",
      )
    }
    let (raw_src_raw, raw_dst) = @gitlib.parse_refspec_pair(spec)
    let raw_src = strip_push_force_prefix(raw_src_raw)
    if raw_src.length() == 0 && raw_dst.length() == 0 {
      return {
        remote_name,
        source_ref: current_ref,
        dest_ref: current_ref,
        auto_set_upstream: false,
        delete_ref: false,
      }
    }
    if looks_like_object_id(raw_src) &&
      raw_dst.length() > 0 &&
      not(raw_dst.has_prefix("refs/")) {
      raise @git.GitError::InvalidObject(
        "Cannot infer destination ref from source object id",
      )
    }
    if raw_src.length() == 0 && raw_dst.length() > 0 {
      let dest_ref = normalize_push_ref_token(raw_dst, current_branch, true)
      return {
        remote_name,
        source_ref: "",
        dest_ref,
        auto_set_upstream: false,
        delete_ref: true,
      }
    }
    guard raw_src.length() > 0 else {
      raise @git.GitError::InvalidObject("Perhaps you should specify a branch.")
    }
    let source_ref = normalize_push_ref_token(raw_src, current_branch, false)
    let dest_ref = if raw_dst.length() == 0 {
      normalize_push_ref_token(raw_src, current_branch, true)
    } else {
      normalize_push_ref_token(raw_dst, current_branch, true)
    }
    return {
      remote_name,
      source_ref,
      dest_ref,
      auto_set_upstream: false,
      delete_ref: false,
    }
  }
  if mode_is_nothing {
    raise @git.GitError::InvalidObject(
      "push.default is set to nothing; specify a refspec",
    )
  }
  if mode_is_upstream && explicit_remote is None && triangular {
    raise @git.GitError::InvalidObject(
      "Cannot use upstream push.default in triangular workflow",
    )
  }
  let remote_name = match explicit_remote {
    Some(name) => name
    None =>
      match mode {
        PushDefaultMode::Upstream =>
          match branch_remote {
            Some(name) => name
            None =>
              raise @git.GitError::InvalidObject(
                "No upstream configured for current branch",
              )
          }
        PushDefaultMode::Simple if not(triangular) =>
          match branch_remote {
            Some(name) => name
            None =>
              raise @git.GitError::InvalidObject(
                "No upstream configured for current branch",
              )
          }
        _ =>
          select_current_like_remote(remotes, branch_remote, remote_pushdefault)
      }
  }
  if mode_is_upstream &&
    explicit_remote is Some(requested) &&
    branch_remote is Some(upstream_remote) &&
    requested != upstream_remote {
    raise @git.GitError::InvalidObject(
      "Cannot push to remote '\{requested}' because branch tracks '\{upstream_remote}'",
    )
  }
  let mut dest_ref = current_ref
  let mut auto_set_upstream_needed = false
  match mode {
    PushDefaultMode::Upstream =>
      match branch_merge {
        Some(merge_ref) => dest_ref = merge_ref
        None =>
          if auto_setup_remote && branch_remote is Some(_) {
            auto_set_upstream_needed = true
          } else {
            raise @git.GitError::InvalidObject(
              "No upstream configured for current branch",
            )
          }
      }
    PushDefaultMode::Simple =>
      if triangular && explicit_remote is None {
        dest_ref = current_ref
      } else {
        match branch_merge {
          Some(merge_ref) =>
            if merge_ref != current_ref {
              raise @git.GitError::InvalidObject(
                "Simple push requires upstream branch name to match current branch",
              )
            } else {
              dest_ref = merge_ref
            }
          None =>
            if auto_setup_remote && branch_remote is Some(_) {
              auto_set_upstream_needed = true
            } else {
              raise @git.GitError::InvalidObject(
                "No upstream configured for current branch",
              )
            }
        }
      }
    PushDefaultMode::Matching =>
      if branch_merge is None {
        raise @git.GitError::InvalidObject(
          "Perhaps you should specify a branch.",
        )
      }
    _ => ()
  }
  {
    remote_name,
    source_ref: current_ref,
    dest_ref,
    auto_set_upstream: auto_set_upstream_needed,
    delete_ref: false,
  }
}

///|
fn resolve_push_positionals(
  positionals : Array[String],
  is_known_remote : (String) -> Bool,
) -> (String?, String?) {
  if positionals.length() == 0 {
    (None, None)
  } else if positionals.length() == 1 {
    let first = positionals[0]
    if is_known_remote(first) {
      (Some(first), None)
    } else {
      (None, Some(first))
    }
  } else {
    (Some(positionals[0]), Some(positionals[positionals.length() - 1]))
  }
}

///|
fn resolve_push_positionals_multi(
  positionals : Array[String],
  is_known_remote : (String) -> Bool,
) -> (String?, Array[String]) {
  if positionals.length() == 0 {
    (None, [])
  } else if positionals.length() == 1 {
    let first = positionals[0]
    if is_known_remote(first) {
      (Some(first), [])
    } else {
      (None, [first])
    }
  } else {
    let refspecs : Array[String] = []
    for i in 1..<positionals.length() {
      refspecs.push(positionals[i])
    }
    (Some(positionals[0]), refspecs)
  }
}

///|
fn parse_push_refspecs_with_presence(
  specs : Array[String],
) -> Array[PushParsedRefspec] {
  let out : Array[PushParsedRefspec] = []
  for raw in specs {
    let mut force = false
    let mut value = raw
    if value.has_prefix("+") {
      force = true
      value = String::unsafe_substring(value, start=1, end=value.length())
    }
    let has_explicit_destination = value.find(":") is Some(_)
    let (src, dst) = @gitlib.parse_refspec_pair(value)
    out.push({ force, src, dst, has_explicit_destination })
  }
  out
}

///|
fn ensure_matching_refspec_has_candidates(
  parsed_specs : Array[PushParsedRefspec],
  plan_count : Int,
) -> Unit raise @git.GitError {
  if plan_count > 0 {
    return ()
  }
  for spec in parsed_specs {
    if spec.src.length() == 0 && spec.dst.length() == 0 {
      raise @git.GitError::InvalidObject("Perhaps you should specify a branch.")
    }
  }
}

///|
fn strip_push_force_prefix(source_spec : String) -> String {
  if source_spec.has_prefix("+") {
    String::unsafe_substring(source_spec, start=1, end=source_spec.length())
  } else {
    source_spec
  }
}

///|
fn option_name_without_prefix(arg : String) -> String {
  if arg.has_prefix("--") {
    String::unsafe_substring(arg, start=2, end=arg.length())
  } else if arg.has_prefix("-") {
    String::unsafe_substring(arg, start=1, end=arg.length())
  } else {
    arg
  }
}

///|
fn is_ambiguous_push_source_refspec(
  source_spec : String,
  has_head_ref : Bool,
  has_tag_ref : Bool,
) -> Bool {
  if source_spec.length() == 0 ||
    source_spec == "HEAD" ||
    source_spec == "@" ||
    source_spec.has_prefix("refs/") ||
    source_spec.contains("^") ||
    source_spec.contains("~") ||
    source_spec.contains(":") {
    false
  } else {
    has_head_ref && has_tag_ref
  }
}

///|
fn resolve_push_source_ref(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  source_token : String,
) -> (String, PushSourceKind) raise @git.GitError {
  if source_token == "HEAD" || source_token == "@" {
    ("HEAD", PushSourceKind::Branch)
  } else if source_token.has_prefix("refs/") {
    if source_token.has_prefix("refs/tags/") {
      (source_token, PushSourceKind::Tag)
    } else if source_token.has_prefix("refs/heads/") {
      (source_token, PushSourceKind::Branch)
    } else {
      (source_token, PushSourceKind::Other)
    }
  } else if source_token.contains("^") ||
    source_token.contains("~") ||
    looks_like_object_id(source_token) {
    (source_token, PushSourceKind::Other)
  } else {
    let branch_ref = "refs/heads/" + source_token
    if @gitlib.resolve_ref(fs, git_dir, branch_ref) is Some(_) {
      (branch_ref, PushSourceKind::Branch)
    } else {
      let tag_ref = "refs/tags/" + source_token
      if @gitlib.resolve_ref(fs, git_dir, tag_ref) is Some(_) {
        (tag_ref, PushSourceKind::Tag)
      } else {
        ("refs/heads/" + source_token, PushSourceKind::Branch)
      }
    }
  }
}

///|
fn resolve_push_source_id(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  source_ref : String,
) -> @git.ObjectId raise @git.GitError {
  match source_ref {
    "HEAD" =>
      match @gitlib.resolve_head_commit(fs, git_dir) {
        Some(id) => id
        None => raise @git.GitError::InvalidObject("HEAD not found")
      }
    _ =>
      match @gitlib.resolve_ref(fs, git_dir, source_ref) {
        Some(id) => id
        None =>
          match @gitrepo.rev_parse(fs, git_dir, source_ref) {
            Some(id) => id
            None =>
              if looks_like_object_id(source_ref) {
                @git.ObjectId::from_hex(source_ref) catch {
                  _ =>
                    raise @git.GitError::InvalidObject(
                      "Cannot resolve source ref: " + source_ref,
                    )
                }
              } else {
                raise @git.GitError::InvalidObject(
                  "Cannot resolve source ref: " + source_ref,
                )
              }
          }
      }
  }
}

///|
fn is_invalid_push_destination_refname(
  refname : String,
  allow_onelevel : Bool,
) -> Bool {
  if not(refname.has_prefix("refs/")) {
    return true
  }
  let rest = String::unsafe_substring(refname, start=5, end=refname.length())
  if rest.length() == 0 || rest.has_suffix("/") {
    return true
  }
  if not(allow_onelevel) && not(rest.contains("/")) {
    return true
  }
  false
}

///|
fn resolve_push_destination_ref(
  fs : &@git.RepoFileSystem,
  remote_git_dir : String,
  source_kind : PushSourceKind,
  destination_token : String,
  current_branch : String,
  allow_onelevel : Bool,
  prefer_source_kind : Bool,
) -> String raise @git.GitError {
  if destination_token == "HEAD" || destination_token == "@" {
    return "refs/heads/" + current_branch
  }
  if destination_token.has_prefix("refs/") {
    if is_invalid_push_destination_refname(destination_token, allow_onelevel) {
      raise @git.GitError::InvalidObject(
        "Invalid refspec destination: " + destination_token,
      )
    }
    return destination_token
  }
  let candidate_heads = "refs/heads/" + destination_token
  let candidate_tags = "refs/tags/" + destination_token
  let candidate_remotes = "refs/remotes/" + destination_token
  let matched : Array[String] = []
  if @gitlib.resolve_ref(fs, remote_git_dir, candidate_heads) is Some(_) {
    matched.push(candidate_heads)
  }
  if @gitlib.resolve_ref(fs, remote_git_dir, candidate_tags) is Some(_) {
    matched.push(candidate_tags)
  }
  if @gitlib.resolve_ref(fs, remote_git_dir, candidate_remotes) is Some(_) {
    matched.push(candidate_remotes)
  }
  if matched.length() > 1 {
    if prefer_source_kind {
      match source_kind {
        PushSourceKind::Branch =>
          if matched.contains(candidate_heads) {
            return candidate_heads
          }
        PushSourceKind::Tag =>
          if matched.contains(candidate_tags) {
            return candidate_tags
          }
        _ => ()
      }
    }
    raise @git.GitError::InvalidObject(
      "dst refspec '\{destination_token}' matches more than one",
    )
  }
  if matched.length() == 1 {
    return matched[0]
  }
  match source_kind {
    PushSourceKind::Tag => candidate_tags
    _ => candidate_heads
  }
}

///|
fn read_branch_pushremote(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  branch_name : String,
) -> String? {
  let content = @gitlib.read_config_content(fs, git_dir)
  let blocks = @gitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some("branch") || block.name != Some(branch_name) {
      continue
    }
    for line in block.lines {
      match @gitlib.parse_config_kv(line) {
        Some((key, value)) if key == "pushremote" => return Some(value)
        _ => ()
      }
    }
  }
  None
}

///|
fn ensure_no_empty_branch_config(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Unit raise @git.GitError {
  let content = @gitlib.read_config_content(rfs, git_dir)
  let blocks = @gitlib.parse_config_blocks(content)
  let filtered : Array[@gitlib.ConfigBlock] = []
  let mut found_invalid = false
  for block in blocks {
    if block.section == Some("branch") && block.name == Some("") {
      found_invalid = true
      continue
    }
    filtered.push(block)
  }
  if found_invalid {
    let config_path = git_dir + "/config"
    fs.write_string(config_path, @gitlib.render_config_blocks(filtered))
    raise @git.GitError::InvalidObject("bad config variable .branch..")
  }
}

///|
enum DenyCurrentBranchDecision {
  Allow
  Warn
  UpdateInstead(String)
}

///|
fn enforce_receive_deny_current_branch(
  deny_current_branch : String?,
  checked_out_worktree : String?,
  dest_ref : String,
) -> DenyCurrentBranchDecision raise @git.GitError {
  guard checked_out_worktree is Some(worktree_path) else {
    return DenyCurrentBranchDecision::Allow
  }
  match deny_current_branch {
    Some(mode) =>
      if mode == "false" || mode == "ignore" {
        DenyCurrentBranchDecision::Allow
      } else if mode == "warn" {
        DenyCurrentBranchDecision::Warn
      } else if mode == "updateinstead" {
        DenyCurrentBranchDecision::UpdateInstead(worktree_path)
      } else {
        raise @git.GitError::InvalidObject(
          "refusing to update checked out branch: " + dest_ref,
        )
      }
    None =>
      raise @git.GitError::InvalidObject(
        "refusing to update checked out branch: " + dest_ref,
      )
  }
}

///|
struct PushResolvedUpdate {
  old_id : @git.ObjectId
  new_id : @git.ObjectId
  refname : String
  delete_ref : Bool
  should_apply : Bool
  update_instead_worktree : String?
}

///|
fn is_invalid_nonexistent_delete(row : PushResolvedUpdate) -> Bool {
  row.delete_ref &&
  row.old_id == @git.ObjectId::zero() &&
  row.new_id == @git.ObjectId::zero()
}

///|
fn resolve_ref_canonical_name_inner(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
  depth : Int,
) -> String {
  if depth > 8 {
    return refname
  }
  let path = git_dir + "/" + refname
  if not(fs.is_file(path)) {
    return refname
  }
  let line = decode_bytes(fs.read_file(path) catch { _ => return refname })
    .trim()
    .to_string()
  if not(line.has_prefix("ref: ")) {
    return refname
  }
  let target = String::unsafe_substring(line, start=5, end=line.length())
  resolve_ref_canonical_name_inner(fs, git_dir, target, depth + 1)
}

///|
fn resolve_ref_canonical_name(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> String {
  resolve_ref_canonical_name_inner(fs, git_dir, refname, 0)
}

///|
fn ensure_consistent_alias_updates(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  rows : Array[PushResolvedUpdate],
) -> Unit raise @git.GitError {
  let canonical_updates : Map[String, (@git.ObjectId, String)] = {}
  for row in rows {
    let canonical = resolve_ref_canonical_name(fs, git_dir, row.refname)
    match canonical_updates.get(canonical) {
      Some((known_id, known_refname)) =>
        if known_id != row.new_id {
          raise @git.GitError::InvalidObject(
            "refusing inconsistent update: " +
            known_refname +
            " and " +
            row.refname,
          )
        }
      None => canonical_updates[canonical] = (row.new_id, row.refname)
    }
  }
}

///|
fn order_pre_receive_rows(
  rows : Array[PushResolvedUpdate],
) -> Array[PushResolvedUpdate] {
  let existing_or_nondelete : Array[PushResolvedUpdate] = []
  let nonexistent_deletes : Array[PushResolvedUpdate] = []
  for row in rows {
    if is_invalid_nonexistent_delete(row) {
      nonexistent_deletes.push(row)
    } else {
      existing_or_nondelete.push(row)
    }
  }
  existing_or_nondelete.sort_by(fn(a, b) { a.refname.compare(b.refname) })
  let ordered : Array[PushResolvedUpdate] = []
  for row in existing_or_nondelete {
    ordered.push(row)
  }
  for row in nonexistent_deletes {
    ordered.push(row)
  }
  ordered
}

///|
fn order_update_rows(
  rows : Array[PushResolvedUpdate],
) -> Array[PushResolvedUpdate] {
  let deletes : Array[PushResolvedUpdate] = []
  let updates : Array[PushResolvedUpdate] = []
  for row in rows {
    if row.delete_ref {
      deletes.push(row)
    } else {
      updates.push(row)
    }
  }
  let ordered : Array[PushResolvedUpdate] = []
  for row in deletes {
    ordered.push(row)
  }
  for row in updates {
    ordered.push(row)
  }
  ordered
}

///|
fn format_push_hook_line(row : PushResolvedUpdate) -> String {
  row.old_id.to_hex() + " " + row.new_id.to_hex() + " " + row.refname
}

///|
fn resolve_push_hook_git_dir(git_dir : String) -> String {
  if git_dir.has_prefix("/") {
    return git_dir
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  normalize_path(cwd + "/" + git_dir)
}

///|
async fn run_push_hook_with_stdin(
  fs : OsFs,
  git_dir : String,
  hook_name : String,
  lines : Array[String],
) -> Int {
  let hook_git_dir = resolve_push_hook_git_dir(git_dir)
  let hook_path = hook_git_dir + "/hooks/" + hook_name
  if not(fs.is_file(hook_path)) {
    return 0
  }
  let stdin_path = hook_git_dir +
    "/hooks/.bit-" +
    hook_name +
    "-" +
    @async.now().to_string() +
    ".stdin"
  let text = if lines.length() > 0 { lines.join("\n") + "\n" } else { "" }
  fs.write_string(stdin_path, text) catch {
    _ => return 1
  }
  let stdin = @process.redirect_from_file(stdin_path) catch {
    _ => {
      fs.remove_file(stdin_path) catch {
        _ => ()
      }
      return 1
    }
  }
  let code = @process.run(
    hook_path,
    [],
    inherit_env=true,
    stdin~,
    cwd=hook_git_dir,
  ) catch {
    _ => 1
  }
  fs.remove_file(stdin_path) catch {
    _ => ()
  }
  code
}

///|
async fn run_push_hook_with_args(
  fs : OsFs,
  git_dir : String,
  hook_name : String,
  args : Array[String],
) -> Int {
  let hook_git_dir = resolve_push_hook_git_dir(git_dir)
  let hook_path = hook_git_dir + "/hooks/" + hook_name
  if not(fs.is_file(hook_path)) {
    return 0
  }
  @process.run(hook_path, args, inherit_env=true, cwd=hook_git_dir) catch {
    _ => 1
  }
}

///|
fn is_worktree_status_clean(status : @gitlib.Status) -> Bool {
  status.staged_added.length() == 0 &&
  status.staged_modified.length() == 0 &&
  status.staged_deleted.length() == 0 &&
  status.unstaged_modified.length() == 0 &&
  status.unstaged_deleted.length() == 0 &&
  status.untracked.length() == 0
}

///|
async fn apply_update_instead_worktree(
  fs : OsFs,
  repo_git_dir : String,
  worktree_path : String,
  new_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let status = @gitlib.status(fs, worktree_path)
  if not(is_worktree_status_clean(status)) {
    raise @git.GitError::InvalidObject("working tree has pending changes")
  }
  let worktree_git_dir = match @gitlib.detect_git_dir(fs, worktree_path) {
    Some((dir, _)) => dir
    None => repo_git_dir
  }
  let db = @gitlib.ObjectDb::load(fs, repo_git_dir)
  let files = @gitlib.collect_tree_files_from_commit(db, fs, new_id)
  @gitlib.write_worktree_from_files(
    db,
    fs,
    fs,
    worktree_path,
    worktree_git_dir,
    files,
    remove_missing=true,
  )
  let entries = @gitlib.tree_files_to_index(db, fs, files)
  @gitlib.write_index_entries(fs, worktree_git_dir, entries)
}

///|
async fn run_push_to_checkout_hook(
  fs : OsFs,
  git_dir : String,
  worktree_path : String,
  new_id : @git.ObjectId,
) -> Int {
  let hook_git_dir = resolve_push_hook_git_dir(git_dir)
  let hook_path = hook_git_dir + "/hooks/push-to-checkout"
  if not(fs.is_file(hook_path)) {
    return -1
  }
  let worktree_git_dir = match @gitlib.detect_git_dir(fs, worktree_path) {
    Some((dir, _)) => resolve_push_hook_git_dir(dir)
    None => hook_git_dir
  }
  let extra_env : Map[String, String] = {}
  extra_env["GIT_SHIM_PWD"] = worktree_path
  extra_env["GIT_SHIM_CWD"] = worktree_path
  extra_env["GIT_DIR"] = worktree_git_dir
  extra_env["GIT_WORK_TREE"] = worktree_path
  extra_env["GIT_COMMON_DIR"] = hook_git_dir
  let code = @process.run(
    hook_path,
    [new_id.to_hex()],
    extra_env~,
    inherit_env=true,
    cwd=worktree_path,
  ) catch {
    _ => 1
  }
  code
}

///|
