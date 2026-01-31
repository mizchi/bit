///|
/// Sparse checkout support for subdirectory modules
///
/// サブディレクトリモジュール内で sparse checkout を有効にし、
/// 特定のファイル/パターンのみをワークツリーに展開する。

///|
/// モジュールの sparse checkout が有効かチェック
pub fn is_module_sparse_enabled(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Bool {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  let config_path = module_dir + "/config"
  if not(rfs.is_file(config_path)) {
    return false
  }
  let content = rfs.read_file(config_path) catch { _ => return false }
  let text = bytes_to_string_sparse(content)
  let mut in_core = false
  for line_view in text.split("\n") {
    let line = sparse_trim(line_view.to_string())
    if line == "[core]" {
      in_core = true
      continue
    }
    if line.has_prefix("[") {
      in_core = false
      continue
    }
    if in_core && line.has_prefix("sparseCheckout") {
      if line.contains("true") || line.contains("= true") {
        return true
      }
    }
  }
  false
}

///|
/// モジュールの sparse checkout パターンを読み取り
pub fn read_module_sparse_patterns(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Array[String] {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  let sparse_path = module_dir + "/info/sparse-checkout"
  if not(rfs.is_file(sparse_path)) {
    return []
  }
  let content = rfs.read_file(sparse_path) catch { _ => return [] }
  let text = bytes_to_string_sparse(content)
  let patterns : Array[String] = []
  for line_view in text.split("\n") {
    let line = sparse_trim(line_view.to_string())
    if line.length() > 0 && not(line.has_prefix("#")) {
      patterns.push(line)
    }
  }
  patterns
}

///|
/// モジュールの sparse checkout パターンを書き込み
pub fn write_module_sparse_patterns(
  fs : &@git.FileSystem,
  git_dir : String,
  subdir_path : String,
  patterns : Array[String],
) -> Unit raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  let info_dir = module_dir + "/info"
  fs.mkdir_p(info_dir) catch {
    _ => raise IoError("failed to create info directory")
  }
  let sparse_path = module_dir + "/info/sparse-checkout"
  let content = build_sparse_content(patterns)
  fs.write_file(sparse_path, string_to_bytes_sparse(content)) catch {
    _ => raise IoError("failed to write sparse-checkout file")
  }
}

///|
/// モジュールの sparse checkout を初期化
pub fn init_module_sparse(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
  cone? : Bool = false,
) -> Unit raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  // モジュールが初期化済みかチェック
  if not(rfs.is_dir(module_dir)) {
    raise IoError("module not initialized: " + subdir_path)
  }
  // config に sparseCheckout = true を追加
  let config_path = module_dir + "/config"
  let mut config = if rfs.is_file(config_path) {
    bytes_to_string_sparse(rfs.read_file(config_path) catch { _ => b"" })
  } else {
    "[core]\n"
  }
  // sparseCheckout = true を追加
  if not(config.contains("sparseCheckout")) {
    if config.contains("[core]") {
      config = config.replace(
        old="[core]",
        new="[core]\n\tsparseCheckout = true",
      )
    } else {
      config = config + "[core]\n\tsparseCheckout = true\n"
    }
  }
  // cone mode を追加
  if cone && not(config.contains("sparseCheckoutCone")) {
    if config.contains("[core]") {
      config = config.replace(
        old="sparseCheckout = true",
        new="sparseCheckout = true\n\tsparseCheckoutCone = true",
      )
    }
  }
  fs.write_file(config_path, string_to_bytes_sparse(config)) catch {
    _ => raise IoError("failed to update config")
  }
  // 初期パターン（ルートのみ）を設定
  let info_dir = module_dir + "/info"
  fs.mkdir_p(info_dir) catch {
    _ => ()
  }
  let sparse_path = module_dir + "/info/sparse-checkout"
  if not(rfs.is_file(sparse_path)) {
    fs.write_file(sparse_path, string_to_bytes_sparse("/*\n!/*/\n")) catch {
      _ => raise IoError("failed to write initial sparse-checkout")
    }
  }
}

///|
/// モジュールの sparse checkout パターンを設定（既存を置換）
pub fn set_module_sparse_patterns(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
  patterns : Array[String],
) -> Unit raise SubdirError {
  // sparse checkout が初期化されていなければ初期化
  if not(is_module_sparse_enabled(rfs, git_dir, subdir_path)) {
    init_module_sparse(fs, rfs, git_dir, subdir_path) catch {
      e => raise e
    }
  }
  write_module_sparse_patterns(fs, git_dir, subdir_path, patterns) catch {
    e => raise e
  }
}

///|
/// モジュールの sparse checkout にパターンを追加
pub fn add_module_sparse_patterns(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
  new_patterns : Array[String],
) -> Unit raise SubdirError {
  // sparse checkout が初期化されていなければ初期化
  if not(is_module_sparse_enabled(rfs, git_dir, subdir_path)) {
    init_module_sparse(fs, rfs, git_dir, subdir_path) catch {
      e => raise e
    }
  }
  let existing = read_module_sparse_patterns(rfs, git_dir, subdir_path)
  for p in new_patterns {
    if not(existing.contains(p)) {
      existing.push(p)
    }
  }
  write_module_sparse_patterns(fs, git_dir, subdir_path, existing) catch {
    e => raise e
  }
}

///|
/// モジュールの sparse checkout を無効化
pub fn disable_module_sparse(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  // config を更新
  let config_path = module_dir + "/config"
  if rfs.is_file(config_path) {
    let config = bytes_to_string_sparse(
      rfs.read_file(config_path) catch {
        _ => b""
      },
    )
    let new_config = config
      .replace(old="sparseCheckout = true", new="sparseCheckout = false")
      .replace(
        old="sparseCheckoutCone = true",
        new="sparseCheckoutCone = false",
      )
    fs.write_file(config_path, string_to_bytes_sparse(new_config)) catch {
      _ => raise IoError("failed to update config")
    }
  }
}

