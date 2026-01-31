///|
/// Git モジュール構造の作成
///
/// サブディレクトリを git submodule 風の構造で初期化し、
/// 標準の git コマンドが透過的に動作するようにする。

///|
/// gitlink mode (160000 octal = submodule)
let gitlink_mode : Int = 57344

///|
/// サブディレクトリをモジュールとして初期化
pub fn init_module(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  let subdir_abs = repo_root + "/" + normalized_path
  // 0. 現在の HEAD コミットを取得（gitlink 用）
  let head_commit_id = resolve_head_commit_for_module(rfs, git_dir)
  // 1. modules ディレクトリを作成
  fs.mkdir_p(module_dir) catch {
    _ => raise IoError("failed to create module directory")
  }
  fs.mkdir_p(module_dir + "/refs/heads") catch {
    _ => ()
  }
  fs.mkdir_p(module_dir + "/refs/tags") catch {
    _ => ()
  }
  // 2. HEAD を作成（親の HEAD を参照）
  let parent_head = read_parent_head(rfs, git_dir)
  let head_content = match parent_head {
    Some(ref_str) => ref_str
    None => "ref: refs/heads/main\n"
  }
  fs.write_file(module_dir + "/HEAD", string_to_bytes_mod(head_content)) catch {
    _ => raise IoError("failed to write HEAD")
  }
  // 3. config を作成
  // モジュールは常に .git/modules/<name>/ にあるため、
  // repo root へは常に 3 レベル上がる
  let rel_worktree = "../../../" + normalized_path
  let config_content = build_module_config(rel_worktree, normalized_path)
  let depth = count_path_depth(normalized_path)
  fs.write_file(module_dir + "/config", string_to_bytes_mod(config_content)) catch {
    _ => raise IoError("failed to write config")
  }
  // 4. objects へのシンボリックリンク（または共有参照）
  // MoonBit の FileSystem には symlink がないので、代わりに alternates を使う
  let objects_dir = module_dir + "/objects"
  fs.mkdir_p(objects_dir) catch {
    _ => ()
  }
  fs.mkdir_p(objects_dir + "/info") catch {
    _ => ()
  }
  let alternates_content = git_dir + "/objects\n"
  fs.write_file(
    objects_dir + "/info/alternates",
    string_to_bytes_mod(alternates_content),
  ) catch {
    _ => raise IoError("failed to write alternates")
  }
  // 5. サブディレクトリに .git ファイルを作成
  let gitdir_rel = build_gitdir_path(depth, module_name)
  let gitfile_content = "gitdir: " + gitdir_rel + "\n"
  fs.write_file(subdir_abs + "/.git", string_to_bytes_mod(gitfile_content)) catch {
    _ => raise IoError("failed to write .git file")
  }
  // 6. exclude ファイルを作成（.git ファイルを除外しない設定）
  let info_dir = module_dir + "/info"
  fs.mkdir_p(info_dir) catch {
    _ => ()
  }
  fs.write_file(info_dir + "/exclude", string_to_bytes_mod("")) catch {
    _ => ()
  }
  // 7. filter driver スクリプトを作成
  setup_filter_script(fs, rfs, git_dir, normalized_path) catch {
    e => raise e
  }
  // 8. .gitattributes に filter パターンを追加
  setup_gitattributes_filter(fs, rfs, repo_root, normalized_path) catch {
    e => raise e
  }
  ignore(head_commit_id)
}

///|
/// Filter driver スクリプトを作成
fn setup_filter_script(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let filter_name = "moongit-subdir-" + path_to_module_name(subdir_path)
  let hooks_dir = git_dir + "/moongit-filters"
  fs.mkdir_p(hooks_dir) catch {
    _ => ()
  }
  // clean filter スクリプト（警告を出してパススルー）
  let clean_script = hooks_dir + "/" + filter_name + "-clean"
  let clean_content = "#!/bin/sh\ncat\n"
  fs.write_file(clean_script, string_to_bytes_mod(clean_content)) catch {
    _ => raise IoError("failed to write clean script")
  }
  // pre-commit hook を設定
  setup_precommit_hook(fs, rfs, git_dir, subdir_path) catch {
    _ => ()
  }
  // smudge filter スクリプト（checkout 時に実行、パススルー）
  let smudge_script = hooks_dir + "/" + filter_name + "-smudge"
  let smudge_content = "#!/bin/sh\ncat\n"
  fs.write_file(smudge_script, string_to_bytes_mod(smudge_content)) catch {
    _ => raise IoError("failed to write smudge script")
  }
  // .git/config に filter 設定を追加
  setup_filter_config(
    fs, rfs, git_dir, filter_name, clean_script, smudge_script,
  ) catch {
    e => raise e
  }
}

