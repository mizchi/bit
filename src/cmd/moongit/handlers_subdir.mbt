///|
/// Subdir command handlers - subdirectory as independent repository

///|
async fn handle_subdir(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_subdir_usage()
    return
  }
  let subcommand = args[0]
  let rest = array_view_to_array(args[1:])
  match subcommand {
    "init" => handle_subdir_init(rest) catch { e => raise e }
    "deinit" => handle_subdir_deinit(rest) catch { e => raise e }
    "list" => handle_subdir_list(rest) catch { e => raise e }
    "sync" => handle_subdir_sync(rest) catch { e => raise e }
    "shell" => handle_subdir_shell(rest) catch { e => raise e }
    "show" => handle_subdir_show(rest) catch { e => raise e }
    "log" => handle_subdir_log(rest) catch { e => raise e }
    "diff" => handle_subdir_diff(rest) catch { e => raise e }
    "commit" => handle_subdir_commit(rest) catch { e => raise e }
    "checkout" => handle_subdir_checkout(rest) catch { e => raise e }
    "push" => handle_subdir_push(rest) catch { e => raise e }
    "pull" => handle_subdir_pull(rest) catch { e => raise e }
    "extract" => handle_subdir_extract(rest) catch { e => raise e }
    "sparse-checkout" =>
      handle_subdir_sparse_checkout(rest) catch {
        e => raise e
      }
    _ => {
      print_line("Unknown subdir subcommand: " + subcommand)
      print_subdir_usage()
    }
  }
}

///|
/// ArrayView を Array に変換
fn array_view_to_array(view : ArrayView[String]) -> Array[String] {
  let arr : Array[String] = []
  for item in view {
    arr.push(item)
  }
  arr
}

///|
async fn print_subdir_usage() -> Unit raise Error {
  print_line("Usage: moongit subdir <command> [options]")
  print_line("")
  print_line("Commands:")
  print_line("  init <path>      Initialize subdirectory as git module")
  print_line("  deinit <path>    Remove subdirectory module")
  print_line("  list             List initialized subdirectory modules")
  print_line("  sync <path>      Sync subdirectory with parent repository")
  print_line("  shell <path>     Start a shell with git scoped to subdirectory")
  print_line("  show <path>      Show subdirectory info")
  print_line("  log <path>       Show commits that affected the subdirectory")
  print_line("  diff <path>      Show working changes in subdirectory")
  print_line(
    "  commit <path>    Commit subdirectory changes to parent repository",
  )
  print_line(
    "  checkout <path> <commit>  Checkout specific commit of subdirectory",
  )
  print_line("  push <path>      Push subdirectory to remote repository")
  print_line("  pull <path>      Pull subdirectory from remote repository")
  print_line(
    "  extract <path> <target>  Extract subdirectory to target directory",
  )
  print_line(
    "  sparse-checkout <cmd>    Manage sparse checkout for subdirectory",
  )
  print_line("")
  print_line("Sparse-checkout commands:")
  print_line(
    "  sparse-checkout init <path> [--cone]     Enable sparse checkout",
  )
  print_line("  sparse-checkout set <path> <patterns>    Set sparse patterns")
  print_line("  sparse-checkout add <path> <patterns>    Add sparse patterns")
  print_line("  sparse-checkout list <path>              List sparse patterns")
  print_line(
    "  sparse-checkout disable <path>           Disable sparse checkout",
  )
  print_line("")
  print_line(
    "After 'init', standard git commands work from within the subdirectory.",
  )
}

///|
async fn handle_subdir_show(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir show <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ワーキングディレクトリの変更を読み込む
  subdir.load_workdir(fs, root)
  print_line("Subdirectory: " + subdir.path())
  match subdir.base_commit() {
    Some(id) => print_line("Base commit: " + id.to_hex())
    None => print_line("Base commit: (none)")
  }
  match subdir.tree_id() {
    Some(id) => print_line("Tree ID: " + id.to_hex())
    None => print_line("Tree ID: (none)")
  }
  print_line("Dirty: " + subdir.is_dirty().to_string())
}

