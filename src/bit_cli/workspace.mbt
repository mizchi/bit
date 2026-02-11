///|
/// workspace command entry points for bit_cli

///|
async fn print_workspace_usage() -> Unit {
  @workspace.print_workspace_usage()
}

///|
async fn print_repo_usage() -> Unit {
  @workspace.print_repo_usage()
}

///|
fn workspace_translate_implicit_command(
  cwd : String?,
  cmd : String,
  rest : Array[String],
) -> (String, Array[String]) {
  @workspace.workspace_translate_implicit_command(cwd, cmd, rest)
}

///|
async fn handle_repo(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_repo_usage()
    return
  }
  let cmd = args[0]
  if cmd == "-h" || cmd == "--help" || cmd == "help" {
    print_repo_usage()
    return
  }
  let rest = collect_args(args, 1)
  dispatch_command(cmd, rest)
}

///|
async fn run_workspace_repo_command_inner(
  cmd : String,
  rest : Array[String],
) -> Unit raise Error {
  match cmd {
    "status" => handle_status(rest)
    "commit" => handle_commit(rest)
    "push" => handle_push(rest)
    "init" => handle_init(rest)
    _ =>
      raise @git.GitError::InvalidObject("unsupported repo command '\{cmd}'")
  }
}

///|
async fn run_workspace_repo_command(
  cwd : String,
  cmd : String,
  rest : Array[String],
) -> (Int, String) {
  let snapshot = enter_run_git_env(Some(cwd), None)
  let mut code = 0
  let mut message = ""
  run_workspace_repo_command_inner(cmd, rest) catch {
    err if @async.is_cancellation_error(err) => {
      restore_run_git_env(snapshot)
      raise err
    }
    err => {
      code = 1
      message = err.to_string()
    }
  }
  restore_run_git_env(snapshot)
  (code, message)
}

///|
async fn handle_workspace(args : Array[String]) -> Unit raise Error {
  @workspace.handle_workspace(args, run_workspace_repo_command)
}
