# bit - AI サンドボックスのための Git 実装

## What's this

git 互換の blob 操作 + 独自の拡張を施した VCS です。

Rust で git を書き直した gitoxide の MoonBit 版のような位置づけですが、AI 用のサンドボックスとして設計しています。

MoonBit で書いていますが、バイナリを Mac/Linux 向けに配布しています。

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/bit/main/install.sh | bash
```

> **Warning**: 実験的な実装です。本番環境では使わないでください。最悪の場合、データが破損する可能性があります。

## Why bit

- **WASI サンドボックス / インメモリ対応**: バックエンドに任意のストレージを持てます。ブラウザ上や WASM 環境で動作可能
- **サブディレクトリチェックアウト**: svn などにあった機能。モノレポの一部だけを独立したリポジトリとして扱える
- **bit/x/fs**: Git blob をバックエンドにした仮想ファイルシステム
- **bit/x/kv**: P2P 同期可能な分散 KV ストア

## Subdirectory Clone

大規模なモノレポで、一部のディレクトリ以下だけほしい時があります。いまの git は sparse-checkout や `--depth=1` の shallow clone などがありますが、任意のサブディレクトリをルートにとって解決することができません。

```
modules/
  foo/
  bar/
```

git だとこの `foo` だけをルートディレクトリとして取り出すことはできません。hg や svn ならできたんですが...

というわけで、まずこれを実装しました。

```bash
# mizchi/bit の src/x/fs だけを取り出す
$ bit clone mizchi/bit:src/x/fs
$ cd fs
$ ls
fs.mbt  types.mbt  ...
```

`@<ref>` を付けるとブランチ/コミットを指定できます（short-hash も可）。

```bash
# ブランチ指定
$ bit clone mizchi/bit@main:src/x/fs

# コミット指定 (short-hash OK)
$ bit clone mizchi/bit@<commit>:src/x/fs
```

GitHub の URL をそのまま貼り付けることもできます。

```bash
# ブラウザで開いてる URL をそのままコピペ (tree はサブディレクトリ)
$ bit clone https://github.com/user/repo/tree/main/packages/core

# blob は単一ファイル取得
$ bit clone https://github.com/user/repo/blob/main/README.md
```

明示的に `subdir-clone` を使うこともできます。

```bash
$ bit subdir-clone https://github.com/user/repo src/lib mylib
```

クローン先はパス末尾の名前になります。必要なら `bit clone <src> <dest>` で明示的に指定できます。

これは双方向に動作します。つまり、`fs` で編集して `bit push` すると、元のリポジトリに変更が反映されます。

```bash
cd fs
echo "// new code" >> fs.mbt
bit add .
bit commit -m "update"
bit push origin main  # 元の mizchi/bit に push される
```

### 親リポジトリとの共存

git から見たときは submodule と同じく embedded repository として認識されるので、親リポジトリから操作して不整合を起こすことはありません。

```bash
# 親リポジトリで git add すると
$ git add fs
warning: adding embedded git repository: fs
```

ただし、bit で checkout したディレクトリの内部で git コマンドを使って操作した場合の挙動は十分に検証できていません。初期化時に pre-commit hook を注入して操作を止めるようにしていますが、完全に不整合を排除できるかは未検証です。不整合を避けたいなら、AI に渡す環境では `git` を `bit` にエイリアスするのが安全でしょう。

## 実験的な機能: bit/x/fs

Git の blob をそのままファイルシステムのバックエンドに使う仮想ファイルシステムです。

```moonbit
let fs = Fs::from_commit(fs, ".git", commit_id)
let content = fs.read_file(fs, "src/main.mbt")  // blob を遅延読み込み
```

Nix のようにハッシュ値で任意の状態を復元できます。この FS 内ならどのような操作を加えても、任意の時点にロールバックすることができます。

最近だと AI エージェント自体がスナップショット機能を持っていることがありますが、これを Git プロトコルのレベルで保証します。つまり、エージェントのメモリ外にある永続化されたストレージとして使えます。

また、WASM/WASI で動くように設計しているので、これを AI 用のサンドボックスとして使うコーディングエージェントを今実装しているところです。

この FS 内部では blob の解決を遅延できるように設計しているので、大規模なリポジトリでも必要な部分だけを読み込む、といった使い方ができます。

## 実験的な機能: bit/x/kv

Git blob を特定の P2P ノード間で共有することを想定した KV ストアです。ブロックチェーンから着想しています。

```moonbit
let db = Kv::init(fs, fs, git_dir, node_id)
db.set(fs, fs, "users/alice/profile", value, ts)
db.sync_with_peer(fs, fs, peer_url)  // Gossip protocol で同期
```

何に使うかというと、多数の AI エージェントに特定の状態を基準にタスクを並列化させたとき、そのエージェント間で状態を高速に同期させる想定です。

## 実験実装: bit/x/hub

GitHub/GitLab に依存しない、Git ネイティブなコラボレーション機能です。Pull Request / Issue は `refs/notes/bit-hub` に記録され、`bit hub sync push/fetch` で同期できます。

```moonbit
let hub = Hub::init(fs, fs, git_dir)
let pr = hub.create_pr(
  fs,
  fs,
  "Fix bug",
  "...",
  "refs/heads/feature",
  "refs/heads/main",
  "agent-a",
)
```

CLI では `bit hub pr/issue/note/sync` が利用でき、`bit agent` からもこの基盤を使って PR 作成・レビュー・マージを行えます。現状は実験段階で、`gh` 依存の import や CLI テストの拡充を進めています。

## Git テストスイート互換性

git 本体のテストスイート (git/t) 1,031 ファイルのうち 706 ファイルが allowlist に登録されています。

| | 件数 |
|---|---|
| テストファイル (allowlist) | 706 / 1,031 (68.5%) |
| サブテスト success | 24,278 |
| サブテスト failed | 0 |
| サブテスト broken (prereq skip) | 178 |

broken 178 件はテスト失敗ではなく、環境に依存する前提条件 (GPG 未インストール、Windows 専用テスト等) によるスキップです。

### allowlist 外のテスト (325 ファイル)

| カテゴリ | 未対応数 | 内容 |
|---|---|---|
| t9xxx (contrib) | 124 | git-p4, git-svn 等の外部連携。対応予定なし |
| t7xxx (porcelain) | 102 | stash, submodule, rebase -i 等の高レベルコマンド |
| t6xxx (rev-list) | 85 | rev-list, rev-parse, bisect, describe 等 |
| t5xxx (transport) | 5 | bitmap, multi-pack reuse, send-pack |
| t0xxx/t1xxx (basic) | 5 | cat-file, help 等 |

### 未対応のコマンド・機能

- **インタラクティブ系**: `bit add -p`、`bit rebase -i` — ターミナル UI の抽象化が未設計
- **GPG 署名**: `commit -S`、`tag -s` — 未実装
- **rev-list / rev-parse**: `bit rev-list`、`bit bisect`、`bit describe` 等の履歴探索系コマンド
- **submodule**: `bit submodule` 系の操作全般
- **send-pack**: `git push` のネイティブ Git プロトコル (HTTP push は対応済み)

### パフォーマンス

- `bit clone` は git の約 1.8 倍遅いです
- MoonBit がマルチスレッド対応してないため、packfile のデコーディングがボトルネックになっています

## リンク

- GitHub: https://github.com/mizchi/bit
- MoonBit: https://www.moonbitlang.com/
