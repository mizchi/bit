///|
/// サブディレクトリの初期化機能
///
/// サブディレクトリを透過的な git 操作が可能な状態に初期化する。
/// - .git/subdir/<path>/ に設定を作成
/// - サブディレクトリに .gitsubdir マーカーを作成
/// - オプションで git ラッパースクリプトを生成

///|
/// サブディレクトリを初期化
pub fn init_subdir(
  fs : &@git.FileSystem,
  git_dir : String,
  repo_root : String,
  subdir_path : String,
  config : SubdirInitConfig,
) -> SubdirInfo raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  // サブディレクトリの絶対パス
  let subdir_abs = repo_root + "/" + normalized_path
  // .git/subdir/<path>/ ディレクトリを作成
  let subdir_config_dir = git_dir +
    "/subdir/" +
    path_to_safe_name(normalized_path)
  fs.mkdir_p(subdir_config_dir) catch {
    _ => raise IoError("failed to create subdir config directory")
  }
  // 設定ファイルを作成
  let config_path = subdir_config_dir + "/config"
  let config_content = build_config_content(normalized_path, repo_root)
  fs.write_file(config_path, string_to_bytes_init(config_content)) catch {
    _ => raise IoError("failed to write config file")
  }
  // .gitsubdir マーカーファイルを作成
  let marker_path = subdir_abs + "/.gitsubdir"
  let marker_content = if config.verbose_marker {
    build_verbose_marker(normalized_path, git_dir)
  } else {
    "# This directory is managed as a git subdirectory\n"
  }
  fs.write_file(marker_path, string_to_bytes_init(marker_content)) catch {
    _ => raise IoError("failed to write marker file")
  }
  // git ラッパースクリプトを生成
  if config.create_wrapper {
    create_wrapper_script(fs, subdir_abs, normalized_path) catch {
      e => raise e
    }
  }
  { path: normalized_path, git_dir, config_path, initialized: true }
}

