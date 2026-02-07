///|
fn has_interactive_add_flag(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "-p" || arg == "--patch" {
      return true
    }
  }
  false
}

///|
fn resolve_real_git_binary() -> String {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) => path
    None =>
      match @sys.get_env_var("GIT_SHIM_REAL_GIT") {
        Some(path) => path
        None => "git"
      }
  }
}

///|
async fn default_add_interactive_runner(args : Array[String]) -> Int {
  let real_args : Array[String] = ["add"]
  for arg in args {
    real_args.push(arg)
  }
  @process.run(resolve_real_git_binary(), real_args, inherit_env=true)
}

///|
async fn run_add_interactive(
  args : Array[String],
  runner? : (async (Array[String]) -> Int noraise)? = None,
) -> Unit raise Error {
  let code = match runner {
    Some(run) => run(args)
    None => default_add_interactive_runner(args)
  }
  if code != 0 {
    raise @git.GitError::InvalidObject(
      "git add --patch failed with exit code \{code}",
    )
  }
}

///|
fn resolve_sequence_editor() -> String? {
  match @sys.get_env_var("GIT_SEQUENCE_EDITOR") {
    Some(cmd) if cmd.trim().to_string().length() > 0 => Some(cmd)
    _ =>
      match @sys.get_env_var("GIT_EDITOR") {
        Some(cmd) if cmd.trim().to_string().length() > 0 => Some(cmd)
        _ =>
          match @sys.get_env_var("VISUAL") {
            Some(cmd) if cmd.trim().to_string().length() > 0 => Some(cmd)
            _ =>
              match @sys.get_env_var("EDITOR") {
                Some(cmd) if cmd.trim().to_string().length() > 0 => Some(cmd)
                _ => None
              }
          }
      }
  }
}

///|
async fn run_editor_on_path(editor_cmd : String, path : String) -> Int {
  let parts = split_alias_command(editor_cmd)
  if parts.length() == 0 {
    return 1
  }
  let bin = parts[0]
  let args : Array[String] = []
  for i = 1; i < parts.length(); i = i + 1 {
    args.push(parts[i])
  }
  args.push(path)
  @process.run(bin, args, inherit_env=true)
}

///|
async fn default_rebase_todo_editor(todo_path : String) -> Bool raise Error {
  guard resolve_sequence_editor() is Some(editor_cmd) else { return false }
  let code = run_editor_on_path(editor_cmd, todo_path)
  if code != 0 {
    raise @git.GitError::InvalidObject(
      "rebase todo editor failed with exit code \{code}",
    )
  }
  true
}

///|
async fn edit_rebase_todo(
  todo_path : String,
  editor? : (async (String) -> Bool noraise)? = None,
) -> Bool raise Error {
  match editor {
    Some(edit) => edit(todo_path)
    None => default_rebase_todo_editor(todo_path)
  }
}
