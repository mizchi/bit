///| Git-shim main entry point and command dispatcher

///|
async fn show_help() -> Unit {
  let help =
    #|usage: bit [-v | --version] [-h | --help] [-C <path>]
    #|           <command> [<args>]
    #|
    #|bit is a Git implementation in MoonBit.
    #|Unsupported commands will fail with an error.
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
    #|   tree       List tree entries from a remote repository (porcelain)
    #|   cat        Show file contents from a remote repository
    #|
    #|grow, mark and tweak your common history
    #|   branch        List, create, or delete branches
    #|   show-branches Show branches and their commits
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
    #|experimental
    #|   collab       Manage pull requests and issues
    #|   subdir-clone  Clone subdirectory as independent repository
    #|   hq            ghq-compatible repository management (~/bhq)
    #|
    #|low-level / plumbing
    #|   bundle          Create, verify, list-heads, and unbundle Git bundles
    #|   cat-file        Provide content or type info for repository objects
    #|   config          Get and set repository options
    #|   hash-object     Compute object ID and optionally creates a blob
    #|   index-pack      Build pack index file for an existing packed archive
    #|   ls-files        Show information about files in the index
    #|   ls-tree         List the contents of a tree object
    #|   pack-objects    Create a packed archive of objects
    #|   receive-pack    Receive what is pushed into the repository
    #|   rev-list        List commit objects in reverse chronological order
    #|   rev-parse       Parse revision specifications
    #|   show-ref        List references in a local repository
    #|   symbolic-ref    Read, modify and delete symbolic refs
    #|   unpack-objects  Unpack objects from a packed archive
    #|   update-ref      Update the object name stored in a ref safely
    #|   upload-pack     Send objects packed back to git-fetch-pack
    #|   verify-pack     Validate packed Git archive files
    #|   write-tree      Create a tree object from the current index
    #|
    #|See 'git help <command>' for more information on a specific command.
  print_line(help)
}

///|
async fn show_simple_command_help(usage : String, summary? : String) -> Unit {
  let mut help = "usage: " + usage
  if summary is Some(text) {
    help = help + "\n\n" + text
  }
  print_line(help)
}