///|
async fn handle_subdir_log(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir log <path> [--max-count=N]")
    return
  }
  let subdir_path = args[0]
  let mut max_count = 20
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("--max-count=") {
      max_count = parse_int_simple(subdir_skip_prefix(arg, 12))
    } else if arg == "-n" && i + 1 < args.length() {
      i += 1
      max_count = parse_int_simple(args[i])
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // 履歴を取得
  let history = subdir.log(fs, max_count~) catch {
    err => raise @git.GitError::IoError("Failed to get log: " + err.to_string())
  }
  if history.length() == 0 {
    print_line("No commits found that affected " + subdir_path)
    return
  }
  print_line("Commits affecting " + subdir_path + ":")
  print_line("")
  for commit in history {
    let _short_id = subdir_short_hex(commit.id.to_hex())
    print_line("commit " + commit.id.to_hex())
    if commit.author != "" {
      print_line("Author: " + commit.author)
    }
    if commit.timestamp > 0L {
      print_line("Date:   " + format_timestamp_simple(commit.timestamp))
    }
    print_line("")
    if commit.message != "" {
      print_line("    " + commit.message)
    }
    print_line("")
  }
}

///|
async fn handle_subdir_diff(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir diff <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ワーキングディレクトリの変更を読み込む
  subdir.load_workdir(fs, root)
  let diff = subdir.diff()
  if diff.length() == 0 {
    print_line("No changes in " + subdir_path)
    return
  }
  print_line("Changes in " + subdir_path + ":")
  for entry in diff {
    print_line(entry.to_string())
  }
}

///|
async fn handle_subdir_extract(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line("Usage: moongit subdir extract <path> <target>")
    return
  }
  let subdir_path = args[0]
  let target_dir = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ターゲットディレクトリを作成
  fs.mkdir_p(target_dir) catch {
    _ => ()
  }
  // ファイルを展開
  let gitfs = subdir.fs()
  let files = gitfs.readdir(fs, "/") catch {
    _ => raise @git.GitError::IoError("Failed to read subdirectory")
  }
  let mut count = 0
  for file in files {
    extract_file_recursive(fs, gitfs, "/", file, target_dir) catch {
      e => raise e
    }
    count += 1
  }
  print_line("Extracted " + count.to_string() + " items to " + target_dir)
}

///|
async fn extract_file_recursive(
  fs : OsFs,
  gitfs : @gitfs.GitFs,
  base_path : String,
  name : String,
  target_dir : String,
) -> Unit raise Error {
  let path = if base_path == "/" { "/" + name } else { base_path + "/" + name }
  if gitfs.is_dir(fs, path) {
    // ディレクトリの場合は再帰
    let subdir_target = target_dir + "/" + name
    fs.mkdir_p(subdir_target) catch {
      _ => ()
    }
    let children = gitfs.readdir(fs, path) catch { _ => return () }
    for child in children {
      extract_file_recursive(fs, gitfs, path, child, subdir_target) catch {
        e => raise e
      }
    }
  } else if gitfs.is_file(fs, path) {
    // ファイルの場合は内容を書き出し
    let content = gitfs.read_file(fs, path) catch { _ => return () }
    let target_path = target_dir + "/" + name
    fs.write_file(target_path, content) catch {
      _ => ()
    }
  }
}

///|
/// 文字列の先頭 n 文字をスキップ
fn subdir_skip_prefix(s : String, n : Int) -> String {
  let chars = s.to_array()
  if n >= chars.length() {
    return ""
  }
  let result = StringBuilder::new()
  for i = n; i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// 簡易的な整数パース
fn parse_int_simple(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - 48)
    }
  }
  result
}

