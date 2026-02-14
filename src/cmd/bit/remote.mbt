///| Remote operation handlers: remote, upload-pack, receive-pack, fetch, pull, push, clone

///|
/// Parse clone shorthand or GitHub browser URL
pub fn parse_github_shorthand(url : String) -> @gitlib.GitHubShorthand? {
  @gitlib.parse_github_shorthand(url)
}

///|
/// Check if shorthand conflicts with local directory
/// Returns the conflicting path if ambiguous
pub fn check_shorthand_ambiguity(
  url : String,
  dir_exists : (String) -> Bool,
) -> String? {
  @gitlib.check_shorthand_ambiguity(url, dir_exists)
}

///|
async fn resolve_remote_ref_id(
  remote_url : String,
  ref_spec : String,
) -> (@git.ObjectId, String?)? raise Error {
  @gitlibnative.resolve_remote_ref_id(remote_url, ref_spec)
}

///|
/// Fetch a raw file from URL and save to local path
async fn fetch_raw_file(url : String, target : String) -> Unit raise Error {
  let root = get_work_root()
  let target_path = if target.has_prefix("/") {
    target
  } else {
    root + "/" + target
  }
  // Use HTTP fetch
  let headers : Map[String, String] = {}
  let (response, content) = @gitionative.native_http_get(url, headers)
  if response.code != 200 {
    raise @git.GitError::InvalidObject(
      "HTTP \{response.code}: failed to fetch \{url}",
    )
  }
  // Write to file
  let fs = OsFs::new()
  fs.write_file(target_path, content)
  print_line("Saved to '\{target}'")
}

///|
async fn die_remote(code : Int, msg : String) -> Unit {
  eprint_line(msg)
  @sys.exit(code)
}

///|
fn emit_trace_region(
  category : String,
  label : String,
) -> Unit raise @git.GitError {
  let path = @sys.get_env_var("GIT_TRACE2_EVENT")
  guard path is Some(target) else { return () }
  let enter = "{\"event\":\"region_enter\",\"category\":\"" +
    category +
    "\",\"label\":\"" +
    label +
    "\"}\n"
  let leave = "{\"event\":\"region_leave\",\"category\":\"" +
    category +
    "\",\"label\":\"" +
    label +
    "\"}\n"
  let fs = OsFs::new()
  if fs.is_file(target) {
    let existing = decode_bytes(
      fs.read_file(target) catch {
        _ => Bytes::default()
      },
    )
    fs.write_string(target, existing + enter + leave)
  } else {
    fs.write_string(target, enter + leave)
  }
}

///|
fn append_text_file(fs : OsFs, path : String, text : String) -> Unit {
  let current = decode_bytes(fs.read_file(path) catch { _ => Bytes::default() })
  fs.write_string(path, current + text) catch {
    _ => ()
  }
}

///|
fn emit_push_trace_event(fs : OsFs, key : String, value : String) -> Unit {
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) => {
      let line = "{\"event\":\"data\",\"key\":\"" +
        key +
        "\",\"value\":\"" +
        value +
        "\"}\n"
      append_text_file(fs, path, line)
    }
    None => ()
  }
}

///|
fn emit_push_trace_subcommand(fs : OsFs, argv : Array[String]) -> Unit {
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) => {
      let encoded : Array[String] = []
      for arg in argv {
        encoded.push("\"" + arg + "\"")
      }
      append_text_file(fs, path, "[" + encoded.join(",") + "]\n")
    }
    None => ()
  }
}

///|
fn is_empty_dir(rfs : &@git.RepoFileSystem, path : String) -> Bool {
  let entries = rfs.readdir(path) catch { _ => return false }
  for entry in entries {
    if entry != "." && entry != ".." {
      return false
    }
  }
  true
}

///|
fn prune_empty_parent_dirs(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  path : String,
  stop_dir : String,
) -> Unit {
  let mut current = parent_dir(path)
  while current.length() > 0 &&
        current != stop_dir &&
        current.has_prefix(stop_dir + "/") {
    if not(rfs.is_dir(current)) {
      break
    }
    if not(is_empty_dir(rfs, current)) {
      break
    }
    fs.remove_dir(current) catch {
      _ => break
    }
    current = parent_dir(current)
  }
}

///|
fn ref_namespace_root(refname : String) -> String {
  if not(refname.has_prefix("refs/")) {
    "refs"
  } else {
    let mut i = 0
    for part_view in refname.split("/") {
      let part = part_view.to_string()
      if i == 1 {
        if part.length() > 0 {
          return "refs/" + part
        }
        return "refs"
      }
      i += 1
    }
    "refs"
  }
}

///|
async fn handle_remote(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let (git_dir, is_bare_repo) = match @gitlib.detect_git_dir(fs, root) {
    Some((dir, bare)) => (dir, bare)
    None => (root + "/.git", false)
  }
  ignore(is_bare_repo)
  if args.length() == 0 {
    // List remotes
    let remotes = @gitlib.list_remotes(fs, git_dir)
    for name in remotes {
      print_line(name)
    }
    return ()
  }
  let subcmd = args[0]
  match subcmd {
    "add" => {
      let mut fetch_after_add = false
      let mut mirror_mode : String? = None
      let mut tagopt : String? = None
      let mut master_branch : String? = None
      let track_branches : Array[String] = []
      let positional : Array[String] = []
      let mut i = 1
      let mut in_opts = true
      while i < args.length() {
        let arg = args[i]
        if in_opts && arg == "--" {
          in_opts = false
          i += 1
          continue
        }
        if in_opts {
          match arg {
            "-f" | "--fetch" => fetch_after_add = true
            "--mirror" =>
              match mirror_mode {
                None => mirror_mode = Some("mirror")
                Some(_) => die_remote(129, "usage: git remote add <name> <url>")
              }
            _ if arg.has_prefix("--mirror=") => {
              let mode = String::unsafe_substring(
                arg,
                start=9,
                end=arg.length(),
              )
              match mode {
                "fetch" | "push" =>
                  match mirror_mode {
                    None => mirror_mode = Some(mode)
                    Some(_) =>
                      die_remote(129, "usage: git remote add <name> <url>")
                  }
                _ => die_remote(129, "usage: git remote add <name> <url>")
              }
            }
            "--tags" => tagopt = Some("--tags")
            "--no-tags" => tagopt = Some("--no-tags")
            "-m" | "--master" =>
              if i + 1 < args.length() {
                master_branch = Some(args[i + 1])
                i += 1
              } else {
                die_remote(129, "usage: git remote add <name> <url>")
              }
            _ if arg.has_prefix("--master=") =>
              master_branch = Some(
                String::unsafe_substring(arg, start=9, end=arg.length()),
              )
            "-t" | "--track" =>
              if i + 1 < args.length() {
                track_branches.push(args[i + 1])
                i += 1
              } else {
                die_remote(129, "usage: git remote add <name> <url>")
              }
            _ if arg.has_prefix("-") =>
              die_remote(129, "usage: git remote add <name> <url>")
            _ => positional.push(arg)
          }
        } else {
          positional.push(arg)
        }
        i += 1
      }
      if positional.length() != 2 {
        die_remote(129, "usage: git remote add <name> <url>")
      }
      let name = positional[0]
      let url = positional[1]
      if (name |> @gitlib.is_valid_remote_name |> not) {
        die_remote(1, "fatal: '\{name}' is not a valid remote name")
      }
      let blocks = @gitlib.parse_config_blocks(
        @gitlib.read_config_content(fs, git_dir),
      )
      if @gitlib.config_has_remote_section(blocks, name) ||
        @gitlib.legacy_remote_exists(fs, git_dir, name) {
        die_remote(3, "error: remote \{name} already exists.")
      }
      let existing_remotes : Array[String] = []
      for block in blocks {
        if block.section == Some("remote") && block.name is Some(rn) {
          existing_remotes.push(rn)
        }
      }
      for existing in existing_remotes {
        if existing == name {
          continue
        }
        if name.has_prefix(existing + "/") {
          die_remote(
            3,
            "error: remote name '\{name}' is a subset of existing remote '\{existing}'",
          )
        }
        if existing.has_prefix(name + "/") {
          die_remote(
            3,
            "error: remote name '\{name}' is a superset of existing remote '\{existing}'",
          )
        }
      }
      let mirror_fetch = mirror_mode == Some("mirror") ||
        mirror_mode == Some("fetch")
      let mirror_push = mirror_mode == Some("mirror") ||
        mirror_mode == Some("push")
      if mirror_push && track_branches.length() > 0 {
        die_remote(129, "usage: git remote add <name> <url>")
      }
      let fetch_specs : Array[String] = []
      if mirror_fetch {
        if track_branches.length() > 0 {
          for t in track_branches {
            let src_ref = @gitlib.normalize_track_ref(t)
            fetch_specs.push("+" + src_ref + ":" + src_ref)
          }
        } else {
          fetch_specs.push("+refs/*:refs/*")
        }
      } else if track_branches.length() > 0 {
        for t in track_branches {
          let src_ref = @gitlib.normalize_track_ref(t)
          let short = @gitlib.normalize_remote_branch_name(src_ref)
          fetch_specs.push("+\{src_ref}:refs/remotes/\{name}/\{short}")
        }
      } else {
        fetch_specs.push("+refs/heads/*:refs/remotes/\{name}/*")
      }
      remote_add(
        fs,
        fs,
        git_dir,
        name,
        url,
        fetch_specs,
        mirror_push,
        tagopt,
        master_branch~,
      )
      if fetch_after_add {
        fetch_from_remote(fs, git_dir, root, name, url, [])
      }
    }
    "remove" | "rm" => {
      if args.length() != 2 {
        die_remote(129, "usage: git remote remove <name>")
      }
      let name = args[1]
      let blocks = @gitlib.parse_config_blocks(
        @gitlib.read_config_content(fs, git_dir),
      )
      if not(@gitlib.config_has_remote_section(blocks, name)) &&
        not(@gitlib.legacy_remote_exists(fs, git_dir, name)) {
        die_remote(2, "error: No such remote: '\{name}'")
      }
      remote_remove(fs, fs, git_dir, name)
    }
    "rename" => {
      let mut progress = false
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "--progress" => progress = true
          _ if arg.has_prefix("-") =>
            die_remote(129, "usage: git remote rename <old> <new>")
          _ => positional.push(arg)
        }
      }
      if positional.length() != 2 {
        die_remote(129, "usage: git remote rename <old> <new>")
      }
      let old_name = positional[0]
      let new_name = positional[1]
      if (new_name |> @gitlib.is_valid_remote_name |> not) {
        die_remote(1, "fatal: '\{new_name}' is not a valid remote name")
      }
      let blocks = @gitlib.parse_config_blocks(
        @gitlib.read_config_content(fs, git_dir),
      )
      let old_exists = @gitlib.config_has_remote_section(blocks, old_name) ||
        @gitlib.legacy_remote_exists(fs, git_dir, old_name)
      if not(old_exists) {
        die_remote(2, "error: No such remote: '\{old_name}'")
      }
      let new_exists = @gitlib.config_has_remote_section(blocks, new_name) ||
        @gitlib.legacy_remote_exists(fs, git_dir, new_name)
      if old_name != new_name && new_exists {
        die_remote(3, "error: remote \{new_name} already exists.")
      }
      if progress {
        emit_trace_region("progress", "Renaming remote references") catch {
          err => {
            if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
              raise err
            }
            ()
          }
        }
      }
      remote_rename(fs, fs, git_dir, old_name, new_name)
    }
    "-v" | "--verbose" => {
      // List remotes with URLs
      let remotes = @gitlib.list_remotes_verbose(fs, git_dir)
      for item in remotes {
        let (name, line) = item
        print_line("\{name}\t\{line}")
      }
    }
    "show" => {
      let mut no_query = false
      let targets : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "-n" | "--no-query" => no_query = true
          _ if arg.has_prefix("-") => warn_unimplemented_arg("remote show", arg)
          _ => targets.push(arg)
        }
      }
      let names = if targets.length() > 0 {
        targets
      } else {
        @gitlib.list_remotes(fs, git_dir)
      }
      for i in 0..<names.length() {
        remote_show(fs, git_dir, root, names[i], no_query)
      }
    }
    "get-url" => {
      let mut push = false
      let mut all = false
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "--push" => push = true
          "--all" => all = true
          _ if arg.has_prefix("-") =>
            die_remote(129, "usage: git remote get-url [--push] [--all] <name>")
          _ => positional.push(arg)
        }
      }
      if positional.length() != 1 {
        die_remote(129, "usage: git remote get-url [--push] [--all] <name>")
      }
      let name = positional[0]
      let (remotes, _) = @gitlib.read_repo_config(fs, git_dir)
      match remotes.get(name) {
        Some(rc) => {
          let urls = if push {
            if rc.pushurls.length() > 0 {
              rc.pushurls
            } else {
              rc.urls
            }
          } else {
            rc.urls
          }
          if urls.length() == 0 {
            die_remote(2, "fatal: No such remote: '\{name}'")
          }
          if all {
            for u in urls {
              print_line(u)
            }
          } else {
            print_line(urls[0])
          }
        }
        None => die_remote(2, "fatal: No such remote: '\{name}'")
      }
    }
    "set-url" => {
      let mut push = false
      let mut add = false
      let mut delete = false
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "--push" => push = true
          "--add" => add = true
          "--delete" => delete = true
          _ if arg.has_prefix("-") =>
            die_remote(
              129, "usage: git remote set-url [--push] [--add] [--delete] <name> <newurl> [<oldurl>]",
            )
          _ => positional.push(arg)
        }
      }
      if add && delete {
        die_remote(
          129, "usage: git remote set-url [--push] [--add] [--delete] <name> <newurl> [<oldurl>]",
        )
      }
      if delete {
        if positional.length() != 2 {
          die_remote(
            129, "usage: git remote set-url [--push] [--add] [--delete] <name> <newurl> [<oldurl>]",
          )
        }
        remote_set_url(
          fs,
          fs,
          git_dir,
          positional[0],
          None,
          Some(positional[1]),
          push,
          false,
          true,
        )
      } else if add {
        if positional.length() != 2 {
          die_remote(
            129, "usage: git remote set-url [--push] [--add] [--delete] <name> <newurl> [<oldurl>]",
          )
        }
        remote_set_url(
          fs,
          fs,
          git_dir,
          positional[0],
          Some(positional[1]),
          None,
          push,
          true,
          false,
        )
      } else {
        if positional.length() < 2 || positional.length() > 3 {
          die_remote(
            129, "usage: git remote set-url [--push] [--add] [--delete] <name> <newurl> [<oldurl>]",
          )
        }
        let old_url = if positional.length() == 3 {
          Some(positional[2])
        } else {
          None
        }
        remote_set_url(
          fs,
          fs,
          git_dir,
          positional[0],
          Some(positional[1]),
          old_url,
          push,
          false,
          false,
        )
      }
    }
    "prune" => {
      let mut dry_run = false
      let targets : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "-n" | "--dry-run" => dry_run = true
          _ if arg.has_prefix("-") =>
            warn_unimplemented_arg("remote prune", arg)
          _ => targets.push(arg)
        }
      }
      if targets.length() == 0 {
        raise @git.GitError::InvalidObject("usage: git remote prune <name>")
      }
      for name in targets {
        remote_prune(fs, git_dir, root, name, dry_run)
      }
    }
    "update" => {
      let mut prune = false
      let targets : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "-p" | "--prune" => prune = true
          _ if arg.has_prefix("-") =>
            warn_unimplemented_arg("remote update", arg)
          _ => targets.push(arg)
        }
      }
      remote_update(fs, git_dir, root, targets, prune)
    }
    "set-branches" => {
      let mut add = false
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "--add" => add = true
          _ if arg.has_prefix("-") =>
            die_remote(
              129, "usage: git remote set-branches [--add] <name> <branch>...",
            )
          _ => positional.push(arg)
        }
      }
      if positional.length() == 0 {
        die_remote(
          129, "usage: git remote set-branches [--add] <name> <branch>...",
        )
      }
      let name = positional[0]
      let branches : Array[String] = []
      for i in 1..<positional.length() {
        branches.push(positional[i])
      }
      if branches.length() == 0 {
        die_remote(
          129, "usage: git remote set-branches [--add] <name> <branch>...",
        )
      }
      @gitlib.remote_set_branches(fs, fs, git_dir, name, branches, add)
    }
    "set-head" => {
      let mut mode : String? = None
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "--delete" => mode = Some("delete")
          "--auto" => mode = Some("auto")
          _ if arg.has_prefix("-") =>
            die_remote(129, "usage: git remote set-head <name> <branch>")
          _ => positional.push(arg)
        }
      }
      if positional.length() == 0 {
        die_remote(129, "usage: git remote set-head <name> <branch>")
      }
      let name = positional[0]
      match mode {
        Some("delete") =>
          if positional.length() == 1 {
            remote_set_head_delete(fs, git_dir, name)
          } else {
            die_remote(129, "usage: git remote set-head <name> <branch>")
          }
        Some("auto") =>
          if positional.length() == 1 {
            remote_set_head_auto(fs, git_dir, root, name)
          } else {
            die_remote(129, "usage: git remote set-head <name> <branch>")
          }
        _ =>
          if positional.length() == 2 {
            remote_set_head_explicit(fs, git_dir, name, positional[1])
          } else {
            die_remote(129, "usage: git remote set-head <name> <branch>")
          }
      }
    }
    _ => die_remote(129, "error: unknown subcommand: \{subcmd}")
  }
}