///|
async fn show_command_help(cmd : String) -> Bool {
  match cmd {
    "hq" => {
      print_hq_usage()
      true
    }
    "subdir-clone" => {
      print_subdir_clone_usage()
      true
    }
    "worktree" => {
      show_worktree_help()
      true
    }
    "collab" => {
      print_collab_usage()
      true
    }
    "clone" => {
      show_simple_command_help(
        "git clone [<options>] [--] <repo> [<dir>]",
        summary="Clone a repository into a new directory.",
      )
      true
    }
    "init" => {
      show_simple_command_help(
        "git init [<options>] [<directory>]",
        summary="Create an empty Git repository or reinitialize an existing one.",
      )
      true
    }
    "status" => {
      show_simple_command_help(
        "git status [<options>] [--] [<pathspec>...]",
        summary="Show the working tree status.",
      )
      true
    }
    "add" => {
      show_simple_command_help(
        "git add [<options>] [--] <pathspec>...",
        summary="Add file contents to the index.",
      )
      true
    }
    "commit" => {
      show_simple_command_help(
        "git commit [<options>]",
        summary="Record changes to the repository.",
      )
      true
    }
    "log" => {
      show_simple_command_help(
        "git log [<options>] [<revision-range>] [--] [<pathspec>...]",
        summary="Show commit logs.",
      )
      true
    }
    "show" => {
      show_simple_command_help(
        "git show [<options>] [<object>...]",
        summary="Show various types of objects.",
      )
      true
    }
    "tree" => {
      show_simple_command_help(
        "bit tree [<options>] <repo>[:<path>] [<pathspec>...]",
        summary="List tree entries from a remote repository (porcelain).",
      )
      true
    }
    "cat" => {
      show_simple_command_help(
        "bit cat <repo>:<path>",
        summary="Show file contents from a remote repository.",
      )
      true
    }
    "diff" => {
      show_simple_command_help(
        "git diff [<options>] [--] [<pathspec>...]",
        summary="Show changes between commits, commit and working tree, etc.",
      )
      true
    }
    "branch" => {
      show_simple_command_help(
        "git branch [<options>] [<branchname>]",
        summary="List, create, or delete branches.",
      )
      true
    }
    "show-branches" | "show-branch" => {
      show_simple_command_help(
        "git show-branch [<options>] [<branch>...]",
        summary="Show branches and their commits.",
      )
      true
    }
    "checkout" => {
      show_simple_command_help(
        "git checkout [<options>] <branch>",
        summary="Switch branches or restore working tree files.",
      )
      true
    }
    "switch" => {
      show_simple_command_help(
        "git switch [<options>] <branch>",
        summary="Switch branches.",
      )
      true
    }
    "reset" => {
      show_simple_command_help(
        "git reset [<options>] [<commit>]",
        summary="Reset current HEAD to the specified state.",
      )
      true
    }
    "rebase" => {
      show_simple_command_help(
        "git rebase [<options>] <upstream> [<branch>]",
        summary="Reapply commits on top of another base tip.",
      )
      true
    }
    "merge" => {
      show_simple_command_help(
        "git merge [<options>] <commit>...",
        summary="Join two or more development histories together.",
      )
      true
    }
    "stash" => {
      show_simple_command_help(
        "git stash [<options>] [<message>]",
        summary="Stash the changes in a dirty working directory.",
      )
      true
    }
    "cherry-pick" => {
      show_simple_command_help(
        "git cherry-pick [<options>] <commit>...",
        summary="Apply the changes from existing commits.",
      )
      true
    }
    "tag" => {
      show_simple_command_help(
        "git tag [<options>] [<name> [<commit>]]",
        summary="Create, list, delete tag objects.",
      )
      true
    }
    "fetch" => {
      show_simple_command_help(
        "git fetch [<options>] [<repository> [<refspec>...]]",
        summary="Download objects and refs from another repository.",
      )
      true
    }
    "pull" => {
      show_simple_command_help(
        "git pull [<options>] [<repository> [<refspec>...]]",
        summary="Fetch from and integrate with another repository.",
      )
      true
    }
    "push" => {
      show_simple_command_help(
        "git push [<options>] [<repository> [<refspec>...]]",
        summary="Update remote refs along with associated objects.",
      )
      true
    }
    "remote" => {
      show_simple_command_help(
        "git remote [<command>] [<args>]",
        summary="Manage set of tracked repositories.",
      )
      true
    }
    "mv" => {
      show_simple_command_help(
        "git mv <source> <destination>",
        summary="Move or rename a file, a directory, or a symlink.",
      )
      true
    }
    "rm" => {
      show_simple_command_help(
        "git rm [<options>] <file>...",
        summary="Remove files from the working tree and from the index.",
      )
      true
    }
    "bundle" => {
      show_simple_command_help(
        "git bundle <command> [<args>]",
        summary="Create, verify, list-heads, and unbundle Git bundles.",
      )
      true
    }
    "clean" => {
      show_simple_command_help(
        "git clean [<options>] [--] <pathspec>...",
        summary="Remove untracked files from the working tree.",
      )
      true
    }
    "cat-file" => {
      show_simple_command_help(
        "git cat-file <type> <object>",
        summary="Provide content or type info for repository objects.",
      )
      true
    }
    "config" => {
      show_simple_command_help(
        "git config [<options>] <name> [<value>]",
        summary="Get and set repository options.",
      )
      true
    }
    "describe" => {
      show_simple_command_help(
        "git describe [<options>] <commit-ish>",
        summary="Give an object a human readable name based on a ref.",
      )
      true
    }
    "format-patch" => {
      show_simple_command_help(
        "git format-patch [<options>] <since>..<until>",
        summary="Prepare patches for e-mail submission.",
      )
      true
    }
    "fsck" => {
      show_simple_command_help(
        "git fsck [<options>]",
        summary="Verify the connectivity and validity of objects.",
      )
      true
    }
    "gc" => {
      show_simple_command_help(
        "git gc [<options>]",
        summary="Cleanup unnecessary files and optimize the local repository.",
      )
      true
    }
    "grep" => {
      show_simple_command_help(
        "git grep [<options>] <pattern> [--] <pathspec>...",
        summary="Print lines matching a pattern.",
      )
      true
    }
    "hash-object" => {
      show_simple_command_help(
        "git hash-object [<options>] <file>...",
        summary="Compute object ID and optionally creates a blob.",
      )
      true
    }
    "index-pack" => {
      show_simple_command_help(
        "git index-pack [<options>] <pack> [<idx>]",
        summary="Build pack index file for an existing packed archive.",
      )
      true
    }
    "ls-files" => {
      show_simple_command_help(
        "git ls-files [<options>] [<file>...]",
        summary="Show information about files in the index.",
      )
      true
    }
    "ls-tree" => {
      show_simple_command_help(
        "git ls-tree [<options>] <tree-ish> [<path>...]",
        summary="List the contents of a tree object.",
      )
      true
    }
    "pack-objects" => {
      show_simple_command_help(
        "git pack-objects [<options>] <base-name>",
        summary="Create a packed archive of objects.",
      )
      true
    }
    "pack-refs" => {
      show_simple_command_help(
        "git pack-refs [<options>]",
        summary="Pack heads and tags for efficient repository access.",
      )
      true
    }
    "prune" => {
      show_simple_command_help(
        "git prune [<options>]",
        summary="Prune all unreachable objects from the object database.",
      )
      true
    }
    "reflog" => {
      show_simple_command_help(
        "git reflog [<options>] [<ref>]",
        summary="Manage reflog information.",
      )
      true
    }
    "repack" => {
      show_simple_command_help(
        "git repack [<options>]",
        summary="Pack unpacked objects in a repository.",
      )
      true
    }
    "revert" => {
      show_simple_command_help(
        "git revert [<options>] <commit>...",
        summary="Revert some existing commits.",
      )
      true
    }
    "notes" => {
      show_simple_command_help(
        "git notes [<command>] [<args>]",
        summary="Add or inspect object notes.",
      )
      true
    }
    "bisect" => {
      show_simple_command_help(
        "git bisect [<options>] <subcommand> [<args>]",
        summary="Find by binary search the change that introduced a bug.",
      )
      true
    }
    "blame" => {
      show_simple_command_help(
        "git blame [<options>] <file>",
        summary="Show what revision and author last modified each line.",
      )
      true
    }
    "receive-pack" | "git-receive-pack" => {
      show_simple_command_help(
        "git receive-pack <git-dir>",
        summary="Receive what is pushed into the repository.",
      )
      true
    }
    "rev-list" => {
      show_simple_command_help(
        "git rev-list [<options>] <commit>...",
        summary="List commit objects in reverse chronological order.",
      )
      true
    }
    "rev-parse" => {
      show_simple_command_help(
        "git rev-parse [<options>] <arg>...",
        summary="Parse revision specifications.",
      )
      true
    }
    "request-pull" => {
      show_simple_command_help(
        "git request-pull <start> <url> [<end>]",
        summary="Generate a summary of pending changes.",
      )
      true
    }
    "send-pack" => {
      show_simple_command_help(
        "git send-pack [<options>] <repository> [<refspec>...]",
        summary="Push objects over git protocol to another repository.",
      )
      true
    }
    "show-ref" => {
      show_simple_command_help(
        "git show-ref [<options>] [<pattern>...]",
        summary="List references in a local repository.",
      )
      true
    }
    "shortlog" => {
      show_simple_command_help(
        "git shortlog [<options>] [<revision-range>]",
        summary="Summarize git log output.",
      )
      true
    }
    "symbolic-ref" => {
      show_simple_command_help(
        "git symbolic-ref [<options>] <name> [<ref>]",
        summary="Read, modify and delete symbolic refs.",
      )
      true
    }
    "submodule" => {
      show_simple_command_help(
        "git submodule [<command>] [<args>]",
        summary="Initialize, update or inspect submodules.",
      )
      true
    }
    "sparse-checkout" => {
      show_simple_command_help(
        "git sparse-checkout [<command>] [<args>]",
        summary="Initialize and modify the sparse-checkout config.",
      )
      true
    }
    "read-tree" => {
      show_simple_command_help(
        "git read-tree [<options>] <tree-ish>",
        summary="Read tree information into the index.",
      )
      true
    }
    "update-index" => {
      show_simple_command_help(
        "git update-index [<options>] [--] <file>...",
        summary="Register file contents in the index.",
      )
      true
    }
    "mktree" => {
      show_simple_command_help(
        "git mktree [<options>]",
        summary="Build a tree-object from ls-tree formatted text.",
      )
      true
    }
    "maintenance" => {
      show_simple_command_help(
        "git maintenance [<command>] [<options>]",
        summary="Run tasks to optimize Git repository data.",
      )
      true
    }
    "unpack-objects" => {
      show_simple_command_help(
        "git unpack-objects [<options>]",
        summary="Unpack objects from a packed archive.",
      )
      true
    }
    "update-ref" => {
      show_simple_command_help(
        "git update-ref [<options>] <refname> <newvalue> [<oldvalue>]",
        summary="Update the object name stored in a ref safely.",
      )
      true
    }
    "upload-pack" | "git-upload-pack" => {
      show_simple_command_help(
        "git upload-pack [<options>] <git-dir>",
        summary="Send objects packed back to git-fetch-pack.",
      )
      true
    }
    "verify-pack" => {
      show_simple_command_help(
        "git verify-pack [<options>] <pack>...",
        summary="Validate packed Git archive files.",
      )
      true
    }
    "write-tree" => {
      show_simple_command_help(
        "git write-tree",
        summary="Create a tree object from the current index.",
      )
      true
    }
    "range-diff" => {
      show_simple_command_help(
        "git range-diff [<options>] <range1> <range2>",
        summary="Compare two commit ranges.",
      )
      true
    }
    "multi-pack-index" => {
      show_simple_command_help(
        "git multi-pack-index [<options>] <subcommand>",
        summary="Write and verify multi-pack-indexes.",
      )
      true
    }
    "cherry" => {
      show_simple_command_help(
        "git cherry [<options>] <upstream> [<head>]",
        summary="Find commits yet to be applied to upstream.",
      )
      true
    }
    "am" => {
      show_simple_command_help(
        "git am [<options>] <mbox>",
        summary="Apply a series of patches from a mailbox.",
      )
      true
    }
    "apply" => {
      show_simple_command_help(
        "git apply [<options>] <patch>...",
        summary="Apply a patch to files and/or to the index.",
      )
      true
    }
    _ => false
  }
}

