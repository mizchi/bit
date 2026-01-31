///|
/// サブディレクトリ履歴のフィルタリング

///|
/// サブディレクトリに影響するコミット履歴を取得
///
/// アルゴリズム:
/// 1. 開始コミットから親方向に辿る
/// 2. 各コミットでサブディレクトリのツリーIDを取得
/// 3. 前のコミットとツリーIDが異なる場合、そのコミットを含める
pub fn SubdirRepo::log(
  self : SubdirRepo,
  rfs : &@git.RepoFileSystem,
  max_count? : Int = 100,
) -> Array[SubdirCommit] raise SubdirError {
  let start_commit = match self.current_commit {
    Some(id) => id
    None => return []
  }
  filter_subdir_history(
    rfs,
    self.git_dir,
    start_commit,
    self.subdir_path,
    max_count,
  )
}

///|
/// コミットのバイトデータから author と message を抽出
fn parse_commit_metadata(data : Bytes) -> (String, String, Int64) {
  let text = bytes_to_string_local(data)
  let lines = split_lines(text)
  let mut author = ""
  let mut message = ""
  let mut in_message = false
  for line in lines {
    if in_message {
      message = line
      break // 最初の行だけ取得
    } else if line.has_prefix("author ") {
      author = skip_prefix(line, 7)
    } else if line == "" {
      in_message = true
    }
  }
  let timestamp = extract_timestamp_from_author(author)
  (message, author, timestamp)
}

///|
/// Bytes を String に変換（ローカルヘルパー）
fn bytes_to_string_local(data : Bytes) -> String {
  let result = StringBuilder::new()
  for b in data {
    result.write_char(b.to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
/// 文字列を行に分割
fn split_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  let current = StringBuilder::new()
  for c in text {
    if c == '\n' {
      lines.push(current.to_string())
      // current を再初期化
      let _ = current.to_string()
      // 新しい StringBuilder を作成できないので、長さ0の状態にリセット
    } else if c != '\r' {
      current.write_char(c)
    }
  }
  let last = current.to_string()
  if last.length() > 0 {
    lines.push(last)
  }
  lines
}

///|
/// 文字列の先頭 n 文字をスキップ
fn skip_prefix(s : String, n : Int) -> String {
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
/// author 行からタイムスタンプを抽出
fn extract_timestamp_from_author(author : String) -> Int64 {
  // author 形式: "Name <email> 1234567890 +0000"
  let chars = author.to_array()
  let mut timestamp_start = 0
  let mut i = 0
  // ">" を見つける
  while i < chars.length() {
    if chars[i] == '>' {
      timestamp_start = i + 2 // "> " の後
      break
    }
    i += 1
  }
  if timestamp_start == 0 || timestamp_start >= chars.length() {
    return 0L
  }
  // タイムスタンプを読む
  let ts = StringBuilder::new()
  i = timestamp_start
  while i < chars.length() && chars[i] >= '0' && chars[i] <= '9' {
    ts.write_char(chars[i])
    i += 1
  }
  let ts_str = ts.to_string()
  if ts_str == "" {
    return 0L
  }
  // 文字列を数値に変換
  let mut result = 0L
  for c in ts_str {
    result = result * 10L + (c.to_int() - 48).to_int64()
  }
  result
}

///|
/// サブディレクトリに影響するコミット履歴をフィルタリング
fn filter_subdir_history(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  start_commit : @git.ObjectId,
  subdir_path : String,
  max_count : Int,
) -> Array[SubdirCommit] raise SubdirError {
  let db = @lib.ObjectDb::load(rfs, git_dir) catch {
    _ => raise IoError("failed to load object db")
  }
  let result : Array[SubdirCommit] = []
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [start_commit]
  let mut prev_tree : @git.ObjectId? = None
  while queue.length() > 0 && result.length() < max_count {
    let commit_id = queue.remove(0)
    let commit_hex = commit_id.to_hex()
    // 既に訪問済みならスキップ
    if visited.contains(commit_hex) {
      continue
    }
    visited[commit_hex] = true
    // コミット情報を取得
    let commit_obj = db.get(rfs, commit_id) catch { _ => continue }
    let obj = match commit_obj {
      Some(o) => o
      None => continue
    }
    let commit_info = @git.parse_commit(obj.data) catch { _ => continue }
    // サブディレクトリのツリーIDを取得
    let subdir_tree = get_subdir_tree_from_tree(
      db,
      rfs,
      commit_info.tree,
      subdir_path,
    )
    // 前のコミットとツリーIDが異なる場合、このコミットを結果に追加
    let tree_changed = match (prev_tree, subdir_tree) {
      (None, Some(_)) => true // サブディレクトリが初めて現れた
      (Some(prev), Some(curr)) => prev != curr // ツリーが変更された
      (Some(_), None) => true // サブディレクトリが削除された
      (None, None) => false // 変化なし
    }
    if tree_changed {
      match subdir_tree {
        Some(tree_id) => {
          let (message, author, timestamp) = parse_commit_metadata(obj.data)
          result.push({
            id: commit_id,
            subdir_tree: tree_id,
            message,
            author,
            timestamp,
            prev_commit: if result.length() > 0 {
              Some(result[result.length() - 1].id)
            } else {
              None
            },
          })
        }
        None => () // サブディレクトリが存在しない場合はスキップ
      }
    }
    // 前のツリーを更新
    prev_tree = subdir_tree
    // 親コミットをキューに追加
    for parent in commit_info.parents {
      if not(visited.contains(parent.to_hex())) {
        queue.push(parent)
      }
    }
  }
  result
}

///|
/// ルートツリーからサブディレクトリのツリーIDを取得（エラーを返さない版）
fn get_subdir_tree_from_tree(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  root_tree : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId? {
  let path_parts = split_subdir_path(subdir_path)
  if path_parts.length() == 0 {
    return Some(root_tree)
  }
  let mut current_tree = root_tree
  for part in path_parts {
    let tree_obj = db.get(rfs, current_tree) catch { _ => return None }
    let tobj = match tree_obj {
      Some(o) => o
      None => return None
    }
    let entries = @git.parse_tree(tobj.data) catch { _ => return None }
    let mut found_id : @git.ObjectId? = None
    for entry in entries {
      if entry.name == part && (entry.mode == "040000" || entry.mode == "40000") {
        found_id = Some(entry.id)
        break
      }
    }
    match found_id {
      Some(id) => current_tree = id
      None => return None
    }
  }
  Some(current_tree)
}

///|
/// パスを分割（履歴用）
fn split_subdir_path(path : String) -> Array[String] {
  if path == "" {
    return []
  }
  let parts : Array[String] = []
  let mut current = StringBuilder::new()
  for c in path {
    if c == '/' {
      let s = current.to_string()
      if s.length() > 0 {
        parts.push(s)
        current = StringBuilder::new()
      }
    } else {
      current.write_char(c)
    }
  }
  let s = current.to_string()
  if s.length() > 0 {
    parts.push(s)
  }
  parts
}

///|
/// サブディレクトリの差分を取得
pub fn SubdirRepo::diff(self : SubdirRepo) -> Array[DiffEntry] {
  let gitfs = self.gitfs
  let result : Array[DiffEntry] = []
  // ワーキング層の変更を収集
  let working = gitfs.get_working_files()
  let deleted = gitfs.get_deleted_files()
  // 追加・変更されたファイル
  for path in working {
    // 追加されたファイルとして扱う（変更と追加の区別は簡略化）
    result.push(Added(path, @git.ObjectId::zero()))
  }
  // 削除されたファイル
  for path in deleted {
    result.push(Deleted(path, @git.ObjectId::zero()))
  }
  result
}