///|
/// パスが sparse パターンにマッチするかチェック
pub fn matches_module_sparse(path : String, patterns : Array[String]) -> Bool {
  if patterns.length() == 0 {
    return true // パターンがない場合はすべて含める
  }
  let mut included = false
  for pattern in patterns {
    if pattern.has_prefix("!") {
      // 否定パターン
      let neg_pattern = if pattern.length() > 1 {
        String::unsafe_substring(pattern, start=1, end=pattern.length())
      } else {
        ""
      }
      if sparse_path_matches(path, neg_pattern) {
        included = false
      }
    } else if sparse_path_matches(path, pattern) {
      included = true
    }
  }
  included
}

///|
/// パターンマッチ（シンプルな glob 対応）
fn sparse_path_matches(path : String, pattern : String) -> Bool {
  // "/*" - ルート直下のファイル
  if pattern == "/*" {
    return not(path.contains("/"))
  }
  // "!/*/" - ルート直下のディレクトリを除外
  if pattern == "!/*/" {
    return path.contains("/")
  }
  // "**" - 任意のパス（先にチェック）
  if pattern.contains("**") {
    return match_double_star(path, pattern)
  }
  // "dir/" - ディレクトリとその中身
  if pattern.has_suffix("/") {
    let dir = String::unsafe_substring(
      pattern,
      start=0,
      end=pattern.length() - 1,
    )
    return path == dir || path.has_prefix(dir + "/")
  }
  // "dir/*" - ディレクトリ直下のファイル
  if pattern.has_suffix("/*") {
    let dir = String::unsafe_substring(
      pattern,
      start=0,
      end=pattern.length() - 2,
    )
    if path.has_prefix(dir + "/") {
      let rest = String::unsafe_substring(
        path,
        start=dir.length() + 1,
        end=path.length(),
      )
      return not(rest.contains("/"))
    }
    return false
  }
  // "*.ext" - 拡張子マッチ
  if pattern.has_prefix("*") {
    let suffix = String::unsafe_substring(
      pattern,
      start=1,
      end=pattern.length(),
    )
    return path.has_suffix(suffix)
  }
  // "prefix*" - プレフィックスマッチ
  if pattern.has_suffix("*") {
    let prefix = String::unsafe_substring(
      pattern,
      start=0,
      end=pattern.length() - 1,
    )
    return path.has_prefix(prefix)
  }
  // 完全一致またはプレフィックス
  path == pattern || path.has_prefix(pattern + "/")
}

///|
/// Double star パターンマッチ（例: "**/test*.mbt"）
fn match_double_star(path : String, pattern : String) -> Bool {
  let parts = pattern.split("**")
  let parts_arr : Array[String] = []
  for p in parts {
    parts_arr.push(p.to_string())
  }
  if parts_arr.length() != 2 {
    return false
  }
  let prefix = parts_arr[0]
  let suffix = parts_arr[1]
  // プレフィックスチェック
  if prefix.length() > 0 && not(path.has_prefix(prefix)) {
    return false
  }
  // サフィックスのパス部分を取得（ファイル名のみ）
  let filename = get_filename(path)
  // サフィックスがスラッシュで始まる場合は除去
  let suffix_pattern = if suffix.has_prefix("/") {
    String::unsafe_substring(suffix, start=1, end=suffix.length())
  } else {
    suffix
  }
  // サフィックスにワイルドカードが含まれる場合
  if suffix_pattern.contains("*") {
    return match_simple_glob(filename, suffix_pattern)
  }
  // 単純なサフィックスマッチ
  suffix.length() == 0 || path.has_suffix(suffix)
}

///|
/// ファイル名を取得（パスの最後の部分）
fn get_filename(path : String) -> String {
  let chars = path.to_array()
  let mut last_slash = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '/' {
      last_slash = i
    }
  }
  if last_slash < 0 {
    path
  } else {
    String::unsafe_substring(path, start=last_slash + 1, end=path.length())
  }
}

///|
/// シンプルなグロブマッチ（"test*.mbt" のような形式）
fn match_simple_glob(filename : String, pattern : String) -> Bool {
  // パターン内の * の位置を探す
  let chars = pattern.to_array()
  let mut star_pos = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '*' {
      star_pos = i
      break
    }
  }
  if star_pos < 0 {
    // * がない場合は完全一致
    return filename == pattern
  }
  // * の前と後で分割
  let before = if star_pos == 0 {
    ""
  } else {
    String::unsafe_substring(pattern, start=0, end=star_pos)
  }
  let after = if star_pos + 1 >= pattern.length() {
    ""
  } else {
    String::unsafe_substring(pattern, start=star_pos + 1, end=pattern.length())
  }
  // プレフィックスとサフィックスをチェック
  (before.length() == 0 || filename.has_prefix(before)) &&
  (after.length() == 0 || filename.has_suffix(after))
}

///|
/// sparse checkout パターンファイルの内容を構築
fn build_sparse_content(patterns : Array[String]) -> String {
  let result = StringBuilder::new()
  result.write_string("# Sparse checkout patterns\n")
  for p in patterns {
    result.write_string(p)
    result.write_string("\n")
  }
  result.to_string()
}

///|
fn sparse_trim(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn bytes_to_string_sparse(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < bytes.length(); i = i + 1 {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn string_to_bytes_sparse(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}