///|
/// SHA の短縮表示
fn subdir_short_hex(hex : String) -> String {
  let chars = hex.to_array()
  let result = StringBuilder::new()
  for i = 0; i < 7 && i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// タイムスタンプのフォーマット
fn format_timestamp_simple(timestamp : Int64) -> String {
  // Unix タイムスタンプを簡易的に表示
  timestamp.to_string()
}

///|
async fn handle_subdir_init(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir init <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // サブディレクトリが存在するか確認
  let subdir_abs = root + "/" + subdir_path
  if not(fs.is_dir(subdir_abs)) {
    print_line("Error: subdirectory does not exist: " + subdir_path)
    return
  }
  // 既に初期化済みか確認
  if @subdir.is_module_initialized(fs, git_dir, subdir_path) {
    print_line("Subdirectory already initialized: " + subdir_path)
    return
  }
  // git modules 構造で初期化
  @subdir.init_module(fs, fs, git_dir, root, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to init: " + err.to_string())
  }
  // pre-commit hook に実行権限を付与
  let hook_path = git_dir + "/hooks/pre-commit"
  if fs.is_file(hook_path) {
    let _ = @process.run("chmod", ["+x", hook_path])

  }
  print_line("Initialized subdirectory as git module: " + subdir_path)
  print_line("")
  print_line("Structure created:")
  print_line("  .git/modules/" + subdir_path_to_safe_name(subdir_path) + "/")
  print_line("  " + subdir_path + "/.git (file)")
  print_line("")
  print_line(
    "You can now use standard git commands from within the subdirectory:",
  )
  print_line("  cd " + subdir_path)
  print_line("  git status    # shows only subdirectory changes")
  print_line("  git log       # shows commits affecting subdirectory")
  print_line("  git add/commit  # commits to parent repository")
}

///|
async fn handle_subdir_deinit(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir deinit <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールとして初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line("Subdirectory is not initialized: " + subdir_path)
    return
  }
  // モジュール構造を削除
  @subdir.deinit_module(fs, fs, git_dir, root, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to deinit: " + err.to_string())
  }
  print_line("Deinitialized subdirectory: " + subdir_path)
  print_line(
    "Removed .git/modules/" + subdir_path_to_safe_name(subdir_path) + "/",
  )
}

///|
async fn handle_subdir_shell(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir shell <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let subdir_abs = root + "/" + subdir_path
  // サブディレクトリが存在するか確認
  if not(fs.is_dir(subdir_abs)) {
    print_line("Error: subdirectory does not exist: " + subdir_path)
    return
  }
  // 環境変数を取得
  let env_vars = @subdir.generate_shell_env(git_dir, root, subdir_path)
  // RC スクリプトを生成
  let rc_script = @subdir.generate_shell_rc(subdir_path)
  // 一時ファイルに RC を書き込み
  let rc_path = "/tmp/moongit-subdir-rc-" + subdir_path_to_id(subdir_path)
  fs.write_file(rc_path, string_to_bytes_subdir(rc_script)) catch {
    _ => ()
  }
  // シェルを起動
  print_line("Starting subdir shell for: " + subdir_path)
  print_line("git commands will be scoped to this directory.")
  print_line("")
  // 環境変数を設定してシェルを起動
  let shell = get_user_shell()
  let shell_args = build_shell_args(shell, rc_path)
  // 環境変数を設定
  for pair in env_vars {
    @sys.set_env_var(pair.0, pair.1)
  }
  // シェルプロセスを起動（サブディレクトリで）
  // カレントディレクトリを変更してシェルを起動
  @sys.set_env_var("MOONGIT_SUBDIR_RC", rc_path)
  let exit_code = @process.run(shell, shell_args)
  if exit_code != 0 {
    print_line("Shell exited with code: " + exit_code.to_string())
  }
  // 一時ファイルを削除
  fs.remove_file(rc_path) catch {
    _ => ()
  }
  print_line("Exited subdir shell.")
}

