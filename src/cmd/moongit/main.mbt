///| Git-shim main entry point and command dispatcher

///|
async fn show_help() -> Unit {
  let help =
    #|usage: moongit [-v | --version] [-h | --help] [-C <path>]
    #|               [--no-git-fallback] <command> [<args>]
    #|
    #|moongit is a Git implementation in MoonBit.
    #|Unsupported commands automatically fallback to system git.
    #|Use --no-git-fallback to disable fallback and fail on unsupported commands.
    #|
    #|start a working area
    #|   clone      Clone a repository into a new directory
    #|   init       Create an empty Git repository
    #|
    #|work on the current change
    #|   add        Add file contents to the index
    #|   mv         Move or rename a file, a directory, or a symlink
    #|   rm         Remove files from the working tree and from the index
    #|
    #|examine the history and state
    #|   diff       Show changes between commits, commit and working tree, etc
    #|   log        Show commit logs
    #|   show       Show various types of objects
    #|   status     Show the working tree status
    #|
    #|grow, mark and tweak your common history
    #|   branch      List, create, or delete branches
    #|   cherry-pick Apply the changes from some existing commits
    #|   commit      Record changes to the repository
    #|   checkout    Switch branches or restore working tree files
    #|   merge       Join two or more development histories together
    #|   rebase      Reapply commits on top of another base tip
    #|   reset       Reset current HEAD to the specified state
    #|   stash       Stash the changes in a dirty working directory
    #|   switch      Switch branches
    #|   tag         Create, list, delete tag objects
    #|
    #|collaborate
    #|   fetch       Download objects and refs from another repository
    #|   pull        Fetch from and integrate with another repository
    #|   push        Update remote refs along with associated objects
    #|   remote      Manage set of tracked repositories
    #|
    #|work with multiple working trees
    #|   worktree    Manage multiple working trees
    #|
    #|low-level / plumbing
    #|   cat-file        Provide content or type info for repository objects
    #|   config          Get and set repository options
    #|   hash-object     Compute object ID and optionally creates a blob
    #|   index-pack      Build pack index file for an existing packed archive
    #|   ls-files        Show information about files in the index
    #|   ls-tree         List the contents of a tree object
    #|   pack-objects    Create a packed archive of objects
    #|   receive-pack    Receive what is pushed into the repository
    #|   rev-parse       Parse revision specifications
    #|   show-ref        List references in a local repository
    #|   symbolic-ref    Read, modify and delete symbolic refs
    #|   update-ref      Update the object name stored in a ref safely
    #|   upload-pack     Send objects packed back to git-fetch-pack
    #|   write-tree      Create a tree object from the current index
    #|
    #|See 'git help <command>' for more information on a specific command.
  print_line(help)
}

///|
async fn main_async() -> Unit {
  let args = @sys.get_cli_args()
  if args.length() < 2 {
    show_help()
    return ()
  }
  // Handle --version and --help early (can appear anywhere before command)
  for i in 1..<args.length() {
    match args[i] {
      "--version" | "version" => {
        print_line("git version 2.47.0 (moongit)")
        return ()
      }
      "-h" | "--help" | "help" => {
        show_help()
        return ()
      }
      _ if not(args[i].has_prefix("-")) => break // Stop at first non-option
      _ => continue
    }
  }
  let full_args = collect_args(args, 1)
  let (subcmd, rest, cwd, unsupported_global, no_fallback, bare) = parse_global_options(
    args,
  )
  guard subcmd is Some(cmd) else {
    eprint_line("git-shim: missing subcommand")
    @sys.exit(2)
  }
  if unsupported_global {
    if no_fallback {
      eprint_line("moongit: unsupported global option (--no-git-fallback)")
      @sys.exit(1)
    }
    run_system_git(full_args)
  }
  // Set working directory if -C was used
  match cwd {
    Some(dir) => {
      @sys.set_env_var("GIT_SHIM_CWD", dir)
      if @sys.get_env_var("GIT_DIR") is None {
        @sys.set_env_var("GIT_DIR", dir + "/.git")
      }
      if @sys.get_env_var("GIT_WORK_TREE") is None {
        @sys.set_env_var("GIT_WORK_TREE", dir)
      }
    }
    None => ()
  }
  // If --bare was passed globally, prepend it to rest for init command
  let effective_rest = if bare && cmd == "init" {
    prepend_arg("--bare", rest)
  } else {
    rest
  }
  dispatch_command(cmd, effective_rest, full_args, no_fallback)
}

