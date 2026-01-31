///|
/// SubdirRepo - サブディレクトリを独立リポジトリのように扱う
///
/// Git リポジトリの特定サブディレクトリを、擬似的な独立リポジトリとして操作できる。
/// - サブディレクトリがルートとして見える
/// - そのディレクトリに影響するコミット履歴のみを表示
/// - 変更をコミットすると元リポジトリに反映
pub struct SubdirRepo {
  /// 元リポジトリの .git ディレクトリ
  git_dir : String
  /// サブディレクトリパス（正規化済み、例: "src/lib"）
  subdir_path : String
  /// 現在のベースコミット
  current_commit : @git.ObjectId?
  /// サブディレクトリのツリーID
  subdir_tree : @git.ObjectId?
  /// 仮想ファイルシステム（サブディレクトリがルートとして見える）
  gitfs : @gitfs.GitFs
  /// 設定
  config : SubdirConfig
}

///|
/// サブディレクトリに影響するコミット情報
pub struct SubdirCommit {
  /// 元のコミットID
  id : @git.ObjectId
  /// このコミットでのサブディレクトリのツリーID
  subdir_tree : @git.ObjectId
  /// コミットメッセージ
  message : String
  /// 作者
  author : String
  /// タイムスタンプ
  timestamp : Int64
  /// サブディレクトリ履歴での前のコミット（サブディレクトリを変更した直前のコミット）
  prev_commit : @git.ObjectId?
}

///|
/// サブディレクトリリポジトリの設定
pub struct SubdirConfig {
  /// ワークツリーを展開する場所（None の場合は展開しない）
  worktree_path : String?
  /// 履歴を追跡するか
  track_history : Bool
}

///|
/// デフォルト設定を作成
pub fn SubdirConfig::default() -> SubdirConfig {
  { worktree_path: None, track_history: true }
}

///|
/// 差分エントリ
pub enum DiffEntry {
  Added(String, @git.ObjectId)
  Modified(String, @git.ObjectId, @git.ObjectId)
  Deleted(String, @git.ObjectId)
}

///|
pub fn DiffEntry::path(self : DiffEntry) -> String {
  match self {
    Added(path, _) => path
    Modified(path, _, _) => path
    Deleted(path, _) => path
  }
}

///|
pub fn DiffEntry::to_string(self : DiffEntry) -> String {
  match self {
    Added(path, _) => "A " + path
    Modified(path, _, _) => "M " + path
    Deleted(path, _) => "D " + path
  }
}

///|
/// サブディレクトリ関連のエラー
pub suberror SubdirError {
  SubdirNotFound(String)
  InvalidPath(String)
  CommitNotFound(@git.ObjectId)
  TreeNotFound(@git.ObjectId)
  IoError(String)
}

///|
pub fn SubdirError::to_string(self : SubdirError) -> String {
  match self {
    SubdirNotFound(path) => "subdirectory not found: " + path
    InvalidPath(path) => "invalid path: " + path
    CommitNotFound(id) => "commit not found: " + id.to_hex()
    TreeNotFound(id) => "tree not found: " + id.to_hex()
    IoError(msg) => "io error: " + msg
  }
}

///|
/// サブディレクトリ初期化の設定
pub struct SubdirInitConfig {
  /// git ラッパースクリプトを生成するか
  create_wrapper : Bool
  /// .gitsubdir ファイルに追加情報を書き込むか
  verbose_marker : Bool
}

///|
pub fn SubdirInitConfig::default() -> SubdirInitConfig {
  { create_wrapper: true, verbose_marker: true }
}

///|
pub fn SubdirInitConfig::new(
  create_wrapper? : Bool = true,
  verbose_marker? : Bool = true,
) -> SubdirInitConfig {
  { create_wrapper, verbose_marker }
}

///|
/// 初期化済みサブディレクトリの情報
pub struct SubdirInfo {
  /// サブディレクトリパス（正規化済み）
  path : String
  /// 元リポジトリの .git ディレクトリ
  git_dir : String
  /// 設定ファイルパス
  config_path : String
  /// 初期化済みかどうか
  initialized : Bool
}