///|
fn get_user_shell() -> String {
  match @sys.get_env_var("SHELL") {
    Some(s) => s
    None => "/bin/sh"
  }
}

///|
fn build_shell_args(shell : String, rc_path : String) -> Array[String] {
  // bash/zsh の場合は --rcfile を使用
  if shell.has_suffix("bash") {
    ["--rcfile", rc_path]
  } else if shell.has_suffix("zsh") {
    // zsh は ZDOTDIR を使うのが標準だが、簡易的に -i で対応
    ["-i"]
  } else {
    []
  }
}

///|
fn subdir_path_to_id(path : String) -> String {
  let result = StringBuilder::new()
  for c in path {
    if c == '/' {
      result.write_char('-')
    } else if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') {
      result.write_char(c)
    }
  }
  result.to_string()
}

///|
fn string_to_bytes_subdir(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
async fn handle_subdir_commit(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line(
      "Usage: moongit subdir commit <path> [-m <message>] [--author <author>]",
    )
    return
  }
  let subdir_path = args[0]
  let mut message = ""
  let mut author = "author <author@example.com>"
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "-m" && i + 1 < args.length() {
      i += 1
      message = args[i]
    } else if arg == "--author" && i + 1 < args.length() {
      i += 1
      author = args[i]
    } else if arg.has_prefix("-m") {
      message = subdir_skip_prefix(arg, 2)
    }
    i += 1
  }
  if message == "" {
    print_line("Error: commit message required (-m)")
    return
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // ワーキングディレクトリの変更を読み込む
  subdir.load_workdir(fs, root)
  // 変更があるか確認
  if not(subdir.is_dirty()) {
    print_line("Nothing to commit in " + subdir_path)
    return
  }
  // コミット
  let timestamp = get_current_timestamp()
  let commit_id = subdir.commit(fs, fs, message, author~, timestamp~) catch {
    err => raise @git.GitError::IoError("Failed to commit: " + err.to_string())
  }
  print_line("Committed subdirectory changes: " + commit_id.to_hex())
  print_line("  Path: " + subdir_path)
  print_line("  Message: " + message)
}

///|
async fn handle_subdir_checkout(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line("Usage: moongit subdir checkout <path> <commit>")
    return
  }
  let subdir_path = args[0]
  let commit_ref = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // コミットIDを解決
  let commit_id = resolve_commit_ref(fs, git_dir, commit_ref) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to resolve commit: " + err.to_string(),
      )
  }
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_commit(
    fs, git_dir, commit_id, subdir_path,
  ) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // サブディレクトリの絶対パス
  let subdir_abs = root + "/" + subdir_path
  // ワークツリーに展開
  let gitfs = subdir.fs()
  let files = gitfs.readdir(fs, "/") catch {
    _ => raise @git.GitError::IoError("Failed to read subdirectory")
  }
  // 既存のファイルを削除（.gitsubdir と git-subdir は保持）
  clear_subdir_worktree(fs, subdir_abs) catch {
    _ => ()
  }
  // ファイルを展開
  let mut count = 0
  for file in files {
    extract_file_recursive(fs, gitfs, "/", file, subdir_abs) catch {
      e => raise e
    }
    count += 1
  }
  print_line("Checked out " + subdir_path + " at " + commit_ref)
  print_line("  Commit: " + commit_id.to_hex())
  print_line("  Files: " + count.to_string() + " items")
}