///|
fn parse_global_options(
  args : Array[String],
) -> (String?, Array[String], String?, Bool, Bool, Bool) {
  let mut i = 1
  let mut in_opts = true
  let mut cwd : String? = None
  let mut unsupported_global = false
  let mut no_fallback = false
  let mut bare = false
  let mut subcmd : String? = None
  let mut rest : Array[String] = []
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg == "--no-git-fallback" {
      no_fallback = true
      i += 1
      continue
    }
    if in_opts && arg == "--bare" {
      bare = true
      i += 1
      continue
    }
    if in_opts && arg == "-C" && i + 1 < args.length() {
      let raw = args[i + 1]
      cwd = Some(
        if raw.has_prefix("/") {
          raw
        } else {
          @sys.get_env_var("GIT_SHIM_PWD")
          .map(fn(base) { base + "/" + raw })
          .unwrap_or(raw)
        },
      )
      i += 2
      continue
    }
    if in_opts && arg == "-c" && i + 1 < args.length() {
      unsupported_global = true
      i += 2
      continue
    }
    if in_opts && is_unsupported_global_flag(arg) {
      unsupported_global = true
      if not(arg.contains("=")) && i + 1 < args.length() {
        i += 2
      } else {
        i += 1
      }
      continue
    }
    if in_opts && arg.has_prefix("-") {
      i += 1
      continue
    }
    subcmd = Some(arg)
    rest = collect_args(args, i + 1)
    break
  }
  (subcmd, rest, cwd, unsupported_global, no_fallback, bare)
}

///|
fn is_unsupported_global_flag(arg : String) -> Bool {
  arg == "--git-dir" ||
  arg == "--work-tree" ||
  arg == "--namespace" ||
  arg == "--super-prefix" ||
  arg == "--git-path" ||
  arg.has_prefix("--git-dir=") ||
  arg.has_prefix("--work-tree=") ||
  arg.has_prefix("--namespace=") ||
  arg.has_prefix("--super-prefix=") ||
  arg.has_prefix("--git-path=")
}

