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
fn resolve_commit_editor() -> String? {
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
fn commit_edit_buffer_template(initial_message : String?) -> String {
  let sb = StringBuilder::new()
  match initial_message {
    Some(msg) => {
      sb.write_string(msg)
      if not(msg.has_suffix("\n")) {
        sb.write_string("\n")
      }
      sb.write_string("\n")
    }
    None => ()
  }
  sb.write_string("# Please enter the commit message for your changes.\n")
  sb.write_string("# Lines starting with '#' will be ignored.\n")
  sb.to_string()
}

///|
fn normalize_commit_edit_buffer(content : String) -> String? {
  let lines = content.split("\n")
  let kept : Array[String] = []
  for line_view in lines {
    let line = line_view.to_string()
    if line.has_prefix("#") {
      continue
    }
    kept.push(line)
  }
  let mut start = 0
  while start < kept.length() && kept[start].trim().to_string().length() == 0 {
    start += 1
  }
  if start >= kept.length() {
    return None
  }
  let mut end = kept.length() - 1
  while end >= start && kept[end].trim().to_string().length() == 0 {
    end -= 1
  }
  let sb = StringBuilder::new()
  for i = start; i <= end; i = i + 1 {
    if i > start {
      sb.write_string("\n")
    }
    sb.write_string(kept[i])
  }
  let msg = sb.to_string()
  if msg.trim().to_string().length() == 0 {
    None
  } else {
    Some(msg)
  }
}

///|
async fn default_commit_message_editor(path : String) -> Bool raise Error {
  guard resolve_commit_editor() is Some(editor_cmd) else { return false }
  let code = run_editor_on_path(editor_cmd, path)
  if code != 0 {
    raise @git.GitError::InvalidObject(
      "commit message editor failed with exit code \{code}",
    )
  }
  true
}

///|
async fn read_commit_message_from_editor(
  fs : OsFs,
  root : String,
  initial_message? : String? = None,
  editor? : (async (String) -> Bool raise Error)? = None,
) -> String? raise Error {
  let path = root + "/.git/COMMIT_EDITMSG"
  fs.write_string(path, commit_edit_buffer_template(initial_message))
  let edited = match editor {
    Some(edit) => edit(path)
    None => default_commit_message_editor(path)
  }
  if not(edited) {
    return None
  }
  guard fs.is_file(path) else { return None }
  let content = decode_bytes(fs.read_file(path))
  normalize_commit_edit_buffer(content)
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