///|
async fn handle_subdir_push(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line(
      "Usage: moongit subdir push <path> [<remote-url>] [--branch <branch>]",
    )
    print_line("")
    print_line("Push subdirectory to a remote repository.")
    print_line("If remote-url is not specified, uses configured remote.")
    return
  }
  let subdir_path = args[0]
  let mut remote_url : String? = None
  let mut branch = "main"
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "--branch" && i + 1 < args.length() {
      i += 1
      branch = args[i]
    } else if not(arg.has_prefix("-")) && remote_url is None {
      remote_url = Some(arg)
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // リモートURLを取得または設定ファイルから読み込み
  let url = match remote_url {
    Some(u) => u
    None => {
      // 設定ファイルからリモートを読み込み
      let config_remote = get_subdir_remote(fs, git_dir, subdir_path)
      match config_remote {
        Some(u) => u
        None => {
          print_line("Error: No remote URL specified and no remote configured.")
          print_line(
            "Use: moongit subdir push " + subdir_path + " <remote-url>",
          )
          return
        }
      }
    }
  }
  // SubdirRepo を作成
  let subdir = @subdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to open subdirectory: " + err.to_string(),
      )
  }
  // サブディレクトリのコミット履歴を取得
  let history = subdir.log(fs, max_count=1) catch {
    _ => raise @git.GitError::IoError("Failed to get history")
  }
  if history.length() == 0 {
    print_line("No commits in subdirectory")
    return
  }
  let latest = history[0]
  print_line("Pushing " + subdir_path + " to " + url)
  print_line("  Branch: " + branch)
  print_line("  Commit: " + latest.id.to_hex())
  // git push を実行（real git を使用）
  let push_result = @process.run("git", [
    "push",
    url,
    "HEAD:" + branch,
    "--force",
  ])
  if push_result != 0 {
    print_line(
      "Warning: git push may have failed (exit code: " +
      push_result.to_string() +
      ")",
    )
  } else {
    print_line("Push completed.")
    // リモートURLを設定に保存
    save_subdir_remote(fs, git_dir, subdir_path, url) catch {
      _ => ()
    }
  }
}

///|
async fn handle_subdir_pull(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line(
      "Usage: moongit subdir pull <path> [<remote-url>] [--branch <branch>]",
    )
    print_line("")
    print_line("Pull subdirectory from a remote repository.")
    print_line("If remote-url is not specified, uses configured remote.")
    return
  }
  let subdir_path = args[0]
  let mut remote_url : String? = None
  let mut branch = "main"
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "--branch" && i + 1 < args.length() {
      i += 1
      branch = args[i]
    } else if not(arg.has_prefix("-")) && remote_url is None {
      remote_url = Some(arg)
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // リモートURLを取得
  let url = match remote_url {
    Some(u) => u
    None => {
      let config_remote = get_subdir_remote(fs, git_dir, subdir_path)
      match config_remote {
        Some(u) => u
        None => {
          print_line("Error: No remote URL specified and no remote configured.")
          print_line(
            "Use: moongit subdir pull " + subdir_path + " <remote-url>",
          )
          return
        }
      }
    }
  }
  print_line("Pulling " + subdir_path + " from " + url)
  print_line("  Branch: " + branch)
  // 一時ディレクトリにクローン
  let temp_dir = "/tmp/moongit-subdir-pull-" + subdir_path_to_id(subdir_path)
  fs.mkdir_p(temp_dir) catch {
    _ => ()
  }
  // git clone
  let clone_result = @process.run("git", [
    "clone", "--depth=1", "--branch", branch, url, temp_dir,
  ])
  if clone_result != 0 {
    print_line("Error: Failed to clone from " + url)
    return
  }
  // サブディレクトリにコピー
  let subdir_abs = root + "/" + subdir_path
  // 既存ファイルをクリア
  clear_subdir_worktree(fs, subdir_abs) catch {
    _ => ()
  }
  // ファイルをコピー（.git を除く）
  copy_dir_recursive(fs, temp_dir, subdir_abs) catch {
    e => raise e
  }
  // 一時ディレクトリを削除
  remove_dir_recursive(fs, temp_dir) catch {
    _ => ()
  }
  print_line("Pull completed.")
  // リモートURLを設定に保存
  save_subdir_remote(fs, git_dir, subdir_path, url) catch {
    _ => ()
  }
}