///|
/// .git/config に filter 設定を追加
fn setup_filter_config(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  filter_name : String,
  clean_script : String,
  smudge_script : String,
) -> Unit raise SubdirError {
  let config_path = git_dir + "/config"
  let config = rfs.read_file(config_path) catch { _ => b"" }
  let mut content = bytes_to_string_mod(config)
  let section_header = "[filter \"" + filter_name + "\"]"
  if content.contains(section_header) {
    return ()
  }
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  content = content + section_header + "\n"
  content = content + "\tclean = sh " + clean_script + "\n"
  content = content + "\tsmudge = sh " + smudge_script + "\n"
  fs.write_file(config_path, string_to_bytes_mod(content)) catch {
    _ => raise IoError("failed to write config")
  }
}

///|
/// .gitattributes に filter パターンを追加
fn setup_gitattributes_filter(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let filter_name = "moongit-subdir-" + path_to_module_name(subdir_path)
  let gitattributes_path = repo_root + "/.gitattributes"
  let mut content = if rfs.is_file(gitattributes_path) {
    bytes_to_string_mod(rfs.read_file(gitattributes_path) catch { _ => b"" })
  } else {
    ""
  }
  let pattern = subdir_path + "/** filter=" + filter_name
  if content.contains(pattern) {
    return ()
  }
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  content = content + "# moongit subdir: " + subdir_path + "\n"
  content = content + pattern + "\n"
  fs.write_file(gitattributes_path, string_to_bytes_mod(content)) catch {
    _ => raise IoError("failed to write .gitattributes")
  }
}

///|
/// pre-commit hook を設定
fn setup_precommit_hook(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let hooks_dir = git_dir + "/hooks"
  fs.mkdir_p(hooks_dir) catch {
    _ => ()
  }
  let hook_path = hooks_dir + "/pre-commit"
  let marker = "# moongit-subdir-check: " + subdir_path
  // 既存の hook を読み込み
  let mut content = if rfs.is_file(hook_path) {
    bytes_to_string_mod(rfs.read_file(hook_path) catch { _ => b"" })
  } else {
    "#!/bin/sh\n"
  }
  // 既に設定済みかチェック
  if content.contains(marker) {
    return ()
  }
  // hook スクリプトを追加
  if not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  content = content + "\n" + marker + "\n"
  content = content +
    "if git diff --cached --name-only | grep -q '^" +
    subdir_path +
    "/'; then\n"
  content = content +
    "  echo \"Error: '" +
    subdir_path +
    "' is managed by moongit. Direct git commit is not allowed.\" >&2\n"
  content = content +
    "  echo \"Use 'moongit subdir commit " +
    subdir_path +
    " -m <message>' instead.\" >&2\n"
  content = content + "  exit 1\n"
  content = content + "fi\n"
  fs.write_file(hook_path, string_to_bytes_mod(content)) catch {
    _ => raise IoError("failed to write pre-commit hook")
  }
}

///|
/// pre-commit hook から subdir チェックを削除
fn remove_precommit_hook(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let hooks_dir = git_dir + "/hooks"
  let hook_path = hooks_dir + "/pre-commit"
  if not(rfs.is_file(hook_path)) {
    return ()
  }
  let content = bytes_to_string_mod(
    rfs.read_file(hook_path) catch {
      _ => return ()
    },
  )
  let marker = "# moongit-subdir-check: " + subdir_path
  if not(content.contains(marker)) {
    return ()
  }
  // マーカーから fi までを削除
  let new_content = remove_hook_section(content, marker)
  if new_content == "#!/bin/sh\n" || new_content.length() < 15 {
    // ほぼ空になった場合は削除
    fs.remove_file(hook_path) catch {
      _ => ()
    }
  } else {
    fs.write_file(hook_path, string_to_bytes_mod(new_content)) catch {
      _ => raise IoError("failed to update pre-commit hook")
    }
  }
}

///|
/// hook からセクションを削除
fn remove_hook_section(content : String, marker : String) -> String {
  let result = StringBuilder::new()
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if line == marker {
      in_section = true
      continue
    }
    if in_section {
      if line == "fi" {
        in_section = false
        continue
      }
      continue
    }
    // 空行が連続しないように
    let current = result.to_string()
    if line.length() == 0 && current.has_suffix("\n\n") {
      continue
    }
    result.write_string(line)
    result.write_string("\n")
  }
  trim_trailing_newlines(result.to_string())
}