///|

///|
fn remote_add(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  url : String,
  fetch_specs : Array[String],
  mirror : Bool,
  tagopt : String?,
  master_branch? : String? = None,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  if rfs.is_file(config_path + ".lock") {
    raise @git.GitError::InvalidObject("config file is locked")
  }
  let existing = if rfs.is_file(config_path) {
    decode_bytes(rfs.read_file(config_path))
  } else {
    ""
  }
  let blocks = @gitlib.parse_config_blocks(existing)
  if @gitlib.config_has_remote_section(blocks, name) ||
    @gitlib.legacy_remote_exists(rfs, git_dir, name) {
    raise @git.GitError::InvalidObject("remote '\{name}' already exists")
  }
  let lines : Array[String] = []
  lines.push("\turl = \{url}")
  for spec in fetch_specs {
    lines.push("\tfetch = " + spec)
  }
  if mirror {
    lines.push("\tmirror = true")
  }
  if tagopt is Some(val) {
    lines.push("\ttagOpt = " + val)
  }
  let new_blocks = blocks
  new_blocks.push({
    header: Some("[remote \"\{name}\"]"),
    section: Some("remote"),
    name: Some(name),
    lines,
  })
  fs.write_string(config_path, @gitlib.render_config_blocks(new_blocks))
  if master_branch is Some(raw_branch) {
    let branch = if raw_branch.has_prefix("refs/heads/") {
      String::unsafe_substring(raw_branch, start=11, end=raw_branch.length())
    } else {
      raw_branch
    }
    let head_ref = "refs/remotes/" + name + "/HEAD"
    let head_target = "refs/remotes/" + name + "/" + branch
    let head_path = git_dir + "/" + head_ref
    let dir = parent_dir(head_path)
    if dir.length() > 0 {
      fs.mkdir_p(dir)
    }
    fs.write_string(head_path, "ref: " + head_target + "\n")
  }
}