///|
fn resolve_commit_ref(
  fs : OsFs,
  git_dir : String,
  ref_str : String,
) -> @git.ObjectId raise @git.GitError {
  // まず HEAD かブランチ名として解決を試みる
  if ref_str == "HEAD" {
    let head_id = @gitlib.resolve_head_commit(fs, git_dir) catch {
      _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
    }
    return match head_id {
      Some(id) => id
      None => raise @git.GitError::InvalidObject("HEAD not found")
    }
  }
  // ブランチとして試す
  let ref_path = git_dir + "/refs/heads/" + ref_str
  if fs.is_file(ref_path) {
    let content = fs.read_file(ref_path) catch {
      _ => raise @git.GitError::InvalidObject("Cannot read ref")
    }
    let hex = bytes_to_string_handler(content).trim(chars=" \n\t").to_string()
    return @git.ObjectId::from_hex(hex) catch {
      _ => raise @git.GitError::InvalidObject("Invalid ref content")
    }
  }
  // 直接SHA-1として解釈
  @git.ObjectId::from_hex(ref_str) catch {
    _ =>
      raise @git.GitError::InvalidObject("Invalid commit reference: " + ref_str)
  }
}

///|
fn clear_subdir_worktree(fs : OsFs, subdir_abs : String) -> Unit raise Error {
  // ディレクトリ内のファイルを削除（.gitsubdir と git-subdir は保持）
  let entries = fs.readdir(subdir_abs) catch { _ => return () }
  for entry in entries {
    if entry == ".gitsubdir" || entry == "git-subdir" {
      continue
    }
    let path = subdir_abs + "/" + entry
    if fs.is_dir(path) {
      subdir_remove_dir_recursive(fs, path) catch {
        _ => ()
      }
    } else {
      fs.remove_file(path) catch {
        _ => ()
      }
    }
  }
}

