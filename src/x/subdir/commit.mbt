///|
/// サブディレクトリでのコミット機能
///
/// サブディレクトリの変更を元リポジトリにコミットする。
/// 1. サブディレクトリの Fs から新しいツリーを構築
/// 2. 元リポジトリのルートツリーでサブディレクトリ部分を置換
/// 3. 新しいコミットを作成

///|
/// サブディレクトリの変更を元リポジトリにコミット
pub fn SubdirRepo::commit(
  self : SubdirRepo,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  message : String,
  author? : String = "author <author@example.com>",
  timestamp? : Int64 = 0L,
) -> @git.ObjectId raise SubdirError {
  // 変更がなければエラー
  if not(self.is_dirty()) {
    raise IoError("nothing to commit")
  }
  // 親コミットを取得
  let parent_commit = match self.current_commit {
    Some(id) => id
    None => raise IoError("no parent commit")
  }
  // Fs からサブディレクトリの新しいツリーを構築
  let new_subdir_tree = @fs.build_tree_from_working(
    fs,
    rfs,
    self.git_dir,
    self.bitfs.base_tree(),
    self.bitfs.working,
  ) catch {
    _ => raise IoError("failed to build tree")
  }
  // 元リポジトリのルートツリーを取得し、サブディレクトリ部分を置換
  let db = @lib.ObjectDb::load(rfs, self.git_dir) catch {
    _ => raise IoError("failed to load object db")
  }
  let parent_obj = db.get(rfs, parent_commit) catch {
    _ => raise CommitNotFound(parent_commit)
  }
  let parent_data = match parent_obj {
    Some(o) => o
    None => raise CommitNotFound(parent_commit)
  }
  let parent_info = @git.parse_commit(parent_data.data) catch {
    _ => raise CommitNotFound(parent_commit)
  }
  // ルートツリーを取得してサブディレクトリを置換
  let new_root_tree = replace_subdir_tree(
    fs,
    rfs,
    db,
    self.git_dir,
    parent_info.tree,
    self.subdir_path,
    new_subdir_tree,
  ) catch {
    e => raise e
  }
  // 新しいコミットを作成
  let new_commit_id = create_commit_object(
    fs,
    self.git_dir,
    new_root_tree,
    parent_commit,
    message,
    author,
    timestamp,
  ) catch {
    e => raise e
  }
  // HEAD（またはブランチ参照）を更新
  update_head_ref(fs, rfs, self.git_dir, new_commit_id) catch {
    e => raise e
  }
  // インデックスを新しいコミットに合わせて更新
  update_index_from_commit(fs, rfs, self.git_dir, new_commit_id) catch {
    e => raise e
  }
  // ワーキング層をクリア
  self.bitfs.discard_changes()
  new_commit_id
}

///|
/// ルートツリーのサブディレクトリ部分を置換して新しいツリーを作成
fn replace_subdir_tree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  db : @lib.ObjectDb,
  git_dir : String,
  root_tree : @git.ObjectId,
  subdir_path : String,
  new_subdir_tree : @git.ObjectId,
) -> @git.ObjectId raise SubdirError {
  let path_parts = split_subdir_path(subdir_path)
  if path_parts.length() == 0 {
    // サブディレクトリがルートの場合、そのまま返す
    return new_subdir_tree
  }
  // 再帰的にツリーを置換
  replace_tree_recursive(
    fs, rfs, db, git_dir, root_tree, path_parts, 0, new_subdir_tree,
  )
}