///|
async fn remote_remove(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit raise Error {
  let config_path = git_dir + "/config"
  if not(rfs.is_file(config_path)) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let (remotes, _) = @gitlib.parse_remote_config(content)
  let warn_branches : Array[String] = []
  match remotes.get(name) {
    Some(rc) => {
      let fetch_specs = @gitlib.parse_fetch_refspecs(rc.fetch)
      if fetch_specs.length() > 0 {
        let branches = @gitlib.collect_local_branches(OsFs::new(), git_dir)
        for branch in branches {
          let refname = "refs/heads/" + branch
          let mut matched = false
          for spec in fetch_specs {
            if spec.negative {
              continue
            }
            let dst = spec.dst
            if dst.length() == 0 || @gitlib.is_remote_namespace(dst, name) {
              continue
            }
            if @gitlib.refspec_capture(dst, refname) is Some(_) {
              matched = true
              break
            }
          }
          if matched {
            warn_branches.push(branch)
          }
        }
      }
    }
    None => ()
  }
  let blocks = @gitlib.parse_config_blocks(content)
  let new_blocks : Array[@gitlib.ConfigBlock] = []
  let mut found = false
  for block in blocks {
    match (block.section, block.name) {
      (Some("remote"), Some(remote_name)) if remote_name == name => {
        found = true
        continue
      }
      (Some("remote"), None) => {
        let updated = block
        let lines : Array[String] = []
        for line in updated.lines {
          match @gitlib.parse_config_kv(line) {
            Some((key, value)) if key == "pushdefault" && value == name => ()
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      (Some("branch"), Some(_)) => {
        let updated = block
        let mut branch_remote : String? = None
        for line in updated.lines {
          match @gitlib.parse_config_kv(line) {
            Some((key, value)) if key == "remote" => branch_remote = Some(value)
            _ => ()
          }
        }
        let remove_merge = branch_remote == Some(name)
        let lines : Array[String] = []
        for line in updated.lines {
          match @gitlib.parse_config_kv(line) {
            Some((key, value)) if key == "remote" && value == name => ()
            Some((key, value)) if key == "pushremote" && value == name => ()
            Some((key, _)) if remove_merge && key == "merge" => ()
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      _ => new_blocks.push(block)
    }
  }
  if not(found) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  fs.write_string(config_path, @gitlib.render_config_blocks(new_blocks))
  @gitlib.remove_remote_refs(fs, rfs, git_dir, name)
  let packed_prefix = "refs/remotes/" + name + "/"
  let packed_exact = "refs/remotes/" + name
  @gitlib.remove_packed_refs_with_prefix(
    fs, rfs, git_dir, packed_prefix, packed_exact,
  )
  if warn_branches.length() > 0 {
    @gitlib.sort_strings_lex(warn_branches)
    let msg = @gitlib.format_remove_warning(warn_branches)
    @stdio.stderr.write(str_to_bytes(msg)) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise err
        }
        ()
      }
    }
  }
}

///|
fn remote_set_url(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  new_url : String?,
  old_url : String?,
  push : Bool,
  add : Bool,
  delete : Bool,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  if rfs.is_file(config_path + ".lock") {
    raise @git.GitError::InvalidObject("config file is locked")
  }
  if not(rfs.is_file(config_path)) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let blocks = @gitlib.parse_config_blocks(content)
  let mut found = false
  let target_key = if push { "pushurl" } else { "url" }
  let new_blocks : Array[@gitlib.ConfigBlock] = []
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      found = true
      let updated = block
      let urls : Array[String] = []
      let other_lines : Array[String] = []
      for line in updated.lines {
        match @gitlib.parse_config_kv(line) {
          Some((key, value)) if key == target_key => urls.push(value)
          _ => other_lines.push(line)
        }
      }
      let mut changed_urls = urls
      if delete {
        match old_url {
          Some(old) => {
            let filtered : Array[String] = []
            for u in changed_urls {
              if not(@gitlib.match_url_pattern(old, u)) {
                filtered.push(u)
              }
            }
            if filtered.length() == changed_urls.length() {
              raise @git.GitError::InvalidObject("No such remote '\{name}'")
            }
            if not(push) && filtered.length() == 0 {
              raise @git.GitError::InvalidObject("No such remote '\{name}'")
            }
            changed_urls = filtered
          }
          None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
        }
      } else if add {
        match new_url {
          Some(nu) => changed_urls.push(nu)
          None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
        }
      } else {
        match new_url {
          Some(nu) =>
            match old_url {
              Some(old) => {
                let mut replaced = false
                let updated_list : Array[String] = []
                for u in changed_urls {
                  if not(replaced) && @gitlib.match_url_pattern(old, u) {
                    updated_list.push(nu)
                    replaced = true
                  } else {
                    updated_list.push(u)
                  }
                }
                if not(replaced) {
                  raise @git.GitError::InvalidObject("No such remote '\{name}'")
                }
                changed_urls = updated_list
              }
              None =>
                if changed_urls.length() == 0 {
                  changed_urls.push(nu)
                } else {
                  changed_urls[0] = nu
                }
            }
          None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
        }
      }
      let final_lines : Array[String] = []
      for line in other_lines {
        final_lines.push(line)
      }
      for u in changed_urls {
        final_lines.push("\t" + target_key + " = " + u)
      }
      updated.lines = final_lines
      new_blocks.push(updated)
    } else {
      new_blocks.push(block)
    }
  }
  if not(found) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  fs.write_string(config_path, @gitlib.render_config_blocks(new_blocks))
}

///|
async fn remote_rename(
  fs : OsFs,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  old_name : String,
  new_name : String,
) -> Unit raise Error {
  let config_path = git_dir + "/config"
  let content = @gitlib.read_config_content(rfs, git_dir)
  let blocks = @gitlib.parse_config_blocks(content)
  let mut found_remote = false
  let mut refspecs_need_update = false
  let mut rename_failed = false
  let new_blocks : Array[@gitlib.ConfigBlock] = []
  for block in blocks {
    match (block.section, block.name) {
      (Some("remote"), Some(remote_name)) if remote_name == old_name => {
        let updated = block
        updated.header = Some("[remote \"\{new_name}\"]")
        let lines : Array[String] = []
        for line in updated.lines {
          match @gitlib.parse_config_kv(line) {
            Some((key, value)) if key == "fetch" => {
              if value.contains(":refs/remotes/" + old_name + "/") {
                refspecs_need_update = true
              }
              let updated_value = @gitlib.update_fetch_refspec(
                value, old_name, new_name,
              )
              lines.push("\tfetch = " + updated_value)
            }
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
        found_remote = true
      }
      (Some("branch"), Some(_)) => {
        let updated = block
        let lines : Array[String] = []
        for line in updated.lines {
          match @gitlib.parse_config_kv(line) {
            Some((key, value)) if key == "remote" && value == old_name =>
              lines.push("\tremote = " + new_name)
            Some((key, value)) if key == "pushremote" && value == old_name =>
              lines.push("\tpushRemote = " + new_name)
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      (Some("remote"), None) => {
        let updated = block
        let lines : Array[String] = []
        for line in updated.lines {
          match @gitlib.parse_config_kv(line) {
            Some((key, value)) if key == "pushdefault" && value == old_name =>
              lines.push("\tpushDefault = " + new_name)
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      _ => new_blocks.push(block)
    }
  }
  let legacy_remotes = git_dir + "/remotes/" + old_name
  let legacy_branches = git_dir + "/branches/" + old_name
  if not(found_remote) && fs.is_file(legacy_remotes) {
    let text = decode_bytes(fs.read_file(legacy_remotes))
    let mut url : String? = None
    let fetches : Array[String] = []
    let pushes : Array[String] = []
    for line_view in text.split("\n") {
      let trimmed = trim_string(line_view.to_string())
      if trimmed.has_prefix("URL:") {
        url = Some(
          trim_string(
            String::unsafe_substring(trimmed, start=4, end=trimmed.length()),
          ),
        )
      } else if trimmed.has_prefix("Push:") {
        let val = trim_string(
          String::unsafe_substring(trimmed, start=5, end=trimmed.length()),
        )
        if val.length() > 0 {
          pushes.push(val)
        }
      } else if trimmed.has_prefix("Pull:") {
        let val = trim_string(
          String::unsafe_substring(trimmed, start=5, end=trimmed.length()),
        )
        if val.length() > 0 {
          fetches.push(val)
        }
      }
    }
    match url {
      Some(u) => {
        let lines : Array[String] = []
        lines.push("\turl = " + u)
        for fetch in fetches {
          lines.push("\tfetch = " + fetch)
        }
        for push in pushes {
          lines.push("\tpush = " + push)
        }
        new_blocks.push({
          header: Some("[remote \"\{new_name}\"]"),
          section: Some("remote"),
          name: Some(new_name),
          lines,
        })
        fs.remove_file(legacy_remotes) catch {
          err => {
            if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
              raise err
            }
            ()
          }
        }
        found_remote = true
      }
      None => ()
    }
  }
  if not(found_remote) && fs.is_file(legacy_branches) {
    let text = decode_bytes(fs.read_file(legacy_branches)).trim().to_string()
    if text.length() > 0 {
      let (url, branch) = match text.find("#") {
        Some(idx) => {
          let u = String::unsafe_substring(text, start=0, end=idx)
          let b = String::unsafe_substring(
            text,
            start=idx + 1,
            end=text.length(),
          )
          (u, b)
        }
        None => (text, "master")
      }
      let branch_name = if branch.length() > 0 { branch } else { "master" }
      let fetch = "refs/heads/" + branch_name + ":refs/heads/" + new_name
      let push = "HEAD:refs/heads/" + branch_name
      let lines : Array[String] = []
      lines.push("\turl = " + url)
      lines.push("\tfetch = " + fetch)
      lines.push("\tpush = " + push)
      new_blocks.push({
        header: Some("[remote \"\{new_name}\"]"),
        section: Some("remote"),
        name: Some(new_name),
        lines,
      })
      fs.remove_file(legacy_branches) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          ()
        }
      }
      found_remote = true
    }
  }
  if not(found_remote) {
    raise @git.GitError::InvalidObject("No such remote '\{old_name}'")
  }
  if old_name != new_name && refspecs_need_update {
    let old_refs = git_dir + "/refs/remotes/" + old_name
    let new_refs = git_dir + "/refs/remotes/" + new_name
    let old_logs = git_dir + "/logs/refs/remotes/" + old_name
    let new_logs = git_dir + "/logs/refs/remotes/" + new_name
    let old_prefix = "refs/remotes/" + old_name + "/"
    let old_exact = "refs/remotes/" + old_name
    let new_prefix = "refs/remotes/" + new_name
    let conflict_refs = @gitlib.list_refs_with_ids(
      fs,
      git_dir,
      Some(new_prefix),
    )
    let mut has_conflict = false
    for refname, _ in conflict_refs {
      if refname == new_prefix {
        has_conflict = true
        break
      }
      if refname == old_exact || refname.has_prefix(old_prefix) {
        continue
      }
      has_conflict = true
      break
    }
    if fs.is_file(new_refs) || fs.is_file(new_logs) {
      has_conflict = true
    }
    if has_conflict {
      eprint_line("error: renaming remote references failed") catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          ()
        }
      }
      eprint_line(
        "error: The remote you are trying to rename has conflicting references",
      ) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          ()
        }
      }
      rename_failed = true
    } else {
      let old_ref_ids = @gitlib.list_refs_with_ids(
        fs,
        git_dir,
        Some(old_prefix),
      )
      @gitlib.move_tree_safe(fs, rfs, old_refs, new_refs)
      @gitlib.move_tree_safe(fs, rfs, old_logs, new_logs)
      let packed_old_prefix = "refs/remotes/" + old_name + "/"
      let packed_new_prefix = "refs/remotes/" + new_name + "/"
      let packed_old_exact = "refs/remotes/" + old_name
      let packed_new_exact = "refs/remotes/" + new_name
      @gitlib.rename_packed_refs_prefix(
        fs, rfs, git_dir, packed_old_prefix, packed_new_prefix, packed_old_exact,
        packed_new_exact,
      )
      let head_path = git_dir + "/refs/remotes/" + new_name + "/HEAD"
      if fs.is_file(head_path) {
        let head_text = decode_bytes(fs.read_file(head_path))
        let sym_prefix = "ref: refs/remotes/" + old_name + "/"
        if head_text.has_prefix(sym_prefix) {
          let rest = String::unsafe_substring(
            head_text,
            start=sym_prefix.length(),
            end=head_text.length(),
          )
          fs.write_string(
            head_path,
            "ref: refs/remotes/" + new_name + "/" + rest,
          )
        }
      }
      let (author, email, timestamp, timezone) = get_committer_identity()
      let is_bare = @gitlib.is_bare_git_dir(git_dir)
      for refname, id in old_ref_ids {
        let suffix = String::unsafe_substring(
          refname,
          start=old_prefix.length(),
          end=refname.length(),
        )
        let new_ref = "refs/remotes/" + new_name + "/" + suffix
        let (should_log, _) = @gitrepo.should_log_ref(
          fs, git_dir, new_ref, is_bare,
        )
        if should_log {
          @gitrepo.append_reflog(
            fs,
            fs,
            git_dir,
            new_ref,
            id,
            id,
            author,
            email,
            timestamp,
            timezone,
            "remote: renamed " + refname + " to " + new_ref,
          )
        }
      }
    }
  }
  fs.write_string(config_path, @gitlib.render_config_blocks(new_blocks))
  if rename_failed {
    @sys.exit(1)
  }
}

///|
async fn remote_prune(
  fs : OsFs,
  git_dir : String,
  root : String,
  name : String,
  dry_run : Bool,
) -> Unit raise Error {
  let (remotes, _) = @gitlib.read_repo_config(fs, git_dir)
  let rc = match remotes.get(name) {
    Some(r) => r
    None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  guard rc.urls.length() > 0 else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let url = rc.urls[0]
  print_line("Pruning \{name}")
  print_line("URL: \{url}")
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  let remote_path = @gitlib.resolve_local_repo_path(fs, local_root, url)
  guard remote_path is Some(path) else { return () }
  let remote_git_dir = @gitlib.detect_git_dir(fs, path).map(pair => pair.0)
  guard remote_git_dir is Some(rgd) else { return () }
  let remote_refs = @gitlib.list_refs_with_ids(fs, rgd, Some("refs/"))
  let fetch_specs = @gitlib.parse_fetch_refspecs(rc.fetch)
  if fetch_specs.length() == 0 {
    fetch_specs.push({
      negative: false,
      src: "refs/heads/*",
      dst: "refs/remotes/" + name + "/*",
    })
  }
  let local_map = @gitlib.list_refs_with_ids(fs, git_dir, Some("refs/"))
  let local_refs : Array[String] = []
  for rname, _ in local_map {
    local_refs.push(rname)
  }
  local_refs.sort()
  let pruned : Array[String] = []
  for local_ref in local_refs {
    if local_ref.has_suffix("/HEAD") {
      continue
    }
    let mut matched = false
    let mut remote_ref : String? = None
    for spec in fetch_specs {
      if spec.negative {
        continue
      }
      if spec.dst.length() == 0 {
        continue
      }
      if @gitlib.refspec_capture(spec.dst, local_ref) is Some(_) {
        matched = true
        remote_ref = @gitlib.refspec_map_dst(spec.dst, spec.src, local_ref)
        break
      }
    }
    if not(matched) {
      continue
    }
    match remote_ref {
      Some(rref) =>
        if not(remote_refs.contains(rref)) {
          let display = local_ref.replace(old="refs/remotes/", new="")
          if dry_run {
            print_line(" * [would prune] \{display}")
          } else {
            @gitlib.remove_ref_path(fs, fs, git_dir + "/" + local_ref)
            @gitlib.remove_ref_path(fs, fs, git_dir + "/logs/" + local_ref)
            @gitlib.remove_packed_ref(fs, fs, git_dir, local_ref)
            print_line(" * [pruned] \{display}")
            pruned.push(local_ref)
          }
        }
      None => ()
    }
  }
  if not(dry_run) {
    let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
    if fs.is_file(head_path) {
      let state = @gitlib.read_local_remote_head_state(fs, head_path, name)
      match state {
        @gitlib.RemoteHeadState::Symref(branch) => {
          let ref_path = git_dir + "/refs/remotes/" + name + "/" + branch
          if not(fs.is_file(ref_path)) {
            print_line("warning: refs/remotes/\{name}/HEAD has become dangling")
          }
        }
        _ => ()
      }
    }
  }
}

///|
async fn remote_update(
  fs : OsFs,
  git_dir : String,
  root : String,
  targets : Array[String],
  prune : Bool,
) -> Unit raise Error {
  let (remotes, _) = @gitlib.read_repo_config(fs, git_dir)
  let config_path = git_dir + "/config"
  let blocks = @gitlib.parse_config_blocks(
    @gitlib.read_config_content(fs, git_dir),
  )
  let names : Array[String] = []
  let seen : Map[String, Bool] = {}
  let mut default_update = false
  if targets.length() == 0 {
    let group = @gitlib.read_config_value(fs, config_path, "remotes", "default")
    match group {
      Some(value) => {
        default_update = false
        let items = @gitlib.split_whitespace_all(value)
        for name in items {
          if not(seen.contains(name)) {
            seen[name] = true
            names.push(name)
          }
        }
      }
      None => {
        default_update = true
        for name, _ in remotes {
          if not(seen.contains(name)) {
            seen[name] = true
            names.push(name)
          }
        }
      }
    }
  } else {
    for target in targets {
      if target == "default" {
        let group = @gitlib.read_config_value(
          fs, config_path, "remotes", "default",
        )
        match group {
          Some(value) => {
            let items = @gitlib.split_whitespace_all(value)
            for name in items {
              if not(seen.contains(name)) {
                seen[name] = true
                names.push(name)
              }
            }
          }
          None => {
            default_update = true
            for name, _ in remotes {
              if not(seen.contains(name)) {
                seen[name] = true
                names.push(name)
              }
            }
          }
        }
        continue
      }
      let group = @gitlib.read_config_value(fs, config_path, "remotes", target)
      match group {
        Some(value) => {
          let items = @gitlib.split_whitespace_all(value)
          for name in items {
            if not(seen.contains(name)) {
              seen[name] = true
              names.push(name)
            }
          }
        }
        None =>
          if not(seen.contains(target)) {
            seen[target] = true
            names.push(target)
          }
      }
    }
  }
  for name in names {
    if default_update && @gitlib.remote_skip_default_update(blocks, name) {
      continue
    }
    match remotes.get(name) {
      Some(rc) =>
        if rc.urls.length() > 0 {
          let url = rc.urls[0]
          fetch_from_remote(fs, git_dir, root, name, url, [])
          if prune {
            remote_prune(fs, git_dir, root, name, false)
          }
        }
      None => ()
    }
  }
}

///|
fn remote_set_head_delete(
  fs : OsFs,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
  let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
  if fs.is_file(head_path) {
    fs.remove_file(head_path)
  }
}

///|
fn remote_set_head_explicit(
  fs : OsFs,
  git_dir : String,
  name : String,
  branch : String,
) -> Unit raise @git.GitError {
  let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
  let parent = parent_dir(head_path)
  if parent.length() > 0 {
    ensure_dir(parent)
  }
  fs.write_string(head_path, "ref: refs/remotes/" + name + "/" + branch + "\n")
}

///|
async fn remote_set_head_auto(
  fs : OsFs,
  git_dir : String,
  root : String,
  name : String,
) -> Unit raise Error {
  let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
  if fs.is_file(head_path + ".lock") {
    die_remote(1, "error: Could not set up refs/remotes/\{name}/HEAD")
  }
  let url = @gitlib.get_remote_url(fs, git_dir, name).unwrap_or("")
  if url.length() == 0 {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  let remote_path = @gitlib.resolve_local_repo_path(fs, local_root, url)
  guard remote_path is Some(path) else { return () }
  let remote_git_dir = @gitlib.detect_git_dir(fs, path).map(pair => pair.0)
  guard remote_git_dir is Some(rgd) else { return () }
  let new_branch = @gitlib.read_remote_head_branch(fs, rgd).unwrap_or("")
  if new_branch.length() == 0 {
    return ()
  }
  let state = @gitlib.read_local_remote_head_state(fs, head_path, name)
  let parent = parent_dir(head_path)
  if parent.length() > 0 {
    ensure_dir(parent)
  }
  fs.write_string(
    head_path,
    "ref: refs/remotes/" + name + "/" + new_branch + "\n",
  )
  let quoted = "'\{name}/HEAD'"
  match state {
    @gitlib.RemoteHeadState::Missing =>
      print_line("\{quoted} is now created and points to '\{new_branch}'")
    @gitlib.RemoteHeadState::Detached(old) =>
      print_line(
        "\{quoted} was detached at '\{old}' and now points to '\{new_branch}'",
      )
    @gitlib.RemoteHeadState::Other(old) =>
      print_line(
        "\{quoted} used to point to '\{old}' (which is not a remote branch), but now points to '\{new_branch}'",
      )
    @gitlib.RemoteHeadState::Symref(old) =>
      if old == new_branch {
        print_line("\{quoted} is unchanged and points to '\{new_branch}'")
      } else {
        print_line(
          "\{quoted} has changed from '\{old}' and now points to '\{new_branch}'",
        )
      }
  }
  @gitlib.update_follow_remote_head(fs, fs, git_dir, name)
}

///|
fn get_committer_identity() -> (String, String, Int64, String) {
  let name = match @sys.get_env_var("GIT_COMMITTER_NAME") {
    Some(n) => n
    None => @sys.get_env_var("USER").unwrap_or("Unknown")
  }
  let email = match @sys.get_env_var("GIT_COMMITTER_EMAIL") {
    Some(e) => e
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u + "@localhost"
        None => "unknown@localhost"
      }
  }
  let mut timestamp = get_current_timestamp()
  let mut timezone = "+0000"
  match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(raw) => {
      let parts = @gitlib.split_whitespace_all(raw)
      if parts.length() > 0 {
        timestamp = @strconv.parse_int64(parts[0]) catch { _ => timestamp }
      }
      if parts.length() > 1 {
        timezone = parts[1]
      }
    }
    None => ()
  }
  (name, email, timestamp, timezone)
}

///|
fn write_ref_file(
  fs : OsFs,
  git_dir : String,
  refname : String,
  id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let path = git_dir + "/" + refname
  let dir = parent_dir(path)
  if dir.length() > 0 {
    ensure_dir(dir)
  }
  fs.write_string(path, id.to_hex() + "\n")
}

///|
fn write_symref_file(
  fs : OsFs,
  git_dir : String,
  refname : String,
  target : String,
) -> Unit raise @git.GitError {
  let path = git_dir + "/" + refname
  let dir = parent_dir(path)
  if dir.length() > 0 {
    ensure_dir(dir)
  }
  fs.write_string(path, "ref: " + target + "\n")
}

///|
fn upsert_packed_refs(
  fs : OsFs,
  git_dir : String,
  refs : Array[(String, @git.ObjectId)],
) -> Unit raise @git.GitError {
  if refs.length() == 0 {
    return
  }
  let packed_path = git_dir + "/packed-refs"
  let packed : Map[String, String] = {}
  if fs.is_file(packed_path) {
    let content = decode_bytes(fs.read_file(packed_path))
    for line_view in content.split("\n") {
      let line = line_view.trim().to_string()
      if line.length() == 0 || line.has_prefix("#") || line.has_prefix("^") {
        continue
      }
      let space = line.find(" ")
      match space {
        Some(i) =>
          if i > 0 && i + 1 < line.length() {
            let oid = String::unsafe_substring(line, start=0, end=i)
            let refname = String::unsafe_substring(
              line,
              start=i + 1,
              end=line.length(),
            )
            packed[refname] = oid
          }
        None => ()
      }
    }
  }
  for entry in refs {
    packed[entry.0] = entry.1.to_hex()
  }
  let entries : Array[(String, String)] = packed.iter().collect()
  entries.sort_by(fn(a, b) { a.0.compare(b.0) })
  let lines : Array[String] = ["# pack-refs with: peeled fully-peeled sorted"]
  for entry in entries {
    lines.push(entry.1 + " " + entry.0)
  }
  fs.write_string(packed_path, lines.join("\n") + "\n")
}

///|
fn update_testgit_push_tracking(
  fs : OsFs,
  git_dir : String,
  remote_name : String,
  refname : String,
  id : @git.ObjectId,
  no_private_update : Bool,
) -> Unit raise @git.GitError {
  match branch_name_from_head_ref(refname) {
    Some(name) => {
      let tracking_ref = "refs/remotes/" + remote_name + "/" + name
      let tracking_current = @gitlib.resolve_ref(fs, git_dir, tracking_ref)
      if tracking_current != Some(id) {
        write_ref_file(fs, git_dir, tracking_ref, id)
      }
      if not(no_private_update) {
        write_ref_file(
          fs,
          git_dir,
          "refs/testgit/" + remote_name + "/heads/" + name,
          id,
        )
      }
    }
    None => ()
  }
}

///|
fn update_local_push_tracking(
  fs : OsFs,
  git_dir : String,
  remote_name : String,
  update : PushResolvedUpdate,
) -> Unit raise @git.GitError {
  match branch_name_from_head_ref(update.refname) {
    Some(name) => {
      let tracking_ref = "refs/remotes/" + remote_name + "/" + name
      if update.delete_ref {
        if update.should_apply {
          @gitlib.remove_ref_path(fs, fs, git_dir + "/" + tracking_ref)
          @gitlib.remove_ref_path(fs, fs, git_dir + "/logs/" + tracking_ref)
          @gitlib.remove_packed_ref(fs, fs, git_dir, tracking_ref)
        }
      } else if @gitlib.resolve_ref(fs, git_dir, tracking_ref) !=
        Some(update.new_id) {
        write_ref_file(fs, git_dir, tracking_ref, update.new_id)
      }
    }
    None => ()
  }
}

///|
fn pack_remote_tracking_refs(
  fs : OsFs,
  git_dir : String,
  remote_name : String,
) -> Unit raise @git.GitError {
  let prefix = "refs/remotes/" + remote_name + "/"
  let refs = @gitlib.list_refs_with_ids(fs, git_dir, Some(prefix))
  let entries : Array[(String, @git.ObjectId)] = []
  for refname, oid in refs {
    if refname != prefix + "HEAD" {
      entries.push((refname, oid))
    }
  }
  if entries.length() == 0 {
    return
  }
  upsert_packed_refs(fs, git_dir, entries)
  for entry in entries {
    @gitlib.remove_ref_path(fs, fs, git_dir + "/" + entry.0)
  }
}

///|
fn parse_legacy_branches_entry(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> (String, String?)? {
  let path = git_dir + "/branches/" + name
  guard fs.is_file(path) else { return None }
  let raw = fs.read_file(path) catch { _ => return None }
  let text = decode_bytes(raw).trim().to_string()
  if text.length() == 0 {
    return None
  }
  match text.find("#") {
    Some(idx) => {
      let url = String::unsafe_substring(text, start=0, end=idx)
      let branch = String::unsafe_substring(
        text,
        start=idx + 1,
        end=text.length(),
      )
      if branch.length() > 0 {
        Some((url, Some(branch)))
      } else {
        Some((url, None))
      }
    }
    None => Some((text, None))
  }
}

///|
fn legacy_default_branch_name() -> String {
  @sys.get_env_var("GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME").unwrap_or("main")
}

///|
fn collect_clone_alternates(
  fs : OsFs,
  src_git_dir : String,
  reference_alternates : Array[String],
) -> Array[String] {
  let alternates : Array[String] = []
  let source_alternates = src_git_dir + "/objects/info/alternates"
  if fs.is_file(source_alternates) {
    let text = decode_bytes(fs.read_file(source_alternates)) catch { _ => "" }
    for line_view in text.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() == 0 {
        continue
      }
      let resolved = if line.has_prefix("/") {
        normalize_path(line)
      } else {
        normalize_path(src_git_dir + "/objects/" + line)
      }
      alternates.push(resolved)
    }
  }
  for alt in reference_alternates {
    alternates.push(normalize_path(alt))
  }
  alternates
}

///|
fn write_clone_alternates(
  fs : OsFs,
  dest_git_dir : String,
  alternates : Array[String],
) -> Unit raise @git.GitError {
  if alternates.length() == 0 {
    return
  }
  let unique : Array[String] = []
  let seen : Map[String, Bool] = {}
  for alt in alternates {
    if seen.contains(alt) {
      continue
    }
    seen[alt] = true
    unique.push(alt)
  }
  fs.mkdir_p(dest_git_dir + "/objects/info")
  fs.write_string(
    dest_git_dir + "/objects/info/alternates",
    unique.join("\n") + "\n",
  )
}

///|
fn read_global_branch_autosetuprebase(
  fs : &@git.RepoFileSystem,
) -> String? raise Error {
  let config_path = match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
    Some(path) => path
    None =>
      match @sys.get_env_var("HOME") {
        Some(home) => home + "/.gitconfig"
        None => return None
      }
  }
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes(fs.read_file(config_path))
  let blocks = @gitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section == Some("branch") && block.name is None {
      for line in block.lines {
        match @gitlib.parse_config_kv(line) {
          Some((key, value)) if key == "autosetuprebase" =>
            return Some(trim_string(value).to_lower())
          _ => ()
        }
      }
    }
  }
  None
}

///|
fn clone_local_repo(
  fs : OsFs,
  src_path : String,
  dest_path : String,
  remote_url : String,
  bare : Bool,
  filter : @protocol.FilterSpec,
  mirror? : Bool = false,
  no_checkout? : Bool = false,
  separate_git_dir? : String? = None,
  remote_name? : String = "origin",
  reference_alternates? : Array[String] = [],
  ref_format? : String = "files",
) -> Unit raise Error {
  guard @gitlib.detect_git_dir(fs, src_path) is Some((src_git_dir, _)) else {
    raise @git.GitError::InvalidObject("Not a git repository: \{src_path}")
  }
  let source_object_format = match
    @gitlib.read_config_value(
      fs,
      src_git_dir + "/config",
      "extensions",
      "objectformat",
    ) {
    Some(value) => if value.to_lower() == "sha256" { "sha256" } else { "sha1" }
    None => "sha1"
  }
  let (head_ref, branches) = @gitlib.list_branches(fs, src_git_dir)
  let mut default_branch = "main"
  let mut head_id : @git.ObjectId? = None
  let mut detached_head = false
  match head_ref {
    @gitlib.HeadRef::Branch(name) => {
      default_branch = name
      let refname = "refs/heads/" + name
      head_id = @gitlib.resolve_ref(fs, src_git_dir, refname)
    }
    @gitlib.HeadRef::Detached(id) => {
      head_id = Some(id)
      detached_head = true
    }
  }
  if head_id is None {
    match read_clone_source_head_fallback(fs, src_git_dir) {
      Some(id) => {
        head_id = Some(id)
        detached_head = true
      }
      None => ()
    }
  }
  let dest_git_dir = if bare {
    @gitlib.init_repo_with_options(fs, dest_path, {
      default_branch,
      bare: true,
      separate_git_dir: None,
      template_dir: None,
      ref_format,
      object_format: source_object_format,
    })
    dest_path
  } else {
    match separate_git_dir {
      Some(path) => {
        fs.mkdir_p(dest_path)
        @gitlib.init_repo_with_options(fs, dest_path, {
          default_branch,
          bare: false,
          separate_git_dir: Some(path),
          template_dir: None,
          ref_format,
          object_format: source_object_format,
        })
        path
      }
      None => {
        @gitlib.init_repo_with_options(fs, dest_path, {
          default_branch,
          bare: false,
          separate_git_dir: None,
          template_dir: None,
          ref_format,
          object_format: source_object_format,
        })
        dest_path + "/.git"
      }
    }
  }
  // Copy object database
  @gitlib.copy_tree(fs, fs, src_git_dir + "/objects", dest_git_dir + "/objects")
  let alternates = collect_clone_alternates(
    fs, src_git_dir, reference_alternates,
  )
  write_clone_alternates(fs, dest_git_dir, alternates)
  let src_shallow_path = src_git_dir + "/shallow"
  if fs.is_file(src_shallow_path) {
    fs.write_string(
      dest_git_dir + "/shallow",
      decode_bytes(fs.read_file(src_shallow_path)),
    )
  }
  match head_id {
    Some(id) =>
      if detached_head {
        // Preserve detached HEAD from source repository.
        fs.write_string(dest_git_dir + "/HEAD", id.to_hex() + "\n")
      } else {
        write_ref_file(fs, dest_git_dir, "refs/heads/" + default_branch, id)
      }
    None => ()
  }
  if mirror {
    let refs = @gitlib.list_refs_with_ids(fs, src_git_dir, None)
    for refname, id in refs {
      if refname.has_prefix("refs/") {
        write_ref_file(fs, dest_git_dir, refname, id)
      }
    }
  } else {
    let tags = @gitlib.list_refs_with_ids(fs, src_git_dir, Some("refs/tags/"))
    for refname, id in tags {
      write_ref_file(fs, dest_git_dir, refname, id)
    }
  }
  // Configure origin
  let fetch_specs = if mirror {
    ["+refs/*:refs/*"]
  } else {
    ["+refs/heads/*:refs/remotes/" + remote_name + "/*"]
  }
  remote_add(
    fs,
    fs,
    dest_git_dir,
    remote_name,
    remote_url,
    fetch_specs,
    mirror,
    None,
  )
  if not(bare) && not(detached_head) {
    @gitlib.set_config_key(
      fs, fs, dest_git_dir, "branch", default_branch, "remote", remote_name,
    )
    @gitlib.set_config_key(
      fs,
      fs,
      dest_git_dir,
      "branch",
      default_branch,
      "merge",
      "refs/heads/" + default_branch,
    )
    match read_global_branch_autosetuprebase(fs) {
      Some(mode) =>
        if mode == "always" || mode == "true" || mode == "remote" {
          @gitlib.set_config_key(
            fs, fs, dest_git_dir, "branch", default_branch, "rebase", "true",
          )
        }
      None => ()
    }
  }
  // Set remote tracking refs in packed-refs so up-to-date pushes keep them packed.
  let packed_tracking_refs : Array[(String, @git.ObjectId)] = []
  if not(mirror) {
    for b in branches {
      packed_tracking_refs.push(
        ("refs/remotes/" + remote_name + "/" + b.name, b.id),
      )
    }
  }
  upsert_packed_refs(fs, dest_git_dir, packed_tracking_refs)
  if not(detached_head) && not(mirror) && branches.length() > 0 {
    write_symref_file(
      fs,
      dest_git_dir,
      "refs/remotes/" + remote_name + "/HEAD",
      "refs/remotes/" + remote_name + "/" + default_branch,
    )
  }
  // Partial clone markers
  if filter.is_partial() {
    @gitlib.set_config_key(
      fs, fs, dest_git_dir, "remote", remote_name, "promisor", "true",
    )
    @gitlib.set_config_key(
      fs,
      fs,
      dest_git_dir,
      "remote",
      remote_name,
      "partialCloneFilter",
      filter.to_string(),
    )
    let promisor_path = dest_git_dir + "/objects/info/promisor"
    fs.write_string(promisor_path, remote_url + "\n")
  }
  // Populate working tree/index from the cloned commit snapshot.
  if not(bare) && not(no_checkout) {
    match head_id {
      Some(id) => {
        let checkout_spec = if detached_head {
          id.to_hex()
        } else {
          default_branch
        }
        let _ = @gitlib.checkout(
          fs,
          fs,
          dest_path,
          checkout_spec,
          detach=detached_head,
          update_worktree=true,
          update_index=true,
        )
      }
      None => ()
    }
  }
}

///|
fn read_clone_source_head_fallback(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId? {
  let head_path = git_dir + "/HEAD"
  if fs.is_file(head_path) {
    let head_content = decode_bytes(
      fs.read_file(head_path) catch {
        _ => str_to_bytes("")
      },
    )
    let head_line = trim_string(head_content)
    if head_line.length() > 0 && not(head_line.has_prefix("ref: ")) {
      let head_id : @git.ObjectId? = Some(@git.ObjectId::from_hex(head_line)) catch {
        _ => None
      }
      if head_id is Some(id) {
        return Some(id)
      }
    }
  }
  let reflog_path = git_dir + "/logs/HEAD"
  guard fs.is_file(reflog_path) else { return None }
  let reflog_content = decode_bytes(
    fs.read_file(reflog_path) catch {
      _ => str_to_bytes("")
    },
  )
  let mut latest_id : @git.ObjectId? = None
  for line_view in reflog_content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    match line.find(" ") {
      Some(first_sep) => {
        let rest = String::unsafe_substring(
          line,
          start=first_sep + 1,
          end=line.length(),
        )
        match rest.find(" ") {
          Some(second_sep) => {
            let new_id_hex = String::unsafe_substring(
              rest,
              start=0,
              end=second_sep,
            )
            let parsed : @git.ObjectId? = Some(
              @git.ObjectId::from_hex(new_id_hex),
            ) catch {
              _ => None
            }
            if parsed is Some(id) {
              latest_id = Some(id)
            }
          }
          None => ()
        }
      }
      None => ()
    }
  }
  latest_id
}

///|
fn has_promisor_source_repo(fs : OsFs, src_path : String) -> Bool {
  guard @gitlib.detect_git_dir(fs, src_path) is Some((src_git_dir, _)) else {
    return false
  }
  if @gitlib.is_partial_clone(fs, src_git_dir) {
    return true
  }
  let (remotes, _) = @gitlib.read_repo_config(fs, src_git_dir)
  for _, rc in remotes {
    if rc.promisor || rc.partial_clone_filter is Some(_) {
      return true
    }
  }
  false
}

///|
fn parse_fetch_refspecs_with_force(
  specs : Array[String],
) -> Array[(@gitlib.FetchRefspec, Bool)] {
  let out : Array[(@gitlib.FetchRefspec, Bool)] = []
  for raw in specs {
    let mut negative = false
    let mut force = false
    let mut spec = raw
    if spec.has_prefix("^") {
      negative = true
      spec = String::unsafe_substring(spec, start=1, end=spec.length())
    }
    if spec.has_prefix("+") {
      force = true
      spec = String::unsafe_substring(spec, start=1, end=spec.length())
    }
    let (src, dst) = @gitlib.parse_refspec_pair(spec)
    out.push(({ negative, src, dst }, force))
  }
  out
}

///|
fn normalize_fetch_destination_ref(
  dst : String,
  source_refname : String?,
) -> String {
  if dst.length() == 0 || dst.has_prefix("refs/") {
    return dst
  }
  match source_refname {
    Some(src) if src.has_prefix("refs/tags/") => "refs/tags/" + dst
    _ => "refs/heads/" + dst
  }
}

///|
struct FetchHeadEntry {
  id : @git.ObjectId
  source_refname : String?
  for_merge : Bool
}

///|
fn normalize_merge_refname(refname : String) -> String {
  if refname.has_prefix("refs/") {
    refname
  } else {
    "refs/heads/" + refname
  }
}

///|
fn format_fetch_head_description(
  source_refname : String?,
  remote_url : String,
) -> String {
  match source_refname {
    Some(refname) if refname.has_prefix("refs/heads/") => {
      let branch = String::unsafe_substring(
        refname,
        start=11,
        end=refname.length(),
      )
      "branch '" + branch + "' of " + remote_url
    }
    Some(refname) if refname.has_prefix("refs/tags/") => {
      let tag = String::unsafe_substring(
        refname,
        start=10,
        end=refname.length(),
      )
      "tag '" + tag + "' of " + remote_url
    }
    Some(refname) => refname + " of " + remote_url
    None => remote_url
  }
}

///|
fn render_fetch_head_content(
  entries : Array[FetchHeadEntry],
  remote_url : String,
) -> String {
  let ordered : Array[FetchHeadEntry] = []
  for entry in entries {
    if entry.for_merge {
      ordered.push(entry)
    }
  }
  for entry in entries {
    if not(entry.for_merge) {
      ordered.push(entry)
    }
  }
  let lines : Array[String] = []
  for entry in ordered {
    let merge_flag = if entry.for_merge { "" } else { "not-for-merge" }
    let description = format_fetch_head_description(
      entry.source_refname,
      remote_url,
    )
    lines.push(entry.id.to_hex() + "\t" + merge_flag + "\t" + description)
  }
  if lines.length() == 0 {
    ""
  } else {
    lines.join("\n") + "\n"
  }
}

///|
enum RemoteTrackingHeadState {
  Missing
  Symref(String)
  Detached(String)
}

///|
fn read_remote_follow_remote_head_mode(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  remote_name : String,
) -> String {
  let config_path = git_dir + "/config"
  guard fs.is_file(config_path) else { return "create" }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => return "create"
    },
  )
  let blocks = @gitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(remote_name) {
      for line in block.lines {
        match @gitlib.parse_config_kv(line) {
          Some((key, value)) =>
            if key.to_lower() == "followremotehead" {
              let mode = trim_string(value).to_lower()
              if mode.length() > 0 {
                return mode
              }
            }
          None => ()
        }
      }
    }
  }
  "create"
}