///|
/// Filter driver を設定して git add をブロック
fn setup_filter_driver(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let filter_name = "moongit-subdir-" + path_to_module_name(subdir_path)
  // 1. .git/config に filter を追加
  add_filter_to_config(fs, rfs, git_dir, filter_name, subdir_path) catch {
    e => raise e
  }
  // 2. .gitattributes にパターンを追加
  add_filter_to_gitattributes(fs, rfs, repo_root, filter_name, subdir_path) catch {
    e => raise e
  }
}

///|
/// .git/config に filter 設定を追加
fn add_filter_to_config(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  filter_name : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let config_path = git_dir + "/config"
  let mut config = if rfs.is_file(config_path) {
    bytes_to_string_mod(rfs.read_file(config_path) catch { _ => b"" })
  } else {
    ""
  }
  // 既に設定済みかチェック
  let section_header = "[filter \"" + filter_name + "\"]"
  if config.contains(section_header) {
    return ()
  }
  // filter セクションを追加
  let filter_section = StringBuilder::new()
  if config.length() > 0 && not(config.has_suffix("\n")) {
    filter_section.write_string("\n")
  }
  filter_section.write_string("[filter \"")
  filter_section.write_string(filter_name)
  filter_section.write_string("\"]\n")
  filter_section.write_string("\tclean = echo \"Error: '")
  filter_section.write_string(subdir_path)
  filter_section.write_string(
    "' is managed by moongit subdir. Use 'moongit subdir commit' instead.\" >&2 && exit 1\n",
  )
  filter_section.write_string("\tsmudge = cat\n")
  filter_section.write_string("\trequired = true\n")
  config = config + filter_section.to_string()
  fs.write_file(config_path, string_to_bytes_mod(config)) catch {
    _ => raise IoError("failed to write config")
  }
}

///|
/// .gitattributes に filter パターンを追加
fn add_filter_to_gitattributes(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  repo_root : String,
  filter_name : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let gitattributes_path = repo_root + "/.gitattributes"
  let mut content = if rfs.is_file(gitattributes_path) {
    bytes_to_string_mod(rfs.read_file(gitattributes_path) catch { _ => b"" })
  } else {
    ""
  }
  // パターンを構築
  let pattern = subdir_path + "/** filter=" + filter_name
  // 既に設定済みかチェック
  if content.contains(pattern) {
    return ()
  }
  // パターンを追加
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  // コメントを追加して分かりやすく
  content = content + "# moongit subdir: " + subdir_path + "\n"
  content = content + pattern + "\n"
  fs.write_file(gitattributes_path, string_to_bytes_mod(content)) catch {
    _ => raise IoError("failed to write .gitattributes")
  }
}

///|
/// Filter driver を削除
fn cleanup_filter_driver(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let filter_name = "moongit-subdir-" + path_to_module_name(subdir_path)
  // 1. filter スクリプトを削除
  let hooks_dir = git_dir + "/moongit-filters"
  fs.remove_file(hooks_dir + "/" + filter_name + "-clean") catch {
    _ => ()
  }
  fs.remove_file(hooks_dir + "/" + filter_name + "-smudge") catch {
    _ => ()
  }
  // hooks_dir が空なら削除
  let entries = rfs.readdir(hooks_dir) catch { _ => [] }
  if entries.length() == 0 {
    fs.remove_dir(hooks_dir) catch {
      _ => ()
    }
  }
  // 2. .git/config から filter を削除
  remove_filter_from_config(fs, rfs, git_dir, filter_name) catch {
    _ => ()
  }
  // 3. .gitattributes からパターンを削除
  remove_filter_from_gitattributes(fs, rfs, repo_root, filter_name, subdir_path) catch {
    _ => ()
  }
  // 4. pre-commit hook から削除
  remove_precommit_hook(fs, rfs, git_dir, subdir_path) catch {
    _ => ()
  }
}