///|
async fn handle_help(args : Array[String]) -> Unit {
  if args.length() == 0 {
    show_help()
    return
  }
  let cmd = args[0]
  if not(show_command_help(cmd)) {
    eprint_line("warning: help for '\{cmd}' is not implemented")
  }
}

///|
async fn main_async() -> Unit {
  let args = @sys.get_cli_args()
  if args.length() < 2 {
    show_help()
    return ()
  }
  @gitlibnative.init_env_provider()
  @gitlibnative.init_worktree_probe()
  // Handle --version and --help early (can appear anywhere before command)
  for i in 1..<args.length() {
    match args[i] {
      "--version" | "version" => {
        print_line("git version 2.47.0 (bit)")
        return ()
      }
      "-h" | "--help" => {
        show_help()
        return ()
      }
      _ if not(args[i].has_prefix("-")) => break // Stop at first non-option
      _ => continue
    }
  }
  let opts = parse_global_options(args)
  guard opts.subcmd is Some(cmd) else {
    eprint_line("bit: missing subcommand")
    @sys.exit(2)
  }
  if opts.unsupported_global {
    eprint_line("bit: unsupported global option")
    @sys.exit(1)
  }
  // Store config overrides in environment variable for handlers to access
  if opts.config_overrides.length() > 0 {
    let encoded : Array[String] = []
    for pair in opts.config_overrides {
      // Encode as key=value, separated by newlines
      encoded.push(pair.0 + "=" + pair.1)
    }
    @sys.set_env_var("GIT_CONFIG_OVERRIDES", encoded.join("\n"))
  }
  // Set working directory if -C was used
  match opts.cwd {
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
  let fs = OsFs::new()
  let aliases = load_global_aliases(fs)
  apply_alias_overrides(aliases, opts.config_overrides)
  let (alias_cmd, alias_rest) = match resolve_alias(aliases, cmd, opts.rest) {
    Resolved(resolved_cmd, resolved_rest) => (resolved_cmd, resolved_rest)
    Shell(cmdline) => {
      eprint_line("warning: shell alias is not supported: \{cmdline}")
      @sys.exit(1)
      (cmd, opts.rest)
    }
  }
  // If --bare was passed globally, prepend it to rest for init command
  let effective_rest = if opts.bare && alias_cmd == "init" {
    prepend_arg("--bare", alias_rest)
  } else {
    alias_rest
  }
  dispatch_command(alias_cmd, effective_rest)
}

///|
struct GlobalOptions {
  subcmd : String?
  rest : Array[String]
  cwd : String?
  unsupported_global : Bool
  bare : Bool
  config_overrides : Array[(String, String)]
}

///|
fn parse_global_options(args : Array[String]) -> GlobalOptions {
  let mut i = 1
  let mut in_opts = true
  let mut cwd : String? = None
  let mut unsupported_global = false
  let mut bare = false
  let mut subcmd : String? = None
  let mut rest : Array[String] = []
  let config_overrides : Array[(String, String)] = []
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
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
      // Parse -c key=value
      let kv = args[i + 1]
      match kv.find("=") {
        Some(eq_idx) => {
          let key = String::unsafe_substring(kv, start=0, end=eq_idx)
          let value = String::unsafe_substring(
            kv,
            start=eq_idx + 1,
            end=kv.length(),
          )
          config_overrides.push((key, value))
        }
        None =>
          // Key without value (treated as empty string in git)
          config_overrides.push((kv, ""))
      }
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
  { subcmd, rest, cwd, unsupported_global, bare, config_overrides }
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
async fn dispatch_command(cmd : String, rest : Array[String]) -> Unit {
  for arg in rest {
    if arg == "-h" || arg == "--help" {
      if not(show_command_help(cmd)) {
        eprint_line("warning: help for '\{cmd}' is not implemented")
      }
      return ()
    }
  }
  match cmd {
    "help" => handle_help(rest)
    // Pack operations
    "receive-pack" | "git-receive-pack" =>
      handle_receive_pack(rest) catch {
        err => exit_with_error("receive-pack", err)
      }
    "upload-pack" | "git-upload-pack" => handle_upload_pack(rest)
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
    "tree" => handle_tree(rest) catch { err => exit_with_error("tree", err) }
    "cat" => handle_cat(rest) catch { err => exit_with_error("cat", err) }
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
    "show-branches" | "show-branch" =>
      handle_show_branches(rest) catch {
        err => exit_with_error("show-branches", err)
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
    "subdir-clone" =>
      handle_subdir_clone(rest) catch {
        err => exit_with_error("subdir", err)
      }
    "collab" =>
      handle_collab(rest) catch {
        err => exit_with_error("collab", err)
      }
    "hq" => handle_hq(rest) catch { err => exit_with_error("hq", err) }
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
    "describe" =>
      handle_describe(rest) catch {
        err => exit_with_error("describe", err)
      }
    "blame" => handle_blame(rest) catch { err => exit_with_error("blame", err) }
    "format-patch" =>
      handle_format_patch(rest) catch {
        err => exit_with_error("format-patch", err)
      }
    "shortlog" =>
      handle_shortlog(rest) catch {
        err => exit_with_error("shortlog", err)
      }
    "am" => handle_am(rest) catch { err => exit_with_error("am", err) }
    "apply" => handle_apply(rest) catch { err => exit_with_error("apply", err) }
    "fsck" => handle_fsck(rest) catch { err => exit_with_error("fsck", err) }
    "prune" => handle_prune(rest) catch { err => exit_with_error("prune", err) }
    "pack-refs" =>
      handle_pack_refs(rest) catch {
        err => exit_with_error("pack-refs", err)
      }
    "repack" =>
      handle_repack(rest) catch {
        err => exit_with_error("repack", err)
      }
    "maintenance" =>
      handle_maintenance(rest) catch {
        err => exit_with_error("maintenance", err)
      }
    "rev-list" =>
      handle_rev_list(rest) catch {
        err => exit_with_error("rev-list", err)
      }
    "verify-pack" =>
      handle_verify_pack(rest) catch {
        err => exit_with_error("verify-pack", err)
      }
    "unpack-objects" =>
      handle_unpack_objects(rest) catch {
        err => exit_with_error("unpack-objects", err)
      }
    "bundle" =>
      handle_bundle(rest) catch {
        err => exit_with_error("bundle", err)
      }
    "read-tree" =>
      handle_read_tree(rest) catch {
        err => exit_with_error("read-tree", err)
      }
    "update-index" =>
      handle_update_index(rest) catch {
        err => exit_with_error("update-index", err)
      }
    "mktree" =>
      handle_mktree(rest) catch {
        err => exit_with_error("mktree", err)
      }
    "request-pull" =>
      handle_request_pull(rest) catch {
        err => exit_with_error("request-pull", err)
      }
    "send-pack" =>
      handle_send_pack(rest) catch {
        err => exit_with_error("send-pack", err)
      }
    "range-diff" =>
      handle_range_diff(rest) catch {
        err => exit_with_error("range-diff", err)
      }
    "multi-pack-index" =>
      handle_multi_pack_index(rest) catch {
        err => exit_with_error("multi-pack-index", err)
      }
    "cherry" =>
      handle_cherry(rest) catch {
        err => exit_with_error("cherry", err)
      }
    "version" | "--version" => print_line("git version 2.47.0 (bit)")
    // Error for unknown commands
    _ => {
      eprint_line("bit: '\{cmd}' is not a bit command")
      @sys.exit(1)
    }
  }
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
