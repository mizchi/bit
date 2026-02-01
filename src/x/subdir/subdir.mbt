///|
/// SubdirRepo の構築と基本操作

///|
/// Bytes を String に変換（ASCII/UTF-8 として解釈）
fn bytes_to_string(data : Bytes) -> String {
  let result = StringBuilder::new()
  for b in data {
    result.write_char(b.to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
/// 文字列の末尾の改行を除去
fn trim_newlines(s : String) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 0 {
    let c = chars[end - 1]
    if c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  let result = StringBuilder::new()
  for i = 0; i < end; i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// 文字列の先頭 n 文字を除去
fn skip_chars(s : String, n : Int) -> String {
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
/// パスを正規化（先頭・末尾のスラッシュを除去）
fn normalize_subdir_path(path : String) -> String {
  let chars = path.to_array()
  let mut start = 0
  let mut end = chars.length()
  // 先頭のスラッシュと "./" を除去
  while start < end && chars[start] == '/' {
    start += 1
  }
  if start + 1 < end && chars[start] == '.' && chars[start + 1] == '/' {
    start += 2
  }
  // 末尾のスラッシュを除去
  while end > start && chars[end - 1] == '/' {
    end -= 1
  }
  // 結果を構築
  let result = StringBuilder::new()
  for i = start; i < end; i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// パスを分割
fn split_path(path : String) -> Array[String] {
  if path == "" {
    return []
  }
  let parts : Array[String] = []
  let mut current = StringBuilder::new()
  for c in path {
    if c == '/' {
      if current.to_string().length() > 0 {
        parts.push(current.to_string())
        current = StringBuilder::new()
      }
    } else {
      current.write_char(c)
    }
  }
  if current.to_string().length() > 0 {
    parts.push(current.to_string())
  }
  parts
}

///|
/// コミットからサブディレクトリのツリーIDを抽出
pub fn extract_subdir_tree(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId raise SubdirError {
  // コミットを取得
  let commit_obj = db.get(rfs, commit_id) catch {
    _ => raise CommitNotFound(commit_id)
  }
  let obj = match commit_obj {
    Some(o) => o
    None => raise CommitNotFound(commit_id)
  }
  let commit = @git.parse_commit(obj.data) catch {
    _ => raise CommitNotFound(commit_id)
  }
  // ルートツリーから開始
  let mut current_tree = commit.tree
  let path_parts = split_path(normalize_subdir_path(subdir_path))
  if path_parts.length() == 0 {
    // ルートディレクトリの場合
    return current_tree
  }
  // パスを辿る
  for part in path_parts {
    let tree_obj = db.get(rfs, current_tree) catch {
      _ => raise TreeNotFound(current_tree)
    }
    let tobj = match tree_obj {
      Some(o) => o
      None => raise TreeNotFound(current_tree)
    }
    let entries = @git.parse_tree(tobj.data) catch {
      _ => raise TreeNotFound(current_tree)
    }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        // ツリーモード（ディレクトリ）かチェック
        if entry.mode == "040000" || entry.mode == "40000" {
          current_tree = entry.id
          found = true
          break
        } else {
          // ファイルを指している場合はエラー
          raise SubdirNotFound(subdir_path)
        }
      }
    }
    if not(found) {
      raise SubdirNotFound(subdir_path)
    }
  }
  current_tree
}

///|
/// コミットからサブディレクトリリポジトリを作成
pub fn SubdirRepo::from_commit(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  subdir_path : String,
  config? : SubdirConfig = SubdirConfig::default(),
) -> SubdirRepo raise SubdirError {
  let normalized_path = normalize_subdir_path(subdir_path)
  if normalized_path == "" {
    raise InvalidPath("subdir_path cannot be empty or root")
  }
  // ObjectDb を読み込む
  let db = @lib.ObjectDb::load(rfs, git_dir) catch {
    _ => raise IoError("failed to load object db")
  }
  // サブディレクトリのツリーを抽出
  let tree_id = extract_subdir_tree(db, rfs, commit_id, normalized_path) catch {
    e => raise e
  }
  // サブディレクトリのツリーをベースとした Fs を作成
  let bitfs = @fs.Fs::from_tree(git_dir, tree_id)
  {
    git_dir,
    subdir_path: normalized_path,
    current_commit: Some(commit_id),
    subdir_tree: Some(tree_id),
    bitfs,
    config,
  }
}

///|
/// HEAD からサブディレクトリリポジトリを作成
pub fn SubdirRepo::from_head(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  subdir_path : String,
  config? : SubdirConfig = SubdirConfig::default(),
) -> SubdirRepo raise SubdirError {
  // HEAD を読み取る
  let head_content = rfs.read_file(git_dir + "/HEAD") catch {
    _ => raise IoError("failed to read HEAD")
  }
  let head_str = trim_newlines(bytes_to_string(head_content))
  let head_id : @git.ObjectId = if head_str.has_prefix("ref: ") {
    // シンボリックリファレンス
    let ref_path = skip_chars(head_str, 5)
    let ref_content = rfs.read_file(git_dir + "/" + ref_path) catch {
      _ => raise IoError("failed to read ref: " + ref_path)
    }
    @git.ObjectId::from_hex(trim_newlines(bytes_to_string(ref_content))) catch {
      _ => raise IoError("invalid commit id in ref")
    }
  } else {
    @git.ObjectId::from_hex(head_str) catch {
      _ => raise IoError("invalid commit id in HEAD")
    }
  }
  SubdirRepo::from_commit(rfs, git_dir, head_id, subdir_path, config~) catch {
    e => raise e
  }
}

///|
/// ブランチからサブディレクトリリポジトリを作成
pub fn SubdirRepo::from_branch(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  branch : String,
  subdir_path : String,
  config? : SubdirConfig = SubdirConfig::default(),
) -> SubdirRepo raise SubdirError {
  // ブランチリファレンスを読み取る
  let ref_path = git_dir + "/refs/heads/" + branch
  let ref_content = rfs.read_file(ref_path) catch {
    _ => raise IoError("branch not found: " + branch)
  }
  let commit_id = @git.ObjectId::from_hex(
    trim_newlines(bytes_to_string(ref_content)),
  ) catch {
    _ => raise IoError("invalid commit id in branch ref")
  }
  SubdirRepo::from_commit(rfs, git_dir, commit_id, subdir_path, config~) catch {
    e => raise e
  }
}

///|
/// サブディレクトリのパスを取得
pub fn SubdirRepo::path(self : SubdirRepo) -> String {
  self.subdir_path
}

///|
/// 現在のベースコミットを取得
pub fn SubdirRepo::base_commit(self : SubdirRepo) -> @git.ObjectId? {
  self.current_commit
}

///|
/// サブディレクトリのツリーIDを取得
pub fn SubdirRepo::tree_id(self : SubdirRepo) -> @git.ObjectId? {
  self.subdir_tree
}

///|
/// 変更があるかどうか
pub fn SubdirRepo::is_dirty(self : SubdirRepo) -> Bool {
  self.bitfs.is_dirty()
}

///|
/// Fs を取得（内部アクセス用）
pub fn SubdirRepo::fs(self : SubdirRepo) -> @fs.Fs {
  self.bitfs
}

///|
/// ワーキングディレクトリの変更を bitfs に読み込む
/// rfs: 実際のファイルシステム（OsFs など）
/// workdir: ワーキングディレクトリのルートパス
pub fn SubdirRepo::load_workdir(
  self : SubdirRepo,
  rfs : &@git.RepoFileSystem,
  workdir : String,
) -> Unit {
  // サブディレクトリのパスを取得
  let subdir_abs = workdir + "/" + self.subdir_path
  // ディレクトリスタック（base_path, rel_path）
  let stack : Array[(String, String)] = [(subdir_abs, "/")]
  while stack.length() > 0 {
    let (base_path, rel_path) = stack.pop().unwrap()
    let dir_path = if rel_path == "/" {
      base_path
    } else {
      base_path + rel_path
    }
    let entries = rfs.readdir(dir_path) catch {
      _ => continue // ディレクトリが読めなければスキップ
    }
    for entry in entries {
      // .git ファイル/ディレクトリはスキップ
      if entry == ".git" {
        continue
      }
      let full_path = dir_path + "/" + entry
      let bitfs_path = if rel_path == "/" {
        "/" + entry
      } else {
        rel_path + "/" + entry
      }
      if rfs.is_dir(full_path) {
        // ディレクトリの場合はスタックに追加
        stack.push((base_path, bitfs_path))
      } else {
        // ファイルの場合は読み込んで比較
        let content = rfs.read_file(full_path) catch {
          _ => continue // 読めなければスキップ
        }
        // 既存の内容と比較
        let existing = self.bitfs.read_file(rfs, bitfs_path) catch {
          _ => b"" // ファイルが存在しない場合は空
        }
        // 異なる場合のみ書き込み
        if content != existing {
          self.bitfs.write_file(bitfs_path, content)
        }
      }
    }
  }
}