///|
fn read_remote_tracking_head_state(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  remote_name : String,
) -> RemoteTrackingHeadState {
  let path = git_dir + "/refs/remotes/" + remote_name + "/HEAD"
  guard fs.is_file(path) else { return RemoteTrackingHeadState::Missing }
  let raw = decode_bytes(
    fs.read_file(path) catch {
      _ => return RemoteTrackingHeadState::Missing
    },
  )
  let trimmed = trim_string(raw)
  if trimmed.has_prefix("ref: ") {
    let target = String::unsafe_substring(
      trimmed,
      start=5,
      end=trimmed.length(),
    )
    return RemoteTrackingHeadState::Symref(trim_string(target))
  }
  if trimmed.length() == 0 {
    RemoteTrackingHeadState::Missing
  } else {
    RemoteTrackingHeadState::Detached(trimmed)
  }
}

///|
fn remote_tracking_branch_name_from_target(
  target : String,
  remote_name : String,
) -> String {
  let prefix = "refs/remotes/" + remote_name + "/"
  if target.has_prefix(prefix) {
    String::unsafe_substring(target, start=prefix.length(), end=target.length())
  } else {
    target
  }
}

///|
fn update_remote_tracking_head_ref(
  fs : OsFs,
  git_dir : String,
  remote_name : String,
  remote_head_branch : String,
  quiet : Bool,
) -> Unit raise @git.GitError {
  let mode = read_remote_follow_remote_head_mode(fs, git_dir, remote_name)
  if mode == "never" {
    return ()
  }
  let local_head_ref = "refs/remotes/" + remote_name + "/HEAD"
  let remote_head_target = "refs/remotes/" +
    remote_name +
    "/" +
    remote_head_branch
  let local_state = read_remote_tracking_head_state(fs, git_dir, remote_name)
  let mut should_update = false
  let mut warning_message : String? = None
  if mode == "always" {
    should_update = true
  } else if mode == "create" {
    match local_state {
      RemoteTrackingHeadState::Missing => should_update = true
      _ => ()
    }
  } else if mode == "warn" || mode.has_prefix("warn-if-not-") {
    let mut should_warn = mode == "warn"
    if mode.has_prefix("warn-if-not-") {
      let expected = String::unsafe_substring(mode, start=12, end=mode.length())
      should_warn = remote_head_branch != expected
    }
    match local_state {
      RemoteTrackingHeadState::Missing => should_update = true
      RemoteTrackingHeadState::Symref(local_target) =>
        if local_target != remote_head_target && should_warn {
          let local_branch = remote_tracking_branch_name_from_target(
            local_target, remote_name,
          )
          warning_message = Some(
            "'HEAD' at '" +
            remote_name +
            "' is '" +
            remote_head_branch +
            "', but we have '" +
            local_branch +
            "' locally.",
          )
        }
      RemoteTrackingHeadState::Detached(local_oid) =>
        if should_warn {
          warning_message = Some(
            "'HEAD' at '" +
            remote_name +
            "' is '" +
            remote_head_branch +
            "', but we have a detached HEAD pointing to '" +
            local_oid +
            "' locally.",
          )
        }
    }
  } else {
    match local_state {
      RemoteTrackingHeadState::Missing => should_update = true
      _ => ()
    }
  }
  if should_update {
    write_symref_file(fs, git_dir, local_head_ref, remote_head_target)
    return ()
  }
  match warning_message {
    Some(msg) => if not(quiet) { println(msg) }
    None => ()
  }
}