///|
/// ツリーを再帰的に置換
fn replace_tree_recursive(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  db : @lib.ObjectDb,
  git_dir : String,
  current_tree : @git.ObjectId,
  path_parts : Array[String],
  depth : Int,
  new_leaf_tree : @git.ObjectId,
) -> @git.ObjectId raise SubdirError {
  // 現在のツリーを読み込む
  let tree_obj = db.get(rfs, current_tree) catch {
    _ => raise TreeNotFound(current_tree)
  }
  let tree_data = match tree_obj {
    Some(o) => o
    None => raise TreeNotFound(current_tree)
  }
  let entries = @git.parse_tree(tree_data.data) catch {
    _ => raise TreeNotFound(current_tree)
  }
  // 新しいエントリリストを構築
  let new_entries : Array[@git.TreeEntry] = []
  let target_name = path_parts[depth]
  let is_last = depth == path_parts.length() - 1
  for entry in entries {
    if entry.name == target_name {
      // 対象のエントリを置換
      if is_last {
        // 最後のパス要素なら、新しいツリーで置換
        new_entries.push(
          @git.TreeEntry::new(entry.mode, entry.name, new_leaf_tree),
        )
      } else {
        // まだパスが続く場合は再帰
        let new_child_tree = replace_tree_recursive(
          fs,
          rfs,
          db,
          git_dir,
          entry.id,
          path_parts,
          depth + 1,
          new_leaf_tree,
        ) catch {
          e => raise e
        }
        new_entries.push(
          @git.TreeEntry::new(entry.mode, entry.name, new_child_tree),
        )
      }
    } else {
      // 対象外のエントリはそのまま
      new_entries.push(entry)
    }
  }
  // 新しいツリーオブジェクトを作成して保存
  let tree_content = build_tree_content(new_entries)
  let tree_id = write_object(fs, git_dir, "tree", tree_content) catch {
    _ => raise IoError("failed to write tree object")
  }
  tree_id
}

///|
/// ツリーエントリからツリーオブジェクトの内容を構築
fn build_tree_content(entries : Array[@git.TreeEntry]) -> Bytes {
  // エントリをソート（Git のツリーは名前でソートされている必要がある）
  let sorted = entries.copy()
  sorted.sort_by(fn(a, b) {
    // ディレクトリは名前の後に "/" を追加してソート
    let a_name = if a.mode == "040000" || a.mode == "40000" {
      a.name + "/"
    } else {
      a.name
    }
    let b_name = if b.mode == "040000" || b.mode == "40000" {
      b.name + "/"
    } else {
      b.name
    }
    a_name.compare(b_name)
  })
  // バイナリ形式で構築: "mode name\0<20-byte-sha>"
  let parts : Array[Bytes] = []
  for entry in sorted {
    // モードと名前
    let header = entry.mode + " " + entry.name
    let header_bytes = string_to_bytes_local(header)
    // null バイト
    let null_byte = Bytes::from_array([b'\x00'])
    // SHA-1 の 20 バイト
    let sha_bytes = entry.id.to_bytes()
    // 結合
    parts.push(header_bytes)
    parts.push(null_byte)
    parts.push(sha_bytes)
  }
  // すべてを結合
  concat_bytes(parts)
}

///|
/// 複数の Bytes を結合
fn concat_bytes(parts : Array[Bytes]) -> Bytes {
  let bytes : Array[Byte] = []
  for part in parts {
    for i = 0; i < part.length(); i = i + 1 {
      bytes.push(part[i])
    }
  }
  Bytes::from_array(bytes)
}

