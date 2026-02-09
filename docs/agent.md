# bit agent - P2P Agent PR Huboration

AI エージェントが自律的に PR を作成・レビュー・マージする仕組み。

## 概要

`bit agent` は、bit の hub (PR/レビュー) 基盤の上に構築されたオーケストレーション層。エージェントがタスクを受け取り、ファイル編集 → コミット → PR 作成 → push という一連の流れを自動化する。また、polling daemon として動作し、他のエージェントが作成した PR を自動でレビュー・マージすることもできる。

```
Agent A: タスク実行 → PR 作成 → push
Agent B: fetch → PR 検証 → レビュー submit → auto-merge → push
```

## 前提条件

- `bit` がインストール済み
- リモートリポジトリが `bit receive-pack` を受け付けること（bit サーバーまたは git 互換サーバー）
- `bit hub init` 済みのリポジトリ

## セットアップ

```bash
# リポジトリを初期化
mkdir my-repo && cd my-repo
bit init
bit hub init

# リモートサーバーを起動（別ターミナル）
cd my-repo && bit receive-pack --http :8080
```

## コマンド

### `bit agent run` - タスク実行

JSON ファイルで定義されたタスクを実行し、PR を作成して push する。

```bash
bit agent run --task task.json --remote http://localhost:8080
```

#### タスク JSON フォーマット

```json
{
  "id": "fix-typo-001",
  "description": "Fix typo in README",
  "pr_title": "Fix typo in README.md",
  "pr_body": "Fixed a small typo in the introduction section.",
  "source_branch": "agent/fix-typo-001",
  "edits": [
    {
      "type": "write",
      "path": "README.md",
      "content": "# My Project\n\nThis is the corrected content.\n"
    },
    {
      "type": "delete",
      "path": "old-file.txt"
    }
  ]
}
```

| フィールド | 必須 | 説明 |
|---|---|---|
| `id` | yes | タスクの一意な ID |
| `description` | no | コミットメッセージに使われる説明 |
| `pr_title` | no | PR タイトル（デフォルト: id） |
| `pr_body` | no | PR 本文 |
| `source_branch` | no | ソースブランチ名（デフォルト: `agent/{id}`） |
| `edits` | no | ファイル編集の配列 |

edits の各要素:

| フィールド | 説明 |
|---|---|
| `type` | `"write"` または `"delete"` |
| `path` | ファイルパス |
| `content` | ファイル内容（`write` 時のみ） |

### `bit agent serve` - Polling Daemon

定期的にリモートから hub notes を fetch し、未レビューの PR を検証してレビューを submit する。`--auto-merge` を付けると、approved な PR を自動マージして push する。

```bash
bit agent serve \
  --remote http://localhost:8080 \
  --branch main \
  --validate "moon check" \
  --auto-merge \
  --interval 10000 \
  --agent-id "ci-bot"
```

| オプション | デフォルト | 説明 |
|---|---|---|
| `--remote <url>` | (必須) | リモートリポジトリの URL |
| `--branch <name>` | `main` | 対象ブランチ |
| `--validate <cmd>` | (なし) | PR 検証に使うシェルコマンド |
| `--auto-merge` | off | approved PR を自動マージ |
| `--interval <ms>` | `5000` | ポーリング間隔（ミリ秒） |
| `--agent-id <id>` | git author | エージェントの識別子 |

#### Daemon の動作サイクル

1. `hub_fetch` でリモートから notes を同期
2. Open な PR を一覧
3. 自分が author でない未レビューの PR に対して:
   - `--validate` コマンドを実行
   - exit 0 → Approved、それ以外 → RequestChanges としてレビュー submit
4. `--auto-merge` が有効なら、approved な PR をマージして push
5. `hub_push` で結果をリモートに同期
6. `--interval` ミリ秒待機して 1 に戻る

### `bit agent status` - ステータス表示

PR の一覧と承認状態を表示する。

```bash
bit agent status --remote http://localhost:8080
```

## 使用例: 2 エージェント間の自動コラボレーション

```bash
# ---- 共有リポジトリを準備 ----
mkdir shared && cd shared
bit init && bit hub init
# 初期コミットを作成
echo "# Project" > README.md
bit add README.md && bit commit -m "init"
# サーバー起動
bit receive-pack --http :8080 &

# ---- Agent A: タスクを実行 ----
cd /tmp && mkdir agent-a && cd agent-a
bit clone http://localhost:8080 .
bit hub init

cat > task.json << 'EOF'
{
  "id": "add-hello",
  "description": "Add hello.txt",
  "pr_title": "Add hello.txt",
  "pr_body": "Adds a greeting file",
  "source_branch": "agent-a/add-hello",
  "edits": [
    {"type": "write", "path": "hello.txt", "content": "Hello, World!\n"}
  ]
}
EOF

bit agent run --task task.json --remote http://localhost:8080 --agent-id agent-a
# => PR created: xxxx

# ---- Agent B: レビュー＆マージ ----
cd /tmp && mkdir agent-b && cd agent-b
bit clone http://localhost:8080 .
bit hub init

# 1回だけ poll して自動レビュー＋マージ
bit agent serve \
  --remote http://localhost:8080 \
  --validate "echo ok" \
  --auto-merge \
  --agent-id agent-b \
  --interval 999999  # Ctrl+C で止める

# ---- 結果確認 ----
cd /tmp/shared
bit agent status
# => xxxx [merged] [approved] Add hello.txt (by agent-a)
```

## アーキテクチャ

```
src/x/agent/              -- pure: workflow + policy
  types.mbt               -- AgentConfig, AgentTask, FileEdit, TaskResult, ReviewResult
  workflow.mbt             -- execute_task, check_and_merge
  policy.mbt              -- evaluate_validation, should_auto_review, submit_validation_review

src/x/agent/native/       -- native: I/O adapters
  runner.mbt              -- FsWorkingTree adapter, run_task, validate_pr
  server.mbt              -- poll_once, serve (polling daemon)

src/bit_cli/
  handlers_agent.mbt      -- CLI: bit agent run/serve/status
```

pure 層 (`src/x/agent/`) はファイルシステムやネットワークに依存せず、`&ObjectStore`, `&RefStore`, `&Clock`, `&WorkingTree` のトレイト参照のみに依存する。native 層がこれらの具体的な実装を注入する。

### 依存グラフ

```
src/x/agent/         → @git, @lib, @hub (pure)
src/x/agent/native/  → @agent, @hub_native, @bitfs, @osfs, @gitnative, @protocol, @pack (native)
src/bit_cli/          → @agent, @agent_native (native, handlers_agent.mbt only)
```

## 既存コンポーネントの再利用

| コンポーネント | 用途 |
|---|---|
| `x/hub` Hub | PR 作成・マージ・レビュー・承認チェック |
| `x/hub/native` hub_push/fetch | Notes の push/fetch |
| `x/fs` Fs | サンドボックスファイルシステム |
| `native` push | ブランチの push |
| `lib` ObjectStore/RefStore/Clock/WorkingTree | DI トレイト |