///|
async fn fetch_local_repo(
  fs : OsFs,
  src_path : String,
  root : String,
  git_dir : String,
  remote_name : String,
  remote_url : String,
  explicit_refspecs : Array[String],
  update_head_ok? : Bool = false,
  quiet? : Bool = false,
) -> Unit raise Error {
  guard @gitlib.detect_git_dir(fs, src_path) is Some((src_git_dir, _)) else {
    raise @git.GitError::InvalidObject("Not a git repository: \{src_path}")
  }
  let display_url = if remote_url.has_prefix("/") ||
    remote_url.has_prefix("file://") {
    remote_url
  } else {
    src_path
  }
  match @sys.get_env_var("GIT_TRACE_PACKET") {
    Some(path) => append_text_file(fs, path, "")
    None => ()
  }
  eprint_line("From \{display_url}")
  let src_db = @gitlib.ObjectDb::load(fs, src_git_dir)
  let (remotes, branches) = @gitlib.read_repo_config(fs, git_dir)
  let rc = remotes
    .get(remote_name)
    .unwrap_or({
      urls: [],
      pushurls: [],
      fetch: [],
      push: [],
      promisor: false,
      partial_clone_filter: None,
      mirror: false,
      tagopt: None,
    })
  let fetch_specs : Array[(@gitlib.FetchRefspec, Bool)] = if explicit_refspecs.length() >
    0 {
    parse_fetch_refspecs_with_force(explicit_refspecs)
  } else {
    let specs = parse_fetch_refspecs_with_force(rc.fetch)
    if specs.length() == 0 {
      specs.push(
        (
          {
            negative: false,
            src: "refs/heads/*",
            dst: "refs/remotes/" + remote_name + "/*",
          },
          false,
        ),
      )
    }
    specs
  }
  let negative_specs : Array[@gitlib.FetchRefspec] = []
  let positive_specs : Array[(@gitlib.FetchRefspec, Bool)] = []
  for spec_entry in fetch_specs {
    let spec = spec_entry.0
    if spec.negative {
      negative_specs.push(spec)
    } else {
      positive_specs.push(spec_entry)
    }
  }
  let remote_refs = @gitlib.list_refs_with_ids(fs, src_git_dir, Some("refs/"))
  let fetch_hide_refs = read_hide_refs(fs, src_git_dir, [
    "transfer", "uploadpack",
  ])
  let fetch_head_merge_refs : Map[String, Bool] = {}
  match @gitlib.read_head_ref(fs, git_dir) {
    @gitlib.HeadRef::Branch(current_branch_name) =>
      match branches.get(current_branch_name) {
        Some(bc) =>
          if bc.remote is Some(config_remote) && config_remote == remote_name {
            for merge in bc.merges {
              fetch_head_merge_refs[normalize_merge_refname(merge)] = true
            }
          }
        None => ()
      }
    @gitlib.HeadRef::Detached(_) => ()
  }
  let allow_tip_sha1_in_want = @gitlib.read_config_bool(
    fs,
    src_git_dir + "/config",
    "uploadpack",
    "allowtipsha1inwant",
  ).unwrap_or(false)
  let allow_reachable_sha1_in_want = @gitlib.read_config_bool(
    fs,
    src_git_dir + "/config",
    "uploadpack",
    "allowreachablesha1inwant",
  ).unwrap_or(false)
  let protocol_version = @sys.get_env_var("GIT_TEST_PROTOCOL_VERSION").unwrap_or(
    "2",
  )
  let enforce_unadvertised_oid = protocol_version == "0"
  let visible_advertised_oids : Map[String, Bool] = {}
  let all_tip_oids : Map[String, Bool] = {}
  let visible_tip_commits : Array[@git.ObjectId] = []
  for refname, id in remote_refs {
    let hex = id.to_hex()
    all_tip_oids[hex] = true
    if is_hidden_ref(refname, fetch_hide_refs) {
      continue
    }
    visible_advertised_oids[hex] = true
    match peel_to_commit(src_db, fs, id) {
      Some(commit_id) => visible_tip_commits.push(commit_id)
      None => ()
    }
  }
  let mut mirror_fetch = @gitlib.is_mirror_fetch_config(rc)
  let mut fetches_tags = false
  for spec_entry in positive_specs {
    let spec = spec_entry.0
    if spec.src.has_prefix("refs/tags/") || spec.src == "refs/*" {
      fetches_tags = true
    }
    if spec.src == "refs/*" {
      mirror_fetch = true
    }
  }
  let fetched_heads : Array[@git.ObjectId] = []
  let mapped_refs : Map[String, @git.ObjectId] = {}
  let bare_oid_fetches : Array[@git.ObjectId] = []
  let fetch_head_entries : Array[FetchHeadEntry] = []
  for spec_entry in positive_specs {
    let spec = spec_entry.0
    let spec_force = spec_entry.1
    if spec.src == "HEAD" || spec.src == "@" {
      if spec.dst.length() == 0 {
        continue
      }
      let (head_source_ref, head_id_opt) = match
        @gitlib.read_head_ref(fs, src_git_dir) {
        @gitlib.HeadRef::Branch(name) => {
          let refname = "refs/heads/" + name
          (Some(refname), @gitlib.resolve_ref(fs, src_git_dir, refname))
        }
        @gitlib.HeadRef::Detached(id) => (None, Some(id))
      }
      guard head_id_opt is Some(head_id) else { continue }
      let normalized_dst = normalize_fetch_destination_ref(
        spec.dst,
        head_source_ref,
      )
      if normalized_dst.has_prefix("refs/tags/") {
        match @gitlib.resolve_ref(fs, git_dir, normalized_dst) {
          Some(existing) =>
            if existing != head_id && not(spec_force) {
              raise @git.GitError::InvalidObject("would clobber existing tag")
            }
          None => ()
        }
      }
      mapped_refs[normalized_dst] = head_id
      if normalized_dst.has_prefix("refs/heads/") {
        fetched_heads.push(head_id)
      }
      let for_merge = match head_source_ref {
        Some(source_ref) => fetch_head_merge_refs.contains(source_ref)
        None => false
      }
      fetch_head_entries.push({
        id: head_id,
        source_refname: head_source_ref,
        for_merge,
      })
      continue
    }
    if spec.src.length() == 0 ||
      spec.src.contains("*") ||
      not(looks_like_object_id(spec.src)) {
      continue
    }
    let object_id = @git.ObjectId::from_hex(spec.src) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise err
        }
        continue
      }
    }
    let object_id_hex = object_id.to_hex()
    if enforce_unadvertised_oid {
      let mut reachable_from_visible_tip = false
      match peel_to_commit(src_db, fs, object_id) {
        Some(commit_id) =>
          for tip_commit_id in visible_tip_commits {
            if is_ancestor_commit(src_db, fs, commit_id, tip_commit_id) {
              reachable_from_visible_tip = true
              break
            }
          }
        None => ()
      }
      let allowed = visible_advertised_oids.get(object_id_hex) is Some(_) ||
        (allow_tip_sha1_in_want && all_tip_oids.get(object_id_hex) is Some(_)) ||
        (allow_reachable_sha1_in_want && reachable_from_visible_tip)
      if not(allowed) {
        if allow_reachable_sha1_in_want && not(reachable_from_visible_tip) {
          raise @git.GitError::InvalidObject("not our ref " + object_id_hex)
        }
        raise @git.GitError::InvalidObject(
          "Server does not allow request for unadvertised object " +
          object_id_hex,
        )
      }
    }
    if spec.dst.length() == 0 {
      bare_oid_fetches.push(object_id)
      fetch_head_entries.push({
        id: object_id,
        source_refname: None,
        for_merge: false,
      })
      continue
    }
    let normalized_dst = normalize_fetch_destination_ref(spec.dst, None)
    mapped_refs[normalized_dst] = object_id
    if normalized_dst.has_prefix("refs/heads/") {
      fetched_heads.push(object_id)
    }
  }
  for refname, id in remote_refs {
    let mut excluded = false
    for spec in negative_specs {
      if @gitlib.refspec_capture(spec.src, refname) is Some(_) {
        excluded = true
        break
      }
    }
    if excluded {
      continue
    }
    for spec_entry in positive_specs {
      let spec = spec_entry.0
      let spec_force = spec_entry.1
      if spec.dst.length() == 0 {
        continue
      }
      let mut mapped_dst : String? = None
      let src_candidates = fetch_source_candidates(spec.src)
      for src_candidate in src_candidates {
        match @gitlib.refspec_map_dst(src_candidate, spec.dst, refname) {
          Some(dst) => {
            mapped_dst = Some(dst)
            break
          }
          None => ()
        }
      }
      match mapped_dst {
        Some(dst) => {
          let normalized_dst = normalize_fetch_destination_ref(
            dst,
            Some(refname),
          )
          if normalized_dst.has_prefix("refs/tags/") {
            match @gitlib.resolve_ref(fs, git_dir, normalized_dst) {
              Some(existing) =>
                if existing != id && not(spec_force) {
                  raise @git.GitError::InvalidObject(
                    "would clobber existing tag",
                  )
                }
              None => ()
            }
          }
          mapped_refs[normalized_dst] = id
          if refname.has_prefix("refs/heads/") {
            fetched_heads.push(id)
          }
          fetch_head_entries.push({
            id,
            source_refname: Some(refname),
            for_merge: fetch_head_merge_refs.contains(refname),
          })
        }
        None => ()
      }
    }
  }
  let transferred_object_ids : Map[String, Bool] = {}
  let rfs : &@git.RepoFileSystem = fs
  let wanted_object_ids : Array[@git.ObjectId] = []
  for _, id in mapped_refs {
    wanted_object_ids.push(id)
  }
  for id in bare_oid_fetches {
    wanted_object_ids.push(id)
  }
  for wanted_id in wanted_object_ids {
    copy_wanted_object_graph(
      fs, rfs, src_db, git_dir, wanted_id, transferred_object_ids,
    )
  }
  let fetch_log_all_ref_updates = @gitlib.read_config_value(
    fs,
    git_dir + "/config",
    "core",
    "logallrefupdates",
  ).map(fn(v) { v.to_lower() })
  let fetch_log_enabled = match fetch_log_all_ref_updates {
    Some("always") => true
    _ => parse_config_bool_string(fetch_log_all_ref_updates)
  }
  let (fetch_name, fetch_email, fetch_timestamp, fetch_timezone) = get_committer_identity()
  let fetch_message = if explicit_refspecs.length() > 0 {
    "fetch " + remote_url + " " + explicit_refspecs.join(" ") + ": storing head"
  } else {
    "fetch " + remote_url + ": storing head"
  }
  fs.write_string(
    git_dir + "/FETCH_HEAD",
    render_fetch_head_content(fetch_head_entries, remote_url),
  )
  if explicit_refspecs.length() == 0 && not(mirror_fetch) {
    match @gitlib.read_remote_head_branch(fs, src_git_dir) {
      Some(remote_head_branch) =>
        update_remote_tracking_head_ref(
          fs, git_dir, remote_name, remote_head_branch, quiet,
        )
      None => ()
    }
  }
  for dst, id in mapped_refs {
    if not(update_head_ok) && dst.has_prefix("refs/heads/") {
      let branch_name = String::unsafe_substring(
        dst,
        start=11,
        end=dst.length(),
      )
      match @gitlib.is_branch_checked_out(fs, root, branch_name) {
        Some(_) =>
          raise @git.GitError::InvalidObject(
            "refusing to fetch into branch '" + branch_name + "' checked out",
          )
        None => ()
      }
    }
    let old_id = @gitlib.resolve_ref(fs, git_dir, dst).unwrap_or(
      @git.ObjectId::zero(),
    )
    write_ref_file(fs, git_dir, dst, id)
    if fetch_log_enabled {
      @gitrepo.append_reflog(
        fs, fs, git_dir, dst, old_id, id, fetch_name, fetch_email, fetch_timestamp,
        fetch_timezone, fetch_message,
      )
    }
  }
  let tagopt = rc.tagopt
  if not(fetches_tags) {
    match tagopt {
      Some("--no-tags") => ()
      Some("--tags") =>
        for refname, id in remote_refs {
          if refname.has_prefix("refs/tags/") {
            copy_wanted_object_graph(
              fs, rfs, src_db, git_dir, id, transferred_object_ids,
            )
            write_ref_file(fs, git_dir, refname, id)
          }
        }
      _ =>
        if fetched_heads.length() > 0 {
          for refname, id in remote_refs {
            if not(refname.has_prefix("refs/tags/")) {
              continue
            }
            let target = peel_to_commit(src_db, fs, id)
            guard target is Some(tag_commit) else { continue }
            let mut reachable = false
            for head_id in fetched_heads {
              if is_ancestor_commit(src_db, fs, tag_commit, head_id) {
                reachable = true
                break
              }
            }
            if reachable {
              copy_wanted_object_graph(
                fs, rfs, src_db, git_dir, id, transferred_object_ids,
              )
              write_ref_file(fs, git_dir, refname, id)
            }
          }
        }
    }
  }
  if mirror_fetch && @gitlib.is_bare_git_dir(git_dir) {
    match @gitlib.read_remote_head_branch(fs, src_git_dir) {
      Some(name) =>
        fs.write_string(git_dir + "/HEAD", "ref: refs/heads/" + name + "\n")
      None => ()
    }
  }
}

