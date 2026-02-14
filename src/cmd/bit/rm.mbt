///|
async fn handle_rm(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let opts = parse_rm_options(args)
  if opts.paths.length() == 0 {
    raise @git.GitError::InvalidObject("No pathspec given")
  }
  let git_dir = root + "/.git"
  let actual_git_dir = if fs.is_file(git_dir) {
    @gitlib.resolve_gitdir(fs, git_dir)
  } else {
    git_dir
  }
  let entries = @gitlib.read_index_entries(fs, actual_git_dir)
  for path in opts.paths {
    if not(opts.ignore_unmatch) &&
      not(rm_pathspec_matches_any(path, entries, opts.recursive)) {
      raise @git.GitError::InvalidObject(
        "pathspec '\{path}' did not match any files",
      )
    }
  }
  let removed_paths = rm_collect_target_paths(
    opts.paths,
    entries,
    opts.recursive,
  )
  if opts.cached && not(opts.force) {
    let st = @gitlib.status(fs, root)
    let staged_but_not_head : Map[String, Bool] = {}
    for path in st.staged_added {
      staged_but_not_head[path] = true
    }
    for path in st.staged_modified {
      staged_but_not_head[path] = true
    }
    let unstaged_modified : Map[String, Bool] = {}
    for path in st.unstaged_modified {
      unstaged_modified[path] = true
    }
    for path in removed_paths {
      if staged_but_not_head.contains(path) && unstaged_modified.contains(path) {
        raise @git.GitError::InvalidObject(
          "the following file has staged content different from both the file and the HEAD:\n    \{path}",
        )
      }
    }
  }
  @gitlib.rm_paths(
    fs,
    fs,
    root,
    opts.paths,
    cached=opts.cached,
    force=opts.force,
    recursive=opts.recursive,
  )
  if not(opts.quiet) {
    for path in removed_paths {
      print_line("rm " + rm_quote_path(path))
    }
  }
}

///|
struct RmOptions {
  cached : Bool
  force : Bool
  recursive : Bool
  quiet : Bool
  ignore_unmatch : Bool
  paths : Array[String]
}

///|
fn parse_rm_options(args : Array[String]) -> RmOptions {
  let mut cached = false
  let mut force = false
  let mut recursive = false
  let mut quiet = false
  let mut ignore_unmatch = false
  let mut parse_options = true
  let paths : Array[String] = []
  for arg in args {
    if parse_options && arg == "--" {
      parse_options = false
      continue
    }
    if parse_options {
      match arg {
        "--cached" => cached = true
        "-f" | "--force" => force = true
        "-r" => recursive = true
        "-q" | "--quiet" => quiet = true
        "--ignore-unmatch" => ignore_unmatch = true
        _ if arg.has_prefix("-") => ()
        _ => paths.push(arg)
      }
    } else {
      paths.push(arg)
    }
  }
  { cached, force, recursive, quiet, ignore_unmatch, paths }
}

///|
fn rm_normalize_rel_path(path : String) -> String {
  if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
}

///|
fn rm_pathspec_matches_any(
  raw_path : String,
  entries : Array[@gitlib.IndexEntry],
  recursive : Bool,
) -> Bool {
  let path = rm_normalize_rel_path(raw_path)
  for entry in entries {
    if entry.path == path {
      return true
    }
    if recursive && entry.path.has_prefix(path + "/") {
      return true
    }
  }
  false
}

///|
fn rm_collect_target_paths(
  raw_paths : Array[String],
  entries : Array[@gitlib.IndexEntry],
  recursive : Bool,
) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = {}
  for raw_path in raw_paths {
    let path = rm_normalize_rel_path(raw_path)
    for entry in entries {
      if entry.path == path || (recursive && entry.path.has_prefix(path + "/")) {
        if not(seen.contains(entry.path)) {
          seen[entry.path] = true
          out.push(entry.path)
        }
      }
    }
  }
  out
}

///|
fn rm_quote_path(path : String) -> String {
  let b = StringBuilder::new()
  b.write_char('\'')
  for c in path {
    if c == '\'' {
      b.write_string("'\\''")
    } else if c == '\n' {
      b.write_string("\\n")
    } else if c == '\r' {
      b.write_string("\\r")
    } else if c == '\t' {
      b.write_string("\\t")
    } else {
      b.write_char(c)
    }
  }
  b.write_char('\'')
  b.to_string()
}

///|