///|
async fn dispatch_command(
  cmd : String,
  rest : Array[String],
  full_args : Array[String],
  no_fallback : Bool,
) -> Unit {
  match cmd {
    // Pack operations
    "receive-pack" | "git-receive-pack" =>
      handle_receive_pack(rest) catch {
        err => exit_with_error("receive-pack", err)
      }
    "upload-pack" | "git-upload-pack" =>
      handle_upload_pack(rest) catch {
        err => exit_with_error("upload-pack", err)
      }
    "pack-objects" =>
      handle_pack_objects(rest) catch {
        err => exit_with_error("pack-objects", err)
      }
    "index-pack" =>
      handle_index_pack(rest) catch {
        err => exit_with_error("index-pack", err)
      }
    // Remote operations
    "remote" =>
      handle_remote(rest) catch {
        err => exit_with_error("remote", err)
      }
    "clone" => handle_clone(rest) catch { err => exit_with_error("clone", err) }
    "fetch" => handle_fetch(rest) catch { err => exit_with_error("fetch", err) }
    "pull" => handle_pull(rest) catch { err => exit_with_error("pull", err) }
    "push" => handle_push(rest) catch { err => exit_with_error("push", err) }
    // Core operations
    "init" => handle_init(rest) catch { err => exit_with_error("init", err) }
    "status" =>
      handle_status(rest) catch {
        err => exit_with_error("status", err)
      }
    "add" => handle_add(rest) catch { err => exit_with_error("add", err) }
    "commit" =>
      handle_commit(rest) catch {
        err => exit_with_error("commit", err)
      }
    "log" => handle_log(rest) catch { err => exit_with_error("log", err) }
    "show" => handle_show(rest) catch { err => exit_with_error("show", err) }
    // Branch operations
    "branch" =>
      handle_branch(rest) catch {
        err => exit_with_error("branch", err)
      }
    "checkout" =>
      handle_checkout(rest) catch {
        err => exit_with_error("checkout", err)
      }
    "switch" =>
      handle_switch(rest) catch {
        err => exit_with_error("switch", err)
      }
    "reset" => handle_reset(rest) catch { err => exit_with_error("reset", err) }
    "rebase" =>
      handle_rebase(rest) catch {
        err => exit_with_error("rebase", err)
      }
    "stash" => handle_stash(rest) catch { err => exit_with_error("stash", err) }
    "cherry-pick" =>
      handle_cherry_pick(rest) catch {
        err => exit_with_error("cherry-pick", err)
      }
    // Misc operations
    "diff" => handle_diff(rest) catch { err => exit_with_error("diff", err) }
    "merge" => handle_merge(rest) catch { err => exit_with_error("merge", err) }
    "tag" => handle_tag(rest) catch { err => exit_with_error("tag", err) }
    "rm" => handle_rm(rest) catch { err => exit_with_error("rm", err) }
    "mv" => handle_mv(rest) catch { err => exit_with_error("mv", err) }
    "config" =>
      handle_config(rest) catch {
        err => exit_with_error("config", err)
      }
    "sparse-checkout" =>
      handle_sparse_checkout(rest) catch {
        err => exit_with_error("sparse-checkout", err)
      }
    "rev-parse" =>
      handle_rev_parse(rest) catch {
        err => exit_with_error("rev-parse", err)
      }
    "cat-file" =>
      handle_cat_file(rest) catch {
        err => exit_with_error("cat-file", err)
      }
    "ls-files" =>
      handle_ls_files(rest) catch {
        err => exit_with_error("ls-files", err)
      }
    "hash-object" =>
      handle_hash_object(rest) catch {
        err => exit_with_error("hash-object", err)
      }
    "ls-tree" =>
      handle_ls_tree(rest) catch {
        err => exit_with_error("ls-tree", err)
      }
    "write-tree" =>
      handle_write_tree(rest) catch {
        err => exit_with_error("write-tree", err)
      }
    "show-ref" =>
      handle_show_ref(rest) catch {
        err => exit_with_error("show-ref", err)
      }
    "update-ref" =>
      handle_update_ref(rest) catch {
        err => exit_with_error("update-ref", err)
      }
    "symbolic-ref" =>
      handle_symbolic_ref(rest) catch {
        err => exit_with_error("symbolic-ref", err)
      }
    "reflog" =>
      handle_reflog(rest) catch {
        err => exit_with_error("reflog", err)
      }
    "worktree" =>
      handle_worktree(rest) catch {
        err => exit_with_error("worktree", err)
      }
    "gc" => handle_gc(rest) catch { err => exit_with_error("gc", err) }
    "clean" => handle_clean(rest) catch { err => exit_with_error("clean", err) }
    "grep" => handle_grep(rest) catch { err => exit_with_error("grep", err) }
    "submodule" =>
      handle_submodule(rest) catch {
        err => exit_with_error("submodule", err)
      }
    "revert" =>
      handle_revert(rest) catch {
        err => exit_with_error("revert", err)
      }
    "notes" => handle_notes(rest) catch { err => exit_with_error("notes", err) }
    "bisect" =>
      handle_bisect(rest) catch {
        err => exit_with_error("bisect", err)
      }
    "version" | "--version" => print_line("git version 2.47.0 (moongit)")
    // Fallback to system git for unknown commands
    _ =>
      if no_fallback {
        eprint_line("moongit: unsupported command '\{cmd}' (--no-git-fallback)")
        @sys.exit(1)
      } else {
        run_system_git(prepend_arg(cmd, rest))
      }
  }
  ignore(full_args)
}

///|
async fn exit_with_error(cmd : String, err : Error) -> Unit {
  eprint_line("\{cmd} failed: \{err}")
  @sys.exit(1)
}

///|
fn main {
  @async.run_async_main(main_async)
}