///|
/// .git/config から filter セクションを削除
fn remove_filter_from_config(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  filter_name : String,
) -> Unit raise SubdirError {
  let config_path = git_dir + "/config"
  if not(rfs.is_file(config_path)) {
    return ()
  }
  let content = bytes_to_string_mod(
    rfs.read_file(config_path) catch {
      _ => return ()
    },
  )
  let section_header = "[filter \"" + filter_name + "\"]"
  if not(content.contains(section_header)) {
    return ()
  }
  // セクションを削除
  let new_content = remove_config_section(
    content,
    "filter \"" + filter_name + "\"",
  )
  fs.write_file(config_path, string_to_bytes_mod(new_content)) catch {
    _ => raise IoError("failed to update config")
  }
}

///|
/// config からセクションを削除
fn remove_config_section(content : String, section_name : String) -> String {
  let result = StringBuilder::new()
  let section_header = "[" + section_name + "]"
  let mut in_section = false
  let mut prev_was_empty = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if line == section_header {
      in_section = true
      continue
    }
    if in_section {
      // 次のセクションまたは空行でセクション終了
      if line.has_prefix("[") {
        in_section = false
        result.write_string(line)
        result.write_string("\n")
        prev_was_empty = false
      } else if line.has_prefix("\t") || line.has_prefix(" ") {
        // セクション内の設定行はスキップ
        continue
      } else if line.length() == 0 {
        // 空行でセクション終了
        in_section = false
      }
      continue
    }
    // 連続した空行を避ける
    if line.length() == 0 {
      if prev_was_empty {
        continue
      }
      prev_was_empty = true
    } else {
      prev_was_empty = false
    }
    result.write_string(line)
    result.write_string("\n")
  }
  let s = result.to_string()
  // 末尾の余分な改行を削除
  trim_trailing_newlines(s)
}

///|
/// 末尾の連続改行を1つに
fn trim_trailing_newlines(s : String) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 1 && chars[end - 1] == '\n' && chars[end - 2] == '\n' {
    end -= 1
  }
  if end == chars.length() {
    s
  } else {
    String::unsafe_substring(s, start=0, end~)
  }
}

///|
/// .gitattributes から filter パターンを削除
fn remove_filter_from_gitattributes(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  repo_root : String,
  filter_name : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let gitattributes_path = repo_root + "/.gitattributes"
  if not(rfs.is_file(gitattributes_path)) {
    return ()
  }
  let content = bytes_to_string_mod(
    rfs.read_file(gitattributes_path) catch {
      _ => return ()
    },
  )
  let pattern_line = subdir_path + "/** filter=" + filter_name
  let comment_line = "# moongit subdir: " + subdir_path
  if not(content.contains(pattern_line)) {
    return ()
  }
  // パターンとコメントを削除
  let result = StringBuilder::new()
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if line == pattern_line || line == comment_line {
      continue
    }
    if line.length() > 0 || result.to_string().length() > 0 {
      result.write_string(line)
      result.write_string("\n")
    }
  }
  let new_content = trim_trailing_newlines(result.to_string())
  if new_content.length() == 0 {
    // 空になった場合は削除
    fs.remove_file(gitattributes_path) catch {
      _ => ()
    }
  } else {
    fs.write_file(gitattributes_path, string_to_bytes_mod(new_content)) catch {
      _ => raise IoError("failed to update .gitattributes")
    }
  }
}