///|
enum UploadPackTransport {
  Http
  Process
}

///|
fn resolve_upload_pack_transport(remote_url : String) -> UploadPackTransport {
  let remote_spec = @protocol.parse_remote(remote_url)
  if remote_spec.kind == @protocol.RemoteKind::Http {
    UploadPackTransport::Http
  } else {
    UploadPackTransport::Process
  }
}

///|
async fn fetch_from_remote(
  fs : OsFs,
  git_dir : String,
  root : String,
  remote_name : String,
  remote_url : String,
  explicit_refspecs : Array[String],
  update_head_ok? : Bool = false,
  filter? : @protocol.FilterSpec = @protocol.FilterSpec::NoFilter,
  force_transport? : Bool = false,
  quiet? : Bool = false,
) -> Unit raise Error {
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  if not(force_transport) {
    match @gitlib.resolve_local_repo_path(fs, local_root, remote_url) {
      Some(src_path) => {
        fetch_local_repo(
          fs,
          src_path,
          root,
          git_dir,
          remote_name,
          remote_url,
          explicit_refspecs,
          update_head_ok~,
          quiet~,
        )
        return ()
      }
      None => ()
    }
  }
  let transport = resolve_upload_pack_transport(remote_url)
  let (refs, _caps, _version, symrefs) = match transport {
    UploadPackTransport::Http =>
      @gitionative.discover_upload_refs_http(remote_url, true)
    UploadPackTransport::Process =>
      @gitionative.discover_upload_refs_process(remote_url, true)
  }
  let default_ref = @protocol.select_default_ref(refs, symrefs)
  match default_ref {
    None => {
      print_line("No refs to fetch")
      return ()
    }
    Some((refname, commit_id)) => {
      let remote_ref = if refname.has_prefix("refs/heads/") {
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        "refs/remotes/" + remote_name + "/" + name
      } else {
        "refs/remotes/" + remote_name + "/HEAD"
      }
      let remote_path = git_dir + "/" + remote_ref
      let mut prev_id : @git.ObjectId? = None
      if fs.is_file(remote_path) {
        let content = decode_bytes(
          fs.read_file(remote_path) catch {
            err => {
              if @async.is_being_cancelled() ||
                @async.is_cancellation_error(err) {
                raise err
              }
              Bytes::default()
            }
          },
        )
        let hex = trim_string(content)
        if hex.length() > 0 {
          prev_id = (hex |> @git.ObjectId::from_hex |> Some) catch {
            err => {
              if @async.is_being_cancelled() ||
                @async.is_cancellation_error(err) {
                raise err
              }
              None
            }
          }
        }
      }
      if prev_id is Some(pid) && pid == commit_id {
        return ()
      }
      print_line("Fetching from \{remote_url}...")
      let pack = match transport {
        UploadPackTransport::Http =>
          @gitionative.fetch_pack_http(remote_url, [commit_id], true, filter~)
        UploadPackTransport::Process =>
          @gitionative.fetch_pack_process(
            remote_url,
            [commit_id],
            true,
            filter~,
          )
      }
      if pack.length() > 0 {
        let objects = @pack.parse_packfile(pack)
        @pack.write_packfile_with_index(fs, git_dir, pack, objects)
        if filter.is_partial() {
          ensure_promisor_remote_file(fs, git_dir, remote_url)
          let pack_id = read_pack_trailer_id(pack)
          write_fetch_pack_promisor_marker(
            fs, git_dir, pack_id, refname, commit_id,
          )
        }
      } else {
        let db_opt = (@gitlib.ObjectDb::load(fs, git_dir) |> Some) catch {
          _ => None
        }
        let has_target = match db_opt {
          Some(db) => (db.get(fs, commit_id) catch { _ => None }) is Some(_)
          None => false
        }
        if not(has_target) {
          raise @git.GitError::PackfileError(
            "No packfile returned and missing object \{commit_id.to_hex()}",
          )
        }
      }
      let dir = match remote_path.rev_find("/") {
        None => ""
        Some(i) => String::unsafe_substring(remote_path, start=0, end=i)
      }
      if dir.length() > 0 {
        fs.mkdir_p(dir)
      }
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      print_line("From \{remote_url}")
      match prev_id {
        None => print_line(" * [new branch] \{refname} -> \{remote_ref}")
        Some(pid) =>
          print_line(
            "   \{pid.to_hex()}..\{commit_id.to_hex()}  \{refname} -> \{remote_ref}",
          )
      }
    }
  }
}