///|
/// String を Bytes に変換
fn string_to_bytes_local(s : String) -> Bytes {
  let chars = s.to_array()
  let bytes : Array[Byte] = []
  for i = 0; i < chars.length(); i = i + 1 {
    bytes.push(chars[i].to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
/// オブジェクトを書き込む
fn write_object(
  fs : &@git.FileSystem,
  git_dir : String,
  obj_type : String,
  content : Bytes,
) -> @git.ObjectId raise SubdirError {
  // ヘッダー: "type size\0"
  let header = obj_type + " " + content.length().to_string()
  let header_bytes = string_to_bytes_local(header)
  let null_byte = Bytes::from_array([b'\x00'])
  // フルデータ
  let full_data = concat_bytes([header_bytes, null_byte, content])
  // SHA-1 ハッシュを計算
  let hash = @git.sha1(full_data)
  let hex = hash.to_hex()
  // オブジェクトパス: first 2 chars / rest
  let dir_name = hex_substring(hex, 0, 2)
  let file_name = hex_substring(hex, 2, 40)
  let dir_path = git_dir + "/objects/" + dir_name
  let file_path = dir_path + "/" + file_name
  // ディレクトリ作成
  fs.mkdir_p(dir_path) catch {
    _ => ()
  }
  // zlib 圧縮して書き込み
  let compressed = @zlib.zlib_compress(full_data)
  fs.write_file(file_path, compressed) catch {
    _ => raise IoError("failed to write object")
  }
  hash
}

///|
/// 文字列から部分文字列を取得
fn hex_substring(s : String, start : Int, end : Int) -> String {
  let chars = s.to_array()
  let result = StringBuilder::new()
  for i = start; i < end && i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// コミットオブジェクトを作成
fn create_commit_object(
  fs : &@git.FileSystem,
  git_dir : String,
  tree_id : @git.ObjectId,
  parent_id : @git.ObjectId,
  message : String,
  author : String,
  timestamp : Int64,
) -> @git.ObjectId raise SubdirError {
  // コミット内容を構築
  let content = StringBuilder::new()
  content.write_string("tree ")
  content.write_string(tree_id.to_hex())
  content.write_string("\n")
  content.write_string("parent ")
  content.write_string(parent_id.to_hex())
  content.write_string("\n")
  content.write_string("author ")
  content.write_string(author)
  content.write_string(" ")
  content.write_string(timestamp.to_string())
  content.write_string(" +0000\n")
  content.write_string("committer ")
  content.write_string(author)
  content.write_string(" ")
  content.write_string(timestamp.to_string())
  content.write_string(" +0000\n")
  content.write_string("\n")
  content.write_string(message)
  content.write_string("\n")
  let content_bytes = string_to_bytes_local(content.to_string())
  write_object(fs, git_dir, "commit", content_bytes)
}

///|
/// HEAD（またはブランチ参照）を新しいコミットに更新
fn update_head_ref(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise SubdirError {
  let head_path = git_dir + "/HEAD"
  let head_bytes = rfs.read_file(head_path) catch {
    _ => raise IoError("failed to read HEAD")
  }
  let head_content = bytes_to_string_commit(head_bytes)
  // HEAD が "ref: refs/heads/..." 形式かチェック
  let trimmed = trim_head_content(head_content)
  if trimmed.has_prefix("ref: ") {
    // シンボリック参照の場合、参照先のファイルを更新
    let ref_path = skip_prefix_commit(trimmed, 5) // "ref: " を除去
    let ref_file = git_dir + "/" + ref_path
    // 親ディレクトリが存在することを確認
    let ref_dir = get_parent_dir(ref_file)
    fs.mkdir_p(ref_dir) catch {
      _ => ()
    }
    // 参照を更新
    let commit_hex = commit_id.to_hex() + "\n"
    fs.write_string(ref_file, commit_hex) catch {
      _ => raise IoError("failed to update ref")
    }
  } else {
    // detached HEAD の場合、HEAD を直接更新
    let commit_hex = commit_id.to_hex() + "\n"
    fs.write_string(head_path, commit_hex) catch {
      _ => raise IoError("failed to update HEAD")
    }
  }
}

///|
fn bytes_to_string_commit(data : Bytes) -> String {
  let result = StringBuilder::new()
  for b in data {
    result.write_char(b.to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn trim_head_content(s : String) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 0 && (chars[end - 1] == '\n' || chars[end - 1] == '\r') {
    end -= 1
  }
  let result = StringBuilder::new()
  for i = 0; i < end; i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
fn skip_prefix_commit(s : String, n : Int) -> String {
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
fn get_parent_dir(path : String) -> String {
  let chars = path.to_array()
  let mut last_slash = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '/' {
      last_slash = i
    }
  }
  if last_slash <= 0 {
    return "/"
  }
  let result = StringBuilder::new()
  for i = 0; i < last_slash; i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// インデックスを新しいコミットに合わせて更新
fn update_index_from_commit(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise SubdirError {
  let db = @lib.ObjectDb::load(rfs, git_dir) catch {
    _ => raise IoError("failed to load object db")
  }
  let files = @lib.collect_tree_files_from_commit(db, rfs, commit_id) catch {
    _ => raise IoError("failed to collect tree files")
  }
  let entries = @lib.tree_files_to_index(db, rfs, files) catch {
    _ => raise IoError("failed to convert to index entries")
  }
  @lib.write_index_entries(fs, git_dir, entries) catch {
    _ => raise IoError("failed to write index")
  }
}