///|
/// HEAD コミットを解決
fn resolve_head_commit_for_module(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId? {
  let head_path = git_dir + "/HEAD"
  let content = rfs.read_file(head_path) catch { _ => return None }
  let head_str = trim_newlines_mod(bytes_to_string_mod(content))
  if head_str.has_prefix("ref: ") {
    let ref_path = skip_chars_mod(head_str, 5)
    let ref_content = rfs.read_file(git_dir + "/" + ref_path) catch {
      _ => return None
    }
    let hex = trim_newlines_mod(bytes_to_string_mod(ref_content))
    Some(@git.ObjectId::from_hex(hex)) catch {
      _ => None
    }
  } else {
    Some(@git.ObjectId::from_hex(head_str)) catch {
      _ => None
    }
  }
}

///|
/// .gitmodules にサブモジュールエントリを追加
fn add_to_gitmodules(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let gitmodules_path = repo_root + "/.gitmodules"
  let mut content = if rfs.is_file(gitmodules_path) {
    bytes_to_string_mod(rfs.read_file(gitmodules_path) catch { _ => b"" })
  } else {
    ""
  }
  // 既に登録されているかチェック
  let section_header = "[submodule \"" + subdir_path + "\"]"
  if content.contains(section_header) {
    return ()
  }
  // 新しいエントリを追加
  let entry = StringBuilder::new()
  if content.length() > 0 && not(content.has_suffix("\n")) {
    entry.write_string("\n")
  }
  entry.write_string("[submodule \"")
  entry.write_string(subdir_path)
  entry.write_string("\"]\n")
  entry.write_string("\tpath = ")
  entry.write_string(subdir_path)
  entry.write_string("\n")
  entry.write_string("\turl = .\n") // 自己参照
  content = content + entry.to_string()
  fs.write_file(gitmodules_path, string_to_bytes_mod(content)) catch {
    _ => raise IoError("failed to write .gitmodules")
  }
}

///|
/// .gitmodules からサブモジュールエントリを削除
fn remove_from_gitmodules(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let gitmodules_path = repo_root + "/.gitmodules"
  if not(rfs.is_file(gitmodules_path)) {
    return ()
  }
  let content = bytes_to_string_mod(
    rfs.read_file(gitmodules_path) catch {
      _ => return ()
    },
  )
  let section_header = "[submodule \"" + subdir_path + "\"]"
  if not(content.contains(section_header)) {
    return ()
  }
  // セクションを削除
  let new_content = remove_gitmodules_section(content, subdir_path)
  if new_content.length() == 0 || new_content == "\n" {
    // .gitmodules が空になった場合は削除
    fs.remove_file(gitmodules_path) catch {
      _ => ()
    }
  } else {
    fs.write_file(gitmodules_path, string_to_bytes_mod(new_content)) catch {
      _ => raise IoError("failed to update .gitmodules")
    }
  }
}

///|
/// .gitmodules からセクションを削除
fn remove_gitmodules_section(content : String, subdir_path : String) -> String {
  let result = StringBuilder::new()
  let section_header = "[submodule \"" + subdir_path + "\"]"
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if line == section_header {
      in_section = true
      continue
    }
    if in_section {
      // 次のセクションの開始でセクション終了
      if line.has_prefix("[") {
        in_section = false
        result.write_string(line)
        result.write_string("\n")
      }
      // セクション内の行はスキップ
      continue
    }
    result.write_string(line)
    result.write_string("\n")
  }
  // 末尾の余分な改行を削除
  let s = result.to_string()
  if s.has_suffix("\n\n") {
    String::unsafe_substring(s, start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
/// index に gitlink エントリを追加
fn add_gitlink_to_index(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
  commit_id : @git.ObjectId,
) -> Unit raise SubdirError {
  // 現在の index を読み込む
  let entries = @lib.read_index_entries(rfs, git_dir) catch { _ => [] }
  // subdir_path 以下のエントリを削除し、gitlink を追加
  let new_entries : Array[@lib.IndexEntry] = []
  for entry in entries {
    // subdir_path 内のファイルは除外
    if entry.path.has_prefix(subdir_path + "/") || entry.path == subdir_path {
      continue
    }
    new_entries.push(entry)
  }
  // gitlink エントリを追加
  new_entries.push(
    @lib.IndexEntry::new(subdir_path, commit_id, gitlink_mode, 0),
  )
  // index を書き込む
  @lib.write_index_entries(fs, git_dir, new_entries) catch {
    _ => raise IoError("failed to update index")
  }
}

///|
/// index から gitlink エントリを削除し、サブディレクトリのファイルを復元
fn remove_gitlink_from_index(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let entries = @lib.read_index_entries(rfs, git_dir) catch { _ => [] }
  // gitlink エントリを削除
  let new_entries : Array[@lib.IndexEntry] = []
  for entry in entries {
    if entry.path == subdir_path && entry.mode == gitlink_mode {
      continue
    }
    new_entries.push(entry)
  }
  @lib.write_index_entries(fs, git_dir, new_entries) catch {
    _ => raise IoError("failed to update index")
  }
}

///|
fn trim_newlines_mod(s : String) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 0 {
    let c = chars[end - 1]
    if c == '\n' || c == '\r' || c == ' ' || c == '\t' {
      end -= 1
    } else {
      break
    }
  }
  if end == chars.length() {
    s
  } else {
    String::unsafe_substring(s, start=0, end~)
  }
}

///|
fn skip_chars_mod(s : String, n : Int) -> String {
  if n >= s.length() {
    ""
  } else {
    String::unsafe_substring(s, start=n, end=s.length())
  }
}

///|
/// モジュールが初期化済みかチェック
pub fn is_module_initialized(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Bool {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  rfs.is_dir(module_dir) && rfs.is_file(module_dir + "/HEAD")
}

///|
/// モジュールを削除
pub fn deinit_module(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  repo_root : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  let subdir_abs = repo_root + "/" + normalized_path
  // 1. .git ファイルを削除
  fs.remove_file(subdir_abs + "/.git") catch {
    _ => ()
  }
  // 2. モジュールディレクトリを削除
  if rfs.is_dir(module_dir) {
    remove_module_dir(fs, rfs, module_dir)
  }
  // 3. filter スクリプトと設定を削除
  cleanup_filter_driver(fs, rfs, git_dir, repo_root, normalized_path) catch {
    _ => ()
  }
}

///|
/// モジュールの状態を親リポジトリと同期
pub fn sync_module(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
) -> Unit raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  let module_name = path_to_module_name(normalized_path)
  let module_dir = git_dir + "/modules/" + module_name
  // 親の HEAD を取得してモジュールの HEAD を更新
  let parent_head = read_parent_head(rfs, git_dir)
  match parent_head {
    Some(ref_str) =>
      fs.write_file(module_dir + "/HEAD", string_to_bytes_mod(ref_str)) catch {
        _ => raise IoError("failed to sync HEAD")
      }
    None => ()
  }
}

///|
/// 初期化済みモジュール一覧を取得
pub fn list_modules(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] {
  let modules_dir = git_dir + "/modules"
  if not(rfs.is_dir(modules_dir)) {
    return []
  }
  let entries = rfs.readdir(modules_dir) catch { _ => return [] }
  let result : Array[String] = []
  for entry in entries {
    let module_path = modules_dir + "/" + entry
    if rfs.is_dir(module_path) && rfs.is_file(module_path + "/HEAD") {
      // モジュール名をパスに戻す
      result.push(module_name_to_path(entry))
    }
  }
  result
}

///|
/// パスをモジュール名に変換（/ を _ に）
fn path_to_module_name(path : String) -> String {
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
/// モジュール名をパスに戻す（_ を / に）
fn module_name_to_path(name : String) -> String {
  let result = StringBuilder::new()
  for c in name {
    if c == '_' {
      result.write_char('/')
    } else {
      result.write_char(c)
    }
  }
  result.to_string()
}

///|
/// パスの深さをカウント
fn count_path_depth(path : String) -> Int {
  let mut count = 0
  for c in path {
    if c == '/' {
      count += 1
    }
  }
  count + 1
}

///|
/// 相対パスを構築（../ を depth 回）
fn build_relative_path(depth : Int, subdir_path : String) -> String {
  let result = StringBuilder::new()
  for i = 0; i < depth; i = i + 1 {
    result.write_string("../")
  }
  result.write_string(subdir_path)
  result.to_string()
}

///|
/// gitdir パスを構築
fn build_gitdir_path(depth : Int, module_name : String) -> String {
  let result = StringBuilder::new()
  for i = 0; i < depth; i = i + 1 {
    result.write_string("../")
  }
  result.write_string(".git/modules/")
  result.write_string(module_name)
  result.to_string()
}

///|
/// モジュール用 config を生成
fn build_module_config(worktree_path : String, subdir_path : String) -> String {
  let config = StringBuilder::new()
  config.write_string("[core]\n")
  config.write_string("\trepositoryformatversion = 0\n")
  config.write_string("\tfilemode = true\n")
  config.write_string("\tbare = false\n")
  config.write_string("\tworktree = ")
  config.write_string(worktree_path)
  config.write_string("\n")
  config.write_string("[subdir]\n")
  config.write_string("\tpath = ")
  config.write_string(subdir_path)
  config.write_string("\n")
  config.write_string("\tactive = true\n")
  config.to_string()
}

///|
/// 親リポジトリの HEAD を読み取り
fn read_parent_head(rfs : &@git.RepoFileSystem, git_dir : String) -> String? {
  let head_path = git_dir + "/HEAD"
  let content = rfs.read_file(head_path) catch { _ => return None }
  Some(bytes_to_string_mod(content))
}

///|
/// モジュールディレクトリを再帰的に削除
fn remove_module_dir(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  path : String,
) -> Unit {
  let entries = rfs.readdir(path) catch { _ => return () }
  for entry in entries {
    let child_path = path + "/" + entry
    if rfs.is_dir(child_path) {
      remove_module_dir(fs, rfs, child_path)
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
fn string_to_bytes_mod(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
fn bytes_to_string_mod(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < bytes.length(); i = i + 1 {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}
