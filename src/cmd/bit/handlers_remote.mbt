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
  @gitlib.resolve_remote_ref_id(remote_url, ref_spec)
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
  let (response, content) = @git.native_http_get(url, headers)
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
      let track_branches : Array[String] = []
      let positional : Array[String] = []
      let mut i = 1
      while i < args.length() {
        let arg = args[i]
        match arg {
          "-f" | "--fetch" => fetch_after_add = true
          "--mirror" =>
            match mirror_mode {
              None => mirror_mode = Some("mirror")
              Some(_) => die_remote(129, "usage: git remote add <name> <url>")
            }
          _ if arg.has_prefix("--mirror=") => {
            let mode = String::unsafe_substring(arg, start=9, end=arg.length())
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
        i += 1
      }
      if positional.length() != 2 {
        die_remote(129, "usage: git remote add <name> <url>")
      }
      let name = positional[0]
      let url = positional[1]
      if not(@gitlib.is_valid_remote_name(name)) {
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
      remote_add(fs, fs, git_dir, name, url, fetch_specs, mirror_push, tagopt)
      if fetch_after_add {
        fetch_from_remote(fs, git_dir, root, name, url)
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
      if not(@gitlib.is_valid_remote_name(new_name)) {
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
          _ => ()
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
  match tagopt {
    Some(val) => lines.push("\ttagOpt = " + val)
    None => ()
  }
  let new_blocks = blocks
  new_blocks.push({
    header: Some("[remote \"\{name}\"]"),
    section: Some("remote"),
    name: Some(name),
    lines,
  })
  fs.write_string(config_path, @gitlib.render_config_blocks(new_blocks))
}

///|
async fn remote_remove(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
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
      _ => ()
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
) -> Unit raise @git.GitError {
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
          _ => ()
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
        _ => ()
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
        _ => ()
      }
      eprint_line(
        "error: The remote you are trying to rename has conflicting references",
      ) catch {
        _ => ()
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
        let (should_log, _) = @gitlib.should_log_ref(
          fs, git_dir, new_ref, is_bare,
        )
        if should_log {
          @gitlib.append_reflog(
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
  let remote_git_dir = @gitlib.detect_git_dir(fs, path).map(fn(pair) { pair.0 })
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
          fetch_from_remote(fs, git_dir, root, name, url)
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
  let remote_git_dir = @gitlib.detect_git_dir(fs, path).map(fn(pair) { pair.0 })
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
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u
        None => "Unknown"
      }
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
fn clone_local_repo(
  fs : OsFs,
  src_path : String,
  dest_path : String,
  remote_url : String,
  bare : Bool,
  filter : @git.FilterSpec,
) -> Unit raise Error {
  guard @gitlib.detect_git_dir(fs, src_path) is Some((src_git_dir, _)) else {
    raise @git.GitError::InvalidObject("Not a git repository: \{src_path}")
  }
  let (head_ref, branches) = @gitlib.list_branches(fs, src_git_dir)
  let (default_branch, head_id) = match head_ref {
    @gitlib.HeadRef::Branch(name) => {
      let refname = "refs/heads/" + name
      let id = match @gitlib.resolve_ref(fs, src_git_dir, refname) {
        Some(v) => v
        None =>
          raise @git.GitError::InvalidObject("Invalid HEAD ref: \{refname}")
      }
      (name, id)
    }
    @gitlib.HeadRef::Detached(id) => ("main", id)
  }
  @gitlib.init_repo(fs, dest_path, default_branch~, bare~)
  let dest_git_dir = if bare { dest_path } else { dest_path + "/.git" }
  // Copy object database
  @gitlib.copy_tree(fs, fs, src_git_dir + "/objects", dest_git_dir + "/objects")
  // Set local HEAD branch to source HEAD
  write_ref_file(fs, dest_git_dir, "refs/heads/" + default_branch, head_id)
  // Configure origin
  remote_add(
    fs,
    fs,
    dest_git_dir,
    "origin",
    remote_url,
    ["+refs/heads/*:refs/remotes/origin/*"],
    false,
    None,
  )
  if not(bare) {
    @gitlib.set_config_key(
      fs, fs, dest_git_dir, "branch", default_branch, "remote", "origin",
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
  }
  // Set remote tracking refs
  for b in branches {
    write_ref_file(fs, dest_git_dir, "refs/remotes/origin/" + b.name, b.id)
  }
  write_symref_file(
    fs,
    dest_git_dir,
    "refs/remotes/origin/HEAD",
    "refs/remotes/origin/" + default_branch,
  )
  // Partial clone markers
  if filter.is_partial() {
    @gitlib.set_config_key(
      fs, fs, dest_git_dir, "remote", "origin", "promisor", "true",
    )
    @gitlib.set_config_key(
      fs,
      fs,
      dest_git_dir,
      "remote",
      "origin",
      "partialCloneFilter",
      filter.to_string(),
    )
    let promisor_path = dest_git_dir + "/objects/info/promisor"
    fs.write_string(promisor_path, remote_url + "\n")
  }
  // Copy working tree for non-bare
  if not(bare) {
    let entries = fs.readdir(src_path) catch { _ => [] }
    for entry in entries {
      if entry == ".git" {
        continue
      }
      @gitlib.copy_tree(fs, fs, src_path + "/" + entry, dest_path + "/" + entry)
    }
    let db = @gitlib.ObjectDb::load(fs, dest_git_dir)
    let files = @gitlib.collect_tree_files_from_commit(db, fs, head_id)
    let index_entries = @gitlib.tree_files_to_index(db, fs, files)
    @gitlib.write_index_entries(fs, dest_git_dir, index_entries)
  }
}

///|
async fn fetch_local_repo(
  fs : OsFs,
  src_path : String,
  git_dir : String,
  remote_name : String,
  remote_url : String,
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
  print_line("From \{display_url}")
  @gitlib.copy_tree(fs, fs, src_git_dir + "/objects", git_dir + "/objects")
  let (remotes, _) = @gitlib.read_repo_config(fs, git_dir)
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
  let fetch_specs = @gitlib.parse_fetch_refspecs(rc.fetch)
  if fetch_specs.length() == 0 {
    fetch_specs.push({
      negative: false,
      src: "refs/heads/*",
      dst: "refs/remotes/" + remote_name + "/*",
    })
  }
  let negative_specs : Array[@gitlib.FetchRefspec] = []
  let positive_specs : Array[@gitlib.FetchRefspec] = []
  for spec in fetch_specs {
    if spec.negative {
      negative_specs.push(spec)
    } else {
      positive_specs.push(spec)
    }
  }
  let remote_refs = @gitlib.list_refs_with_ids(fs, src_git_dir, Some("refs/"))
  let mut mirror_fetch = @gitlib.is_mirror_fetch_config(rc)
  let mut fetches_tags = false
  for spec in positive_specs {
    if spec.src.has_prefix("refs/tags/") || spec.src == "refs/*" {
      fetches_tags = true
    }
    if spec.src == "refs/*" {
      mirror_fetch = true
    }
  }
  let fetched_heads : Array[@git.ObjectId] = []
  let mapped_refs : Map[String, @git.ObjectId] = {}
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
    for spec in positive_specs {
      if spec.dst.length() == 0 {
        continue
      }
      match @gitlib.refspec_map_dst(spec.src, spec.dst, refname) {
        Some(dst) => {
          mapped_refs[dst] = id
          if refname.has_prefix("refs/heads/") {
            fetched_heads.push(id)
          }
        }
        None => ()
      }
    }
  }
  for dst, id in mapped_refs {
    write_ref_file(fs, git_dir, dst, id)
  }
  if not(mirror_fetch) {
    match @gitlib.read_remote_head_branch(fs, src_git_dir) {
      Some(name) =>
        write_symref_file(
          fs,
          git_dir,
          "refs/remotes/" + remote_name + "/HEAD",
          "refs/remotes/" + remote_name + "/" + name,
        )
      None => ()
    }
  }
  let tagopt = rc.tagopt
  if not(fetches_tags) {
    match tagopt {
      Some("--no-tags") => ()
      Some("--tags") =>
        for refname, id in remote_refs {
          if refname.has_prefix("refs/tags/") {
            write_ref_file(fs, git_dir, refname, id)
          }
        }
      _ =>
        if fetched_heads.length() > 0 {
          let local_db = @gitlib.ObjectDb::load(fs, git_dir)
          for refname, id in remote_refs {
            if not(refname.has_prefix("refs/tags/")) {
              continue
            }
            let target = peel_to_commit(local_db, fs, id)
            guard target is Some(tag_commit) else { continue }
            let mut reachable = false
            for head_id in fetched_heads {
              if is_ancestor_commit(local_db, fs, tag_commit, head_id) {
                reachable = true
                break
              }
            }
            if reachable {
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
async fn fetch_from_remote(
  fs : OsFs,
  git_dir : String,
  root : String,
  remote_name : String,
  remote_url : String,
) -> Unit raise Error {
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  match @gitlib.resolve_local_repo_path(fs, local_root, remote_url) {
    Some(src_path) => {
      fetch_local_repo(fs, src_path, git_dir, remote_name, remote_url)
      return ()
    }
    None => ()
  }
  // Fallback to HTTP fetch
  let (refs, _caps, _version, symrefs) = @git.discover_upload_refs_http(
    remote_url, true,
  )
  let default_ref = @git.select_default_ref(refs, symrefs)
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
            _ => Bytes::default()
          },
        )
        let hex = trim_string(content)
        if hex.length() > 0 {
          prev_id = Some(@git.ObjectId::from_hex(hex)) catch { _ => None }
        }
      }
      if prev_id is Some(pid) && pid == commit_id {
        return ()
      }
      print_line("Fetching from \{remote_url}...")
      let pack = @git.fetch_pack_http(remote_url, [commit_id], true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
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
    Some(p) => @gitlib.detect_git_dir(fs, p).map(fn(pair) { pair.0 })
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
async fn handle_upload_pack(args : Array[String]) -> Unit {
  // Handle -h option
  for arg in args {
    if arg == "-h" {
      print_line(
        "usage: git upload-pack [--[no-]strict] [--timeout=<n>] [--stateless-rpc]",
      )
      print_line("                       [--advertise-refs] <dir>")
      @sys.exit(129)
    }
  }
  let mut advertise = false
  let mut protocol_version = 1
  try {
    // Parse config overrides from environment variable
    let cmdline_config = @gitlib.parse_config_overrides()
    guard parse_pack_args(args) is Some((advertise_flag, repo_path)) else {
      raise @git.GitError::ProtocolError("missing repository path")
    }
    advertise = advertise_flag
    let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
      // Bare repository with .git suffix
      repo_path
    } else {
      normalize_repo_root(repo_path)
    }
    let fs = OsFs::new()
    let git_dir = if root.has_suffix(".git") && !root.has_suffix("/.git") {
      root
    } else {
      root + "/.git"
    }
    let config_git_dir = if fs.is_file(root + "/config") { root } else { git_dir }
    if is_sha256_repo(config_git_dir) {
      match real_git_path() {
        Some(real_git) => {
          let real_args = real_git_args_from_cli()
          let code = @process.run(real_git, real_args)
          @sys.exit(code)
        }
        None => {
          @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
          @sys.exit(1)
        }
      }
    }
    let mut has_uploadpackfilter = false
    for entry in cmdline_config {
      let (key, _value) = entry
      if key.has_prefix("uploadpackfilter.") {
        has_uploadpackfilter = true
        break
      }
    }
    let allow_filter =
      match git_config_get(config_git_dir, "uploadpack", "allowfilter") {
        Some(value) =>
          match parse_bool_value(value) {
            Some(flag) => flag
            None => false
          }
        None => false
      }
    let allow_any_want =
      match git_config_get(config_git_dir, "uploadpack", "allowanysha1inwant") {
        Some(value) =>
          match parse_bool_value(value) {
            Some(flag) => flag
            None => false
          }
        None => false
      }
    if has_uploadpackfilter || allow_filter || allow_any_want {
      match real_git_path() {
        Some(real_git) => {
          let real_args = real_git_args_from_cli()
          let code = @process.run(real_git, real_args)
          @sys.exit(code)
        }
        None => ()
      }
    }
    if advertise {
      match real_git_path() {
        Some(real_git) => {
          let real_args = real_git_args_from_cli()
          let code = @process.run(real_git, real_args)
          @sys.exit(code)
        }
        None => ()
      }
    }
    if advertise {
      let out = @gitlib.build_upload_pack_advertisement(fs, root)
      @stdio.stdout.write(out)
    } else {
      let input = read_all_stdin()
      // Check protocol version from GIT_PROTOCOL environment variable
      protocol_version = @gitlib.get_protocol_version()
      if protocol_version == 2 {
        // Protocol v2: parse and handle v2 request
        let req = @gitlib.parse_upload_pack_request_v2(input)
        let config = @gitlib.build_upload_pack_config_with_overrides(
          fs, root, cmdline_config,
        )
        let out = @gitlib.upload_pack_v2(fs, root, req, config)
        @stdio.stdout.write(out)
      } else {
        // Protocol v1: use existing handler
        let req = @gitlib.parse_upload_pack_request(input)
        let out = @gitlib.upload_pack(fs, root, req)
        @stdio.stdout.write(out)
      }
    }
  } catch {
    err => upload_pack_fail(err, protocol_version, advertise)
  }
}

///|
async fn upload_pack_fail(
  err : Error,
  protocol_version : Int,
  advertise : Bool,
) -> Unit {
  let _ : Int = protocol_version
  let msg = upload_pack_error_text(err)
  if not(advertise) {
    let line = upload_pack_first_line(msg)
    let pkt = @git.pktline_encode("ERR " + line + "\n")
    @stdio.stdout.write(pkt)
  }
  @stdio.stderr.write(msg + "\n")
  @sys.exit(1)
}

///|
fn upload_pack_error_text(err : Error) -> String {
  match err {
    @git.GitError::ProtocolError(msg) => msg
    @git.GitError::InvalidObject(msg) => msg
    @git.GitError::PackfileError(msg) => msg
    @git.GitError::HashMismatch(_, _) => "hash mismatch"
    @git.GitError::IoError(msg) => msg
    _ => err.to_string()
  }
}

///|
fn upload_pack_first_line(msg : String) -> String {
  match msg.find("\n") {
    Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
    None => msg
  }
}

///|
async fn handle_receive_pack(args : Array[String]) -> Unit {
  // Handle -h option
  for arg in args {
    if arg == "-h" {
      print_line("usage: git receive-pack <git-dir>")
      @sys.exit(129)
    }
  }
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    // Bare repository with .git suffix
    repo_path
  } else {
    normalize_repo_root(repo_path)
  }
  let fs = OsFs::new()
  let git_dir = if root.has_suffix(".git") && !root.has_suffix("/.git") {
    root
  } else {
    root + "/.git"
  }
  if is_sha256_repo(git_dir) {
    match real_git_path() {
      Some(real_git) => {
        let real_args = real_git_args_from_cli()
        let code = @process.run(real_git, real_args)
        @sys.exit(code)
      }
      None => {
        @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
        @sys.exit(1)
      }
    }
  }
  if not(advertise) {
    match real_git_path() {
      Some(real_git) => {
        let real_args = real_git_args_from_cli()
        let code = @process.run(real_git, real_args)
        @sys.exit(code)
      }
      None => ()
    }
  }
  if advertise {
    match real_git_path() {
      Some(real_git) => {
        let real_args = real_git_args_from_cli()
        let code = @process.run(real_git, real_args)
        @sys.exit(code)
      }
      None => ()
    }
  }
  if advertise {
    let out = @gitlib.build_receive_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    let out = @gitlib.receive_pack(fs, fs, root, input)
    @stdio.stdout.write(out)
  }
}

///|
/// Parse filter specification from command line
fn parse_filter_spec(spec : String) -> @git.FilterSpec {
  if spec == "blob:none" {
    @git.FilterSpec::BlobNone
  } else if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = @strconv.parse_int64(limit_str) catch { _ => 0L }
    @git.FilterSpec::BlobLimit(limit)
  } else if spec.has_prefix("tree:") {
    let depth_str = String::unsafe_substring(spec, start=5, end=spec.length())
    let depth = @strconv.parse_int(depth_str) catch { _ => 0 }
    @git.FilterSpec::TreeDepth(depth)
  } else {
    @git.FilterSpec::NoFilter
  }
}

///|
async fn handle_clone(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let mut url : String? = None
  let mut dest : String? = None
  let mut depth = 0
  let mut filter = @git.FilterSpec::NoFilter
  let mut has_filter_flag = false
  let mut bare = false
  let mut ref_spec : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--depth" && i + 1 < args.length() {
      // Parse depth value
      let depth_str = args[i + 1]
      depth = @strconv.parse_int(depth_str) catch { _ => 0 }
      i += 2
      continue
    }
    if arg.has_prefix("--depth=") {
      let depth_str = String::unsafe_substring(arg, start=8, end=arg.length())
      depth = @strconv.parse_int(depth_str) catch { _ => 0 }
      i += 1
      continue
    }
    if arg == "--bare" {
      bare = true
      i += 1
      continue
    }
    // Parse --filter option
    if arg == "--filter" && i + 1 < args.length() {
      has_filter_flag = true
      filter = parse_filter_spec(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--filter=") {
      has_filter_flag = true
      let filter_str = String::unsafe_substring(arg, start=9, end=arg.length())
      filter = parse_filter_spec(filter_str)
      i += 1
      continue
    }
    if arg.has_prefix("-") {
      warn_unimplemented_arg("clone", arg)
      i += 1
      continue
    }
    if url is None {
      url = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
    i += 1
  }
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  if has_filter_flag {
    match real_git_path() {
      Some(real_git) => {
        let real_args = real_git_args_from_cli()
        let code = @process.run(real_git, real_args)
        @sys.exit(code)
      }
      None => ()
    }
  }
  // Check for ambiguity with local directories
  let fs = OsFs::new()
  match check_shorthand_ambiguity(remote_url, fn(p) { fs.is_dir(p) }) {
    Some(conflict_path) =>
      raise @git.GitError::InvalidObject(
        "Ambiguous: '\{conflict_path}' exists locally. Use full URL or ./\{remote_url} for local path.",
      )
    None => ()
  }
  // Check for shorthand (user/repo, user/repo:path, or browser URL)
  match parse_github_shorthand(remote_url) {
    Some(Repo(github_url, refname)) => {
      // user/repo → normal clone from GitHub
      print_line("Shorthand: \{github_url}")
      url = Some(github_url)
      ref_spec = refname
    }
    Some(Subdir(github_url, subdir, refname)) => {
      // user/repo:path or /tree/ URL → subdir clone
      print_line("Subdir clone: \{github_url} → \{subdir}")
      return subdir_clone(github_url, subdir, dest, refname)
    }
    Some(File(raw_url, filename)) => {
      // /blob/ URL → single file fetch
      let target_file = match dest {
        Some(d) => d
        None => filename
      }
      print_line("Fetching file: \{raw_url}")
      return fetch_raw_file(raw_url, target_file)
    }
    None => ()
  }
  // Re-extract remote_url after potential shorthand expansion
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Derive destination from URL if not specified
  let relative_target = match dest {
    Some(d) => d
    None => {
      let name = if remote_url.has_suffix(".git") {
        String::unsafe_substring(
          remote_url,
          start=0,
          end=remote_url.length() - 4,
        )
      } else {
        remote_url
      }
      match name.rev_find("/") {
        Some(i) =>
          String::unsafe_substring(name, start=i + 1, end=name.length())
        None => name
      }
    }
  }
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  // Show what kind of clone we're doing
  let clone_type = if filter.is_partial() {
    "partial clone (\{filter.to_string()})"
  } else if depth > 0 {
    "shallow clone (depth=\{depth})"
  } else {
    "full clone"
  }
  print_line("Cloning into '\{relative_target}'... (\{clone_type})")
  let fs = OsFs::new()
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  match @gitlib.resolve_local_repo_path(fs, local_root, remote_url) {
    Some(src_path) => {
      let remote_display = if remote_url.has_prefix("file://") {
        remote_url
      } else if remote_url.has_prefix("/") {
        remote_url
      } else {
        normalize_path(local_root + "/" + remote_url)
      }
      clone_local_repo(fs, src_path, target, remote_display, bare, filter)
      if not(bare) && not(filter.is_partial()) {
        let git_dir = target + "/.git"
        match @gitlib.resolve_head_commit(fs, git_dir) {
          Some(commit_id) =>
            @gitlib.apply_worktree_modes_from_commit(
              fs, fs, target, git_dir, commit_id,
            )
          None => ()
        }
      }
      if ref_spec is Some(refname) && not(bare) && not(filter.is_partial()) {
        let _ = @gitlib.checkout(fs, fs, target, refname)

      }
      print_line("done.")
    }
    None => {
      let refs = @git.clone_http_to_fs(
        remote_url,
        true,
        fs,
        target,
        depth~,
        filter~,
      )
      if not(bare) && not(filter.is_partial()) {
        let git_dir = target + "/.git"
        match @gitlib.resolve_head_commit(fs, git_dir) {
          Some(commit_id) =>
            @gitlib.apply_worktree_modes_from_commit(
              fs, fs, target, git_dir, commit_id,
            )
          None => ()
        }
      }
      if refs.length() > 0 {
        if ref_spec is Some(refname) && not(bare) && not(filter.is_partial()) {
          match resolve_remote_ref_id(remote_url, refname) {
            Some((commit_id, branch)) => {
              let git_dir = target + "/.git"
              let mut db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
              if db.get(fs, commit_id) is None {
                let pack = @git.fetch_pack_http(remote_url, [commit_id], true)
                let objects = @git.parse_packfile(pack)
                @git.write_packfile_with_index(fs, git_dir, pack, objects)
                db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
              }
              match branch {
                Some(name) => {
                  fs.mkdir_p(git_dir + "/refs/heads") catch {
                    _ => ()
                  }
                  fs.write_string(
                    git_dir + "/refs/heads/" + name,
                    commit_id.to_hex() + "\n",
                  ) catch {
                    _ => ()
                  }
                  let _ = @gitlib.checkout(fs, fs, target, name)

                }
                None => {
                  let _ = @gitlib.checkout(fs, fs, target, commit_id.to_hex())

                }
              }
            }
            None =>
              raise @git.GitError::InvalidObject("Unknown ref: " + refname)
          }
        }
        print_line("done.")
      } else {
        raise @git.GitError::InvalidObject("Clone failed: no refs found")
      }
    }
  }
}

///|
async fn handle_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let (remotes, _) = @gitlib.read_repo_config(fs, git_dir)
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_name = "origin"
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  let mut has_filter_flag = false
  // Override with command line argument
  for arg in args {
    if not(arg.has_prefix("-")) {
      match remotes.get(arg) {
        Some(rc) => {
          remote_name = arg
          if rc.urls.length() > 0 {
            remote_url = Some(rc.urls[0])
          }
        }
        None => remote_url = Some(arg)
      }
      break
    }
    if arg.has_prefix("--filter") || arg == "--refetch" || arg == "--no-filter" {
      has_filter_flag = true
      continue
    }
    if arg == "--prune" || arg == "-p" || arg == "--prune-tags" ||
      arg == "--tags" || arg == "--no-tags" {
      continue
    }
    warn_unimplemented_arg("fetch", arg)
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let mut is_partial_clone = false
  match remotes.get(remote_name) {
    Some(rc) =>
      if rc.promisor || rc.partial_clone_filter is Some(_) {
        is_partial_clone = true
      }
    None => ()
  }
  if has_filter_flag || is_partial_clone {
    match real_git_path() {
      Some(real_git) => {
        let real_args = real_git_args_from_cli()
        let code = @process.run(real_git, real_args)
        @sys.exit(code)
      }
      None => ()
    }
  }
  fetch_from_remote(fs, git_dir, root, remote_name, url)
}

///|
async fn handle_pull(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
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
  for arg in args {
    match arg {
      "--rebase" | "-r" => rebase = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("pull", arg)
      _ => {
        if arg_remote is None {
          arg_remote = Some(arg)
        } else if arg_refspec is None {
          arg_refspec = Some(arg)
        }
      }
    }
  }
  // Apply explicit remote argument
  match arg_remote {
    Some(r) =>
      match remotes.get(r) {
        Some(rc) => {
          remote_name = r
          if rc.urls.length() > 0 {
            remote_url = Some(rc.urls[0])
          }
        }
        None => remote_url = Some(r)
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
  fetch_from_remote(fs, git_dir, root, remote_name, url)
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
                @gitlib.copy_tree(fs, fs, src_git_dir + "/objects", git_dir + "/objects")
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
            let pack = @git.fetch_pack_http(url, [id], true)
            let objects = @git.parse_packfile(pack)
            @git.write_packfile_with_index(fs, git_dir, pack, objects)
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
}
///|
async fn handle_push(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  // Check if this is a subdir-clone
  let subdir_remote = match get_subdir_info(fs, git_dir) {
    Some((remote, _, _)) => Some(remote)
    None => None
  }
  // Parse arguments
  let mut remote_name = "origin"
  let mut refspec : String? = None
  let mut force = false
  let mut set_upstream = false
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "-u" | "--set-upstream" => set_upstream = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("push", arg)
      _ =>
        if refspec is None {
          // First non-option is either remote or refspec
          // Check if it's a known remote
          let url = @gitlib.get_remote_url(fs, git_dir, arg)
          if url is Some(_) {
            remote_name = arg
          } else {
            refspec = Some(arg)
          }
        } else {
          // Second non-option is refspec
          refspec = Some(arg)
        }
    }
  }
  // Get remote URL - prefer subdir-clone remote
  let remote_url = match subdir_remote {
    Some(url) => Some(url)
    None => @gitlib.get_remote_url(fs, git_dir, remote_name)
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No such remote: \{remote_name}")
  }
  // Determine refspec
  let refname = match refspec {
    Some(r) => if r.has_prefix("refs/") { r } else { "refs/heads/" + r }
    None => {
      // Use current branch
      let head_ref = @gitlib.read_head_ref(fs, git_dir)
      match head_ref {
        @gitlib.HeadRef::Branch(branch) => "refs/heads/" + branch
        @gitlib.HeadRef::Detached(_) =>
          raise @git.GitError::InvalidObject(
            "Cannot push from detached HEAD without refspec",
          )
      }
    }
  }
  // Check if this is a subdir-clone - if so, transform commits before push
  match get_subdir_info(fs, git_dir) {
    Some((remote_url, subdir_path, base_hex)) => {
      print_line("Pushing subdir-clone to \{remote_url}...")
      print_line("  Subdirectory: \{subdir_path}")
      handle_subdir_push(
        fs, root, git_dir, remote_url, subdir_path, base_hex, refname, force,
      ) catch {
        err => raise err
      }
    }
    None => {
      print_line("Pushing to \{url}...")
      match @gitlib.resolve_local_repo_path(fs, root, url) {
        Some(remote_path) => {
          let remote_git_dir = @gitlib.detect_git_dir(fs, remote_path)
            .map(fn(pair) { pair.0 })
          guard remote_git_dir is Some(rgd) else {
            raise @git.GitError::InvalidObject(
              "Not a git repository: " + remote_path,
            )
          }
          let local_id = match @gitlib.resolve_ref(fs, git_dir, refname) {
            Some(id) => id
            None =>
              match @gitlib.resolve_head_commit(fs, git_dir) {
                Some(id) => id
                None =>
                  raise @git.GitError::InvalidObject("HEAD not found")
              }
          }
          @gitlib.copy_tree(fs, fs, git_dir + "/objects", rgd + "/objects")
          write_ref_file(fs, rgd, refname, local_id)
          print_line("Push successful")
        }
        None => {
          ignore(force) // TODO: implement force push
          let result = @gitlib.push_http(fs, root, url, refname)
          print_line(result)
        }
      }
    }
  }
  if set_upstream {
    // TODO: set tracking branch
    print_line("Branch '\{refname}' set up to track remote branch.")
  }
}

///|
/// Handle push for subdir-clone repositories
/// Transforms local commits to fit the original repository structure
async fn handle_subdir_push(
  fs : OsFs,
  root : String,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  base_hex : String,
  refname : String,
  _force : Bool,
) -> Unit raise Error {
  // Step 1: Get local HEAD commit
  let local_head_opt = @gitlib.rev_parse(fs, git_dir, "HEAD") catch {
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard local_head_opt is Some(local_head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  print_line("  Local HEAD: \{local_head.to_hex()}")
  // Step 2: Get the initial commit (first commit in the subdir-clone)
  let initial_commit = find_initial_subdir_commit(fs, git_dir) catch {
    _ => raise @git.GitError::InvalidObject("Cannot find initial commit")
  }
  print_line("  Initial commit: \{initial_commit.to_hex()}")
  // Step 3: Collect local commits since initial
  let local_commits = collect_commits_since(
    fs, git_dir, initial_commit, local_head,
  ) catch {
    err => raise err
  }
  if local_commits.length() == 0 {
    print_line("Nothing to push.")
    return
  }
  print_line("  Found \{local_commits.length()} local commits to transform")
  // Step 4: Get upstream base commit
  let upstream_base = @git.ObjectId::from_hex(base_hex) catch {
    _ => raise @git.GitError::InvalidObject("Cannot parse base commit")
  }
  print_line("  Upstream base: \{upstream_base.to_hex()}")
  // Step 5: Fetch upstream base commit and its tree from remote
  print_line("  Fetching upstream objects...")
  let pack = @git.fetch_pack_http(remote_url, [upstream_base], true)
  let objects = @git.parse_packfile(pack)
  @git.write_packfile_with_index(fs, git_dir, pack, objects)
  print_line("  Fetched \{objects.length()} objects")
  // Step 6: Reload ObjectDb to pick up new packfile, then transform commits
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let mut parent : @git.ObjectId = upstream_base
  for commit_id in local_commits {
    let new_commit = transform_subdir_commit(
      fs, db, git_dir, commit_id, parent, subdir_path,
    ) catch {
      err => raise err
    }
    print_line("  Transformed: \{commit_id.to_hex()} -> \{new_commit.to_hex()}")
    parent = new_commit
  }
  // Step 7: Push the transformed commits (tree only, not parent history)
  let transformed_head : @git.ObjectId = parent
  print_line("  Pushing transformed commits...")
  let result = @gitlib.push_http_tree_only(
    fs, root, remote_url, transformed_head, upstream_base, refname,
  )
  print_line("  \{result}")
  // Step 8: Update base commit
  update_subdir_base(fs, git_dir, transformed_head.to_hex())
  print_line("done.")
}

///|
/// Find the initial commit of a subdir-clone (the "cloned from" commit)
fn find_initial_subdir_commit(
  fs : OsFs,
  git_dir : String,
) -> @git.ObjectId raise @git.GitError {
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Start from HEAD and walk back to find root commit
  let head_opt = @gitlib.rev_parse(fs, git_dir, "HEAD") catch {
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard head_opt is Some(head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  let mut current : @git.ObjectId = head
  let mut prev : @git.ObjectId = current
  while true {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      // Found root commit
      return current
    }
    prev = current
    current = info.parents[0]
  }
  prev
}

///|
/// Collect commits from start (exclusive) to end (inclusive)
fn collect_commits_since(
  fs : OsFs,
  git_dir : String,
  start : @git.ObjectId,
  end : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let result : Array[@git.ObjectId] = []
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  let mut current : @git.ObjectId = end
  let start_hex = start.to_hex()
  while true {
    let hex = current.to_hex()
    if hex == start_hex {
      break
    }
    result.push(current)
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get oldest first
  result.rev_in_place()
  result
}

///|
/// Transform a subdir-clone commit to fit the original repository structure
fn transform_subdir_commit(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  local_commit : @git.ObjectId,
  upstream_parent : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId raise @git.GitError {
  // Get local commit info
  let local_obj = db.get(fs, local_commit)
  guard local_obj is Some(lo) else {
    raise @git.GitError::InvalidObject("Cannot find local commit")
  }
  let local_info = @git.parse_commit(lo.data) catch { err => raise err }
  let (author, message) = parse_commit_author_message(lo.data)
  // Get upstream parent's tree
  let upstream_obj = db.get(fs, upstream_parent)
  guard upstream_obj is Some(uo) else {
    raise @git.GitError::InvalidObject("Cannot find upstream commit")
  }
  let upstream_info = @git.parse_commit(uo.data) catch { err => raise err }
  // The local commit's tree IS the subdirectory content
  let new_subdir_tree = local_info.tree
  // Replace the subdirectory in the upstream tree
  let new_root_tree = replace_tree_at_path(
    fs,
    db,
    git_dir,
    upstream_info.tree,
    subdir_path,
    new_subdir_tree,
  ) catch {
    err => raise err
  }
  // Create new commit with the transformed tree
  let timestamp = get_current_timestamp()
  let new_commit = @subdir.create_commit_in_repo(
    fs, git_dir, new_root_tree, upstream_parent, message, author, timestamp,
  ) catch {
    _ => raise @git.GitError::InvalidObject("Cannot create commit")
  }
  new_commit
}

///|
/// Replace a subtree at a given path within a root tree
fn replace_tree_at_path(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  root_tree : @git.ObjectId,
  path : String,
  new_subtree : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  let path_parts : Array[String] = path
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  if path_parts.length() == 0 {
    return new_subtree
  }
  replace_tree_recursive_push(
    fs, db, git_dir, root_tree, path_parts, 0, new_subtree,
  )
}

///|
fn replace_tree_recursive_push(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  current_tree : @git.ObjectId,
  path_parts : Array[String],
  depth : Int,
  new_leaf : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  // Read current tree
  let tree_obj = db.get(fs, current_tree)
  guard tree_obj is Some(to) else {
    raise @git.GitError::InvalidObject("Cannot find tree")
  }
  let entries = @git.parse_tree(to.data) catch { err => raise err }
  // Build new entries
  let new_entries : Array[@git.TreeEntry] = []
  let target_name = path_parts[depth]
  let is_last = depth == path_parts.length() - 1
  for entry in entries {
    if entry.name == target_name {
      if is_last {
        // Replace with new subtree
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_leaf))
      } else {
        // Recurse
        let new_child = replace_tree_recursive_push(
          fs,
          db,
          git_dir,
          entry.id,
          path_parts,
          depth + 1,
          new_leaf,
        ) catch {
          err => raise err
        }
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_child))
      }
    } else {
      new_entries.push(entry)
    }
  }
  // Create new tree and write it
  let (tree_id, tree_data) = @git.create_tree(new_entries)
  write_object_to_repo(fs, git_dir, tree_id, tree_data) catch {
    _ => raise @git.GitError::InvalidObject("Cannot write tree")
  }
  tree_id
}

///|
/// Write an object (already compressed) to the repository
fn write_object_to_repo(
  fs : OsFs,
  git_dir : String,
  id : @git.ObjectId,
  compressed_data : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let dir_name = String::unsafe_substring(hex, start=0, end=2)
  let file_name = String::unsafe_substring(hex, start=2, end=40)
  let dir_path = git_dir + "/objects/" + dir_name
  let file_path = dir_path + "/" + file_name
  // Create directory if needed
  fs.mkdir_p(dir_path) catch {
    _ => ()
  }
  // Write already-compressed data
  fs.write_file(file_path, compressed_data) catch {
    _ => raise @git.GitError::IoError("Cannot write object")
  }
}