///|
/// サブディレクトリが初期化済みかチェック
pub fn is_subdir_initialized(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Bool {
  let normalized_path = normalize_subdir_path(subdir_path)
  let config_dir = git_dir + "/subdir/" + path_to_safe_name(normalized_path)
  let config_path = config_dir + "/config"
  rfs.is_file(config_path)
}

///|
/// 初期化済みサブディレクトリの情報を取得
pub fn get_subdir_info(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  repo_root : String,
  subdir_path : String,
) -> SubdirInfo? {
  let normalized_path = normalize_subdir_path(subdir_path)
  let config_dir = git_dir + "/subdir/" + path_to_safe_name(normalized_path)
  let config_path = config_dir + "/config"
  if rfs.is_file(config_path) {
    Some({ path: normalized_path, git_dir, config_path, initialized: true })
  } else {
    None
  }
}

///|
/// 初期化を解除
pub fn deinit_subdir(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  let subdir_abs = repo_root + "/" + normalized_path
  // 設定ディレクトリを削除
  let config_dir = git_dir + "/subdir/" + path_to_safe_name(normalized_path)
  if rfs.is_dir(config_dir) {
    // config ファイルを削除
    fs.remove_file(config_dir + "/config") catch {
      _ => ()
    }
    fs.remove_dir(config_dir) catch {
      _ => ()
    }
  }
  // マーカーファイルを削除
  let marker_path = subdir_abs + "/.gitsubdir"
  fs.remove_file(marker_path) catch {
    _ => ()
  }
  // ラッパースクリプトを削除
  let wrapper_path = subdir_abs + "/git-subdir"
  fs.remove_file(wrapper_path) catch {
    _ => ()
  }
}

///|
/// シェル起動用の環境変数設定を生成
pub fn generate_shell_env(
  git_dir : String,
  repo_root : String,
  subdir_path : String,
) -> Array[(String, String)] {
  let normalized_path = normalize_subdir_path(subdir_path)
  [
    ("MOONGIT_SUBDIR", normalized_path),
    ("MOONGIT_GIT_DIR", git_dir),
    ("MOONGIT_REPO_ROOT", repo_root),
    ("GIT_PREFIX", normalized_path + "/"),
  ]
}

///|
/// シェル起動用の RC スクリプトを生成
pub fn generate_shell_rc(subdir_path : String) -> String {
  let normalized_path = normalize_subdir_path(subdir_path)
  let script = StringBuilder::new()
  // ヘッダー
  script.write_string("# Moongit subdir shell for: ")
  script.write_string(normalized_path)
  script.write_string("\n\n")
  // git ラッパー関数
  script.write_string("git() {\n")
  script.write_string("  local cmd=\"$1\"\n")
  script.write_string("  shift\n")
  script.write_string("  case \"$cmd\" in\n")
  // log コマンド
  script.write_string("    log)\n")
  script.write_string("      command git log \"$@\" -- .\n")
  script.write_string("      ;;\n")
  // status コマンド
  script.write_string("    status)\n")
  script.write_string("      command git status \"$@\" -- .\n")
  script.write_string("      ;;\n")
  // diff コマンド
  script.write_string("    diff)\n")
  script.write_string("      command git diff \"$@\" -- .\n")
  script.write_string("      ;;\n")
  // add コマンド
  script.write_string("    add)\n")
  script.write_string("      if [ $# -eq 0 ] || [ \"$1\" = \".\" ]; then\n")
  script.write_string("        command git add .\n")
  script.write_string("      else\n")
  script.write_string("        command git add \"$@\"\n")
  script.write_string("      fi\n")
  script.write_string("      ;;\n")
  // その他のコマンド
  script.write_string("    *)\n")
  script.write_string("      command git \"$cmd\" \"$@\"\n")
  script.write_string("      ;;\n")
  script.write_string("  esac\n")
  script.write_string("}\n\n")
  // プロンプト変更
  script.write_string("export PS1=\"[subdir:")
  script.write_string(normalized_path)
  script.write_string("] $PS1\"\n\n")
  // 終了時メッセージ
  script.write_string("echo \"Entered subdir shell for: ")
  script.write_string(normalized_path)
  script.write_string("\"\n")
  script.write_string("echo \"git commands are scoped to this directory.\"\n")
  script.write_string("echo \"Type 'exit' to return.\"\n")
  script.to_string()
}

///|
/// パスをファイル名安全な形式に変換（/ を _ に）
fn path_to_safe_name(path : String) -> String {
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
/// 設定ファイルの内容を生成
fn build_config_content(subdir_path : String, repo_root : String) -> String {
  let content = StringBuilder::new()
  content.write_string("[subdir]\n")
  content.write_string("\tpath = ")
  content.write_string(subdir_path)
  content.write_string("\n")
  content.write_string("\trepoRoot = ")
  content.write_string(repo_root)
  content.write_string("\n")
  content.write_string("\tinitialized = true\n")
  content.to_string()
}

///|
/// 詳細なマーカーファイルの内容を生成
fn build_verbose_marker(subdir_path : String, git_dir : String) -> String {
  let content = StringBuilder::new()
  content.write_string("# This directory is managed as a git subdirectory\n")
  content.write_string("# Do not edit this file manually\n")
  content.write_string("\n")
  content.write_string("path = ")
  content.write_string(subdir_path)
  content.write_string("\n")
  content.write_string("gitdir = ")
  content.write_string(git_dir)
  content.write_string("\n")
  content.to_string()
}

///|
/// git ラッパースクリプトを作成
fn create_wrapper_script(
  fs : &@git.FileSystem,
  subdir_abs : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let script_path = subdir_abs + "/git-subdir"
  let script = StringBuilder::new()
  script.write_string("#!/bin/sh\n")
  script.write_string("# Git wrapper for subdirectory: ")
  script.write_string(subdir_path)
  script.write_string("\n\n")
  script.write_string("cmd=\"$1\"\n")
  script.write_string("shift\n\n")
  script.write_string("case \"$cmd\" in\n")
  script.write_string("  log|status|diff)\n")
  script.write_string("    git \"$cmd\" \"$@\" -- .\n")
  script.write_string("    ;;\n")
  script.write_string("  *)\n")
  script.write_string("    git \"$cmd\" \"$@\"\n")
  script.write_string("    ;;\n")
  script.write_string("esac\n")
  fs.write_file(script_path, string_to_bytes_init(script.to_string())) catch {
    _ => raise IoError("failed to write wrapper script")
  }
}

///|
/// String を Bytes に変換
fn string_to_bytes_init(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}