///|
fn read_pack_trailer_id(pack : Bytes) -> @git.ObjectId raise Error {
  if pack.length() < 20 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  let trailer_start = pack.length() - 20
  let bytes = FixedArray::makei(20, i => pack[trailer_start + i])
  @git.ObjectId::new(bytes)
}

///|
fn ensure_promisor_remote_file(
  fs : OsFs,
  git_dir : String,
  remote_url : String,
) -> Unit raise Error {
  let info_dir = git_dir + "/objects/info"
  fs.mkdir_p(info_dir)
  let promisor_path = info_dir + "/promisor"
  if fs.is_file(promisor_path) {
    return ()
  }
  fs.write_string(promisor_path, remote_url + "\n")
}

///|
fn write_fetch_pack_promisor_marker(
  fs : OsFs,
  git_dir : String,
  pack_id : @git.ObjectId,
  refname : String,
  commit_id : @git.ObjectId,
) -> Unit raise Error {
  let pack_dir = git_dir + "/objects/pack"
  let marker_path = pack_dir + "/pack-\{pack_id.to_hex()}.promisor"
  let lines = [commit_id.to_hex() + " HEAD", commit_id.to_hex() + " " + refname]
  fs.write_string(marker_path, lines.join("\n") + "\n")
}

///|

///|

///|
fn is_ancestor_commit(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  ancestor : @git.ObjectId,
  commit_id : @git.ObjectId,
) -> Bool {
  let stack : Array[@git.ObjectId] = [commit_id]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = stack.pop().unwrap_or(ancestor)
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if id == ancestor {
      return true
    }
    let obj = db.get(fs, id) catch { _ => continue }
    guard obj is Some(o) else { continue }
    let info = @git.parse_commit(o.data) catch { _ => continue }
    for p in info.parents {
      stack.push(p)
    }
  }
  false
}

///|
fn parse_tag_target(data : Bytes) -> @git.ObjectId? {
  let text = @utf8.decode_lossy(data[:])
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("object ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      let id = @git.ObjectId::from_hex(hex) catch { _ => return None }
      return Some(id)
    }
  }
  None
}

///|
fn copy_wanted_object_graph(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  src_db : @gitlib.ObjectDb,
  dst_git_dir : String,
  wanted_id : @git.ObjectId,
  transferred_object_ids : Map[String, Bool],
) -> Unit raise Error {
  let wanted_hex = wanted_id.to_hex()
  if transferred_object_ids.contains(wanted_hex) {
    return
  }
  let wanted_obj_opt = src_db.get(rfs, wanted_id) catch { _ => None }
  guard wanted_obj_opt is Some(wanted_obj) else { return }
  transferred_object_ids[wanted_hex] = true
  ignore(
    @gitlib.write_loose_object(
      fs,
      dst_git_dir,
      wanted_obj.obj_type,
      wanted_obj.data,
    ),
  )
  if wanted_obj.obj_type == @git.ObjectType::Commit {
    let reachable = @gitlib.collect_reachable_objects(src_db, rfs, wanted_id) catch {
      _ => []
    }
    for reachable_obj in reachable {
      let copy_id = @git.hash_object_content(
        reachable_obj.obj_type,
        reachable_obj.data,
      )
      let copy_hex = copy_id.to_hex()
      if transferred_object_ids.contains(copy_hex) {
        continue
      }
      transferred_object_ids[copy_hex] = true
      ignore(
        @gitlib.write_loose_object(
          fs,
          dst_git_dir,
          reachable_obj.obj_type,
          reachable_obj.data,
        ),
      )
    }
  } else if wanted_obj.obj_type == @git.ObjectType::Tag {
    match parse_tag_target(wanted_obj.data) {
      Some(tag_target_id) =>
        copy_wanted_object_graph(
          fs, rfs, src_db, dst_git_dir, tag_target_id, transferred_object_ids,
        )
      None => ()
    }
  }
}