///|
fn subdir_remove_dir_recursive(fs : OsFs, path : String) -> Unit raise Error {
  let entries = fs.readdir(path) catch { _ => return () }
  for entry in entries {
    let child_path = path + "/" + entry
    if fs.is_dir(child_path) {
      subdir_remove_dir_recursive(fs, child_path) catch {
        _ => ()
      }
    } else {
      fs.remove_file(child_path) catch {
        _ => ()
      }
    }
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn copy_dir_recursive(
  fs : OsFs,
  src : String,
  dst : String,
) -> Unit raise Error {
  fs.mkdir_p(dst) catch {
    _ => ()
  }
  let entries = fs.readdir(src) catch { _ => return () }
  for entry in entries {
    // .git ディレクトリはスキップ
    if entry == ".git" {
      continue
    }
    let src_path = src + "/" + entry
    let dst_path = dst + "/" + entry
    if fs.is_dir(src_path) {
      copy_dir_recursive(fs, src_path, dst_path) catch {
        e => raise e
      }
    } else {
      let content = fs.read_file(src_path) catch { _ => continue }
      fs.write_file(dst_path, content) catch {
        _ => ()
      }
    }
  }
}

///|
fn get_subdir_remote(
  fs : OsFs,
  git_dir : String,
  subdir_path : String,
) -> String? {
  let safe_name = subdir_path_to_safe_name(subdir_path)
  let config_path = git_dir + "/subdir/" + safe_name + "/remote"
  let content = fs.read_file(config_path) catch { _ => return None }
  Some(bytes_to_string_handler(content).trim(chars=" \n\t").to_string())
}

///|
fn save_subdir_remote(
  fs : OsFs,
  git_dir : String,
  subdir_path : String,
  url : String,
) -> Unit raise Error {
  let safe_name = subdir_path_to_safe_name(subdir_path)
  let config_dir = git_dir + "/subdir/" + safe_name
  fs.mkdir_p(config_dir) catch {
    _ => ()
  }
  let config_path = config_dir + "/remote"
  fs.write_file(config_path, string_to_bytes_subdir(url)) catch {
    _ => ()
  }
}

///|
fn subdir_path_to_safe_name(path : String) -> String {
  let result = StringBuilder::new()
  for c in path {
    if c == '/' {
      result.write_char('_')
    } else {
      result.write_char(c)
    }
  }
  result.to_string()
}

///|
fn bytes_to_string_handler(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < bytes.length(); i = i + 1 {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
async fn handle_subdir_list(_args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let modules = @subdir.list_modules(fs, git_dir)
  if modules.length() == 0 {
    print_line("No subdirectory modules initialized.")
    print_line("Use 'moongit subdir init <path>' to initialize a subdirectory.")
    return
  }
  print_line("Initialized subdirectory modules:")
  print_line("")
  for path in modules {
    print_line("  " + path)
  }
}

///|
async fn handle_subdir_sync(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sync <path>")
    print_line("       moongit subdir sync --all")
    return
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args[0] == "--all" {
    // 全モジュールを同期
    let modules = @subdir.list_modules(fs, git_dir)
    if modules.length() == 0 {
      print_line("No subdirectory modules to sync.")
      return
    }
    for path in modules {
      @subdir.sync_module(fs, fs, git_dir, path) catch {
        _ => ()
      }
      print_line("Synced: " + path)
    }
  } else {
    let subdir_path = args[0]
    if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
      print_line("Subdirectory is not initialized: " + subdir_path)
      return
    }
    @subdir.sync_module(fs, fs, git_dir, subdir_path) catch {
      err => raise @git.GitError::IoError("Failed to sync: " + err.to_string())
    }
    print_line("Synced: " + subdir_path)
  }
}

///|
/// sparse-checkout サブコマンドのハンドラ
async fn handle_subdir_sparse_checkout(
  args : Array[String],
) -> Unit raise Error {
  if args.length() < 1 {
    print_sparse_checkout_usage()
    return
  }
  let cmd = args[0]
  let rest = array_view_to_array(args[1:])
  match cmd {
    "init" => handle_sparse_init(rest) catch { e => raise e }
    "set" => handle_sparse_set(rest) catch { e => raise e }
    "add" => handle_sparse_add(rest) catch { e => raise e }
    "list" => handle_sparse_list(rest) catch { e => raise e }
    "disable" => handle_sparse_disable(rest) catch { e => raise e }
    _ => {
      print_line("Unknown sparse-checkout command: " + cmd)
      print_sparse_checkout_usage()
    }
  }
}

///|
async fn print_sparse_checkout_usage() -> Unit raise Error {
  print_line("Usage: moongit subdir sparse-checkout <command> [options]")
  print_line("")
  print_line("Commands:")
  print_line(
    "  init <path> [--cone]     Enable sparse checkout for subdirectory",
  )
  print_line(
    "  set <path> <patterns>    Set sparse checkout patterns (replaces existing)",
  )
  print_line("  add <path> <patterns>    Add patterns to sparse checkout")
  print_line("  list <path>              List current sparse checkout patterns")
  print_line("  disable <path>           Disable sparse checkout")
  print_line("")
  print_line("Patterns:")
  print_line("  *.mbt        Match files with .mbt extension")
  print_line("  src/         Include src directory and its contents")
  print_line("  !tests/      Exclude tests directory")
  print_line("  **/test*.mbt Match test files in any directory")
}

///|
async fn handle_sparse_init(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sparse-checkout init <path> [--cone]")
    return
  }
  let subdir_path = args[0]
  let mut cone = false
  for i = 1; i < args.length(); i = i + 1 {
    if args[i] == "--cone" {
      cone = true
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line(
      "Error: subdirectory not initialized. Run 'moongit subdir init " +
      subdir_path +
      "' first.",
    )
    return
  }
  // sparse checkout を初期化
  @subdir.init_module_sparse(fs, fs, git_dir, subdir_path, cone~) catch {
    err =>
      raise @git.GitError::IoError("Failed to init sparse: " + err.to_string())
  }
  print_line("Sparse checkout enabled for: " + subdir_path)
  if cone {
    print_line("  Mode: cone (directory-based)")
  } else {
    print_line("  Mode: pattern-based")
  }
  print_line("")
  print_line(
    "Use 'moongit subdir sparse-checkout set " +
    subdir_path +
    " <patterns>' to specify files.",
  )
}

///|
async fn handle_sparse_set(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line(
      "Usage: moongit subdir sparse-checkout set <path> <pattern1> [pattern2] ...",
    )
    return
  }
  let subdir_path = args[0]
  let patterns : Array[String] = []
  for i = 1; i < args.length(); i = i + 1 {
    patterns.push(args[i])
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line(
      "Error: subdirectory not initialized. Run 'moongit subdir init " +
      subdir_path +
      "' first.",
    )
    return
  }
  // パターンを設定
  @subdir.set_module_sparse_patterns(fs, fs, git_dir, subdir_path, patterns) catch {
    err =>
      raise @git.GitError::IoError("Failed to set patterns: " + err.to_string())
  }
  print_line("Sparse checkout patterns set for: " + subdir_path)
  print_line("")
  for p in patterns {
    print_line("  " + p)
  }
  print_line("")
  print_line(
    "Use 'moongit subdir checkout " + subdir_path + " HEAD' to apply patterns.",
  )
}

///|
async fn handle_sparse_add(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line(
      "Usage: moongit subdir sparse-checkout add <path> <pattern1> [pattern2] ...",
    )
    return
  }
  let subdir_path = args[0]
  let patterns : Array[String] = []
  for i = 1; i < args.length(); i = i + 1 {
    patterns.push(args[i])
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line(
      "Error: subdirectory not initialized. Run 'moongit subdir init " +
      subdir_path +
      "' first.",
    )
    return
  }
  // パターンを追加
  @subdir.add_module_sparse_patterns(fs, fs, git_dir, subdir_path, patterns) catch {
    err =>
      raise @git.GitError::IoError("Failed to add patterns: " + err.to_string())
  }
  print_line("Patterns added to sparse checkout for: " + subdir_path)
  // 現在のパターンを表示
  let all_patterns = @subdir.read_module_sparse_patterns(
    fs, git_dir, subdir_path,
  )
  print_line("")
  print_line("Current patterns:")
  for p in all_patterns {
    print_line("  " + p)
  }
}

///|
async fn handle_sparse_list(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sparse-checkout list <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line("Error: subdirectory not initialized.")
    return
  }
  // sparse checkout が有効かチェック
  if not(@subdir.is_module_sparse_enabled(fs, git_dir, subdir_path)) {
    print_line("Sparse checkout is not enabled for: " + subdir_path)
    print_line(
      "Use 'moongit subdir sparse-checkout init " + subdir_path + "' to enable.",
    )
    return
  }
  // パターンを表示
  let patterns = @subdir.read_module_sparse_patterns(
    fs, git_dir, subdir_path,
  )
  if patterns.length() == 0 {
    print_line("No sparse checkout patterns set for: " + subdir_path)
    return
  }
  print_line("Sparse checkout patterns for: " + subdir_path)
  print_line("")
  for p in patterns {
    print_line("  " + p)
  }
}

///|
async fn handle_sparse_disable(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir sparse-checkout disable <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // モジュールが初期化されているか確認
  if not(@subdir.is_module_initialized(fs, git_dir, subdir_path)) {
    print_line("Error: subdirectory not initialized.")
    return
  }
  // sparse checkout を無効化
  @subdir.disable_module_sparse(fs, fs, git_dir, subdir_path) catch {
    err =>
      raise @git.GitError::IoError(
        "Failed to disable sparse: " + err.to_string(),
      )
  }
  print_line("Sparse checkout disabled for: " + subdir_path)
  print_line("All files will now be checked out.")
}