///|
fn peel_to_commit(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> @git.ObjectId? {
  let mut current = id
  for _ in 0..<5 {
    let obj = db.get(fs, current) catch { _ => return None }
    guard obj is Some(o) else { return None }
    match o.obj_type {
      @git.ObjectType::Commit => return Some(current)
      @git.ObjectType::Tag =>
        match parse_tag_target(o.data) {
          Some(next) => current = next
          None => return None
        }
      _ => return None
    }
  }
  None
}

///|
fn format_push_lines(
  lines : Array[(String, String, String, String?)],
  include_status : Bool,
) -> Array[String] {
  let out : Array[String] = []
  if lines.length() == 0 {
    return out
  }
  let mut max_src = 0
  for item in lines {
    let (src, _action, _dst, _status) = item
    if src.length() > max_src {
      max_src = src.length()
    }
  }
  for item in lines {
    let (src, action, dst, status) = item
    let mut base = src
    if src.length() < max_src {
      let mut pad = ""
      for _ in 0..<(max_src - src.length()) {
        pad = pad + " "
      }
      base = base + pad
    }
    let mut line = "    " + base + " " + action + " " + dst
    if include_status && status is Some(st) {
      let target_col = 24
      let current = line.length() - 4
      if current < target_col {
        let mut pad = ""
        for _ in 0..<(target_col - current) {
          pad = pad + " "
        }
        line = line + pad + st
      } else {
        line = line + " " + st
      }
    }
    out.push(line)
  }
  out
}

///|
async fn remote_show(
  fs : OsFs,
  git_dir : String,
  root : String,
  name : String,
  no_query : Bool,
) -> Unit raise Error {
  let (remotes, branches) = @gitlib.read_repo_config(fs, git_dir)
  guard remotes.get(name) is Some(rc) else {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  ignore(rc.mirror)
  let fetch_url = if rc.urls.length() > 0 { rc.urls[0] } else { "" }
  print_line("* remote \{name}")
  print_line("  Fetch URL: \{fetch_url}")
  let push_urls = if rc.pushurls.length() > 0 { rc.pushurls } else { rc.urls }
  if push_urls.length() == 0 {
    print_line("  Push  URL: \{fetch_url}")
  } else {
    for pu in push_urls {
      print_line("  Push  URL: \{pu}")
    }
  }
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  let remote_path = if no_query {
    None
  } else {
    @gitlib.resolve_local_repo_path(fs, local_root, fetch_url)
  }
  let remote_git_dir = match remote_path {
    Some(p) => @gitlib.detect_git_dir(fs, p).map(pair => pair.0)
    None => None
  }
  let head_branch = match remote_git_dir {
    Some(rgd) =>
      match @gitlib.read_head_ref(fs, rgd) {
        @gitlib.HeadRef::Branch(b) => b
        _ => "(unknown)"
      }
    None => "(not queried)"
  }
  print_line("  HEAD branch: \{head_branch}")
  if no_query || remote_git_dir is None {
    print_line("  Remote branches: (status not queried)")
    let local_refs = @gitlib.list_remote_tracking_refs(fs, git_dir, name)
    let names : Map[String, Bool] = {}
    for k, _ in local_refs {
      names[k] = true
    }
    for _, bc in branches {
      if bc.remote == Some(name) {
        for merge in bc.merges {
          let short = @gitlib.normalize_remote_branch_name(merge)
          if short.length() > 0 {
            names[short] = true
          }
        }
      }
    }
    let keys : Array[String] = []
    for k, _ in names {
      keys.push(k)
    }
    @gitlib.sort_strings_lex(keys)
    for k in keys {
      print_line("    \{k}")
    }
  } else {
    let rgd = remote_git_dir.unwrap_or("")
    let (_rhead, remote_branches) = @gitlib.list_branches(fs, rgd)
    let remote_map : Map[String, @git.ObjectId] = {}
    for b in remote_branches {
      remote_map[b.name] = b.id
    }
    let fetch_specs = @gitlib.parse_fetch_refspecs(rc.fetch)
    if fetch_specs.length() > 0 {
      print_line("  Remote branches:")
      let local_refs = @gitlib.list_remote_tracking_refs(fs, git_dir, name)
      let negative_specs : Array[@gitlib.FetchRefspec] = []
      let positive_specs : Array[@gitlib.FetchRefspec] = []
      for s in fetch_specs {
        if s.negative {
          negative_specs.push(s)
        } else {
          positive_specs.push(s)
        }
      }
      let remote_names : Array[String] = []
      for rname, _ in remote_map {
        remote_names.push(rname)
      }
      @gitlib.sort_strings_lex(remote_names)
      let emitted : Map[String, Bool] = {}
      for rname in remote_names {
        let full_ref = "refs/heads/" + rname
        let mut excluded = false
        for s in negative_specs {
          if @gitlib.refspec_capture(s.src, full_ref) is Some(_) {
            excluded = true
            break
          }
        }
        if excluded {
          if local_refs.contains(rname) {
            print_line("    \{rname} stale (use 'git remote prune' to remove)")
          } else {
            print_line("    \{rname} skipped")
          }
          emitted[rname] = true
          continue
        }
        let mut dest_ok = false
        for s in positive_specs {
          if @gitlib.refspec_map_dst(s.src, s.dst, full_ref) is Some(_) {
            dest_ok = true
            break
          }
        }
        if not(dest_ok) {
          continue
        }
        if local_refs.contains(rname) {
          print_line("    \{rname} tracked")
        } else {
          print_line(
            "    \{rname} new (next fetch will store in remotes/\{name})",
          )
        }
        emitted[rname] = true
      }
      for lname, _ in local_refs {
        if not(emitted.contains(lname)) {
          print_line("    \{lname} stale (use 'git remote prune' to remove)")
        }
      }
    }
  }
  let pull_branches : Array[@gitlib.BranchConfig] = []
  for _, bc in branches {
    if bc.remote is Some(rn) && rn == name && bc.merges.length() > 0 {
      pull_branches.push(bc)
    }
  }
  if pull_branches.length() > 0 {
    print_line("  Local branches configured for 'git pull':")
    let mut max_len = 0
    let mut any_rebase = false
    for bc in pull_branches {
      if bc.name.length() > max_len {
        max_len = bc.name.length()
      }
      if bc.rebase == Some(true) {
        any_rebase = true
      }
    }
    @gitlib.sort_branch_configs_by_name(pull_branches)
    for bc in pull_branches {
      let branch = bc.name
      let merge_target = @gitlib.normalize_remote_branch_name(bc.merges[0])
      let padded = pad_right(branch, max_len)
      let base = "    " + padded + " "
      match bc.rebase {
        Some(true) => print_line(base + "rebases onto remote " + merge_target)
        _ => {
          if any_rebase {
            print_line(base + " merges with remote " + merge_target)
          } else {
            print_line(base + "merges with remote " + merge_target)
          }
          if bc.merges.length() > 1 {
            let mut indent = max_len + 8
            if any_rebase {
              indent = indent + 1
            }
            let mut pad = ""
            for _ in 0..<indent {
              pad = pad + " "
            }
            for i in 1..<bc.merges.length() {
              let m = @gitlib.normalize_remote_branch_name(bc.merges[i])
              print_line(pad + "and with remote " + m)
            }
          }
        }
      }
    }
  }
  if rc.push.length() > 0 || no_query {
    let status_query = not(no_query) && remote_git_dir is Some(_)
    if status_query {
      print_line("  Local refs configured for 'git push':")
    } else {
      print_line("  Local refs configured for 'git push' (status not queried):")
    }
    let push_specs = @gitlib.parse_push_refspecs(rc.push)
    if push_specs.length() == 0 {
      push_specs.push({ force: false, src: "", dst: "" })
    }
    let push_lines : Array[(String, String, String, String?)] = []
    let local_db = @gitlib.ObjectDb::load(fs, git_dir)
    let remote_db = match remote_git_dir {
      Some(rgd) => Some(@gitlib.ObjectDb::load(fs, rgd))
      None => None
    }
    let head_branch = match @gitlib.read_head_ref(fs, git_dir) {
      @gitlib.HeadRef::Branch(b) => Some(b)
      _ => None
    }
    for spec in push_specs {
      if status_query && spec.src.length() == 0 {
        match head_branch {
          Some(branch) => {
            let src_ref = "refs/heads/" + branch
            let dst_ref = "refs/heads/" + branch
            let local_id = @gitlib.resolve_ref(fs, git_dir, src_ref)
            let remote_id = match remote_git_dir {
              Some(rgd) => @gitlib.resolve_ref(fs, rgd, dst_ref)
              None => None
            }
            let status = match
              (local_id, remote_id, remote_git_dir, remote_db) {
              (Some(lid), Some(rid), Some(_), Some(rdb)) =>
                if lid == rid {
                  Some("(up to date)")
                } else if is_ancestor_commit(rdb, fs, lid, rid) {
                  Some("(local out of date)")
                } else if is_ancestor_commit(local_db, fs, rid, lid) {
                  Some("(fast-forwardable)")
                } else {
                  Some("(local out of date)")
                }
              (Some(_), None, _, _) => Some("(create)")
              _ => None
            }
            push_lines.push((branch, "pushes to", branch, status))
          }
          None => ()
        }
        continue
      }
      if status_query &&
        spec.src.has_prefix("refs/") &&
        not(spec.src.has_prefix("refs/heads/")) {
        continue
      }
      let src_display = if spec.src.length() == 0 {
        "(matching)"
      } else if status_query {
        @gitlib.normalize_remote_branch_name(spec.src)
      } else {
        spec.src
      }
      let dst_display = if spec.dst.length() == 0 {
        "(matching)"
      } else if status_query {
        @gitlib.normalize_remote_branch_name(spec.dst)
      } else {
        spec.dst
      }
      let action = if spec.force { "forces to" } else { "pushes to" }
      let status = if status_query {
        let src_ref = if spec.src.has_prefix("refs/") {
          spec.src
        } else {
          "refs/heads/" + spec.src
        }
        let dst_ref = if spec.dst.length() == 0 {
          src_ref
        } else if spec.dst.has_prefix("refs/") {
          spec.dst
        } else {
          "refs/heads/" + spec.dst
        }
        let local_id = @gitlib.resolve_ref(fs, git_dir, src_ref)
        let remote_id = match remote_git_dir {
          Some(rgd) => @gitlib.resolve_ref(fs, rgd, dst_ref)
          None => None
        }
        match (local_id, remote_id, remote_git_dir, remote_db) {
          (Some(lid), Some(rid), Some(_), Some(rdb)) =>
            if lid == rid {
              Some("(up to date)")
            } else if is_ancestor_commit(rdb, fs, lid, rid) {
              Some("(local out of date)")
            } else if is_ancestor_commit(local_db, fs, rid, lid) {
              Some("(fast-forwardable)")
            } else {
              Some("(local out of date)")
            }
          (Some(_), None, _, _) => Some("(create)")
          _ => None
        }
      } else {
        None
      }
      push_lines.push((src_display, action, dst_display, status))
    }
    let formatted = format_push_lines(push_lines, status_query)
    for line in formatted {
      print_line(line)
    }
  }
}

///|
fn parse_pack_args(args : Array[String]) -> (Bool, String)? {
  let mut advertise = false
  let mut repo : String? = None
  for arg in args {
    match arg {
      "--advertise-refs" => advertise = true
      "--http-backend-info-refs" => advertise = true
      "--stateless-rpc" => continue
      _ if arg.has_prefix("--") => continue
      _ => if repo is None { repo = Some(arg) }
    }
  }
  match repo {
    Some(path) => Some((advertise, path))
    None => None
  }
}

///|
