# Agent System Extraction Proposal

## 問いの整理

1. agent 層を別リポジトリに切り出すべきか
2. moonix 上で shell エミュレーション環境を渡して作業させるべきか

## 現状の依存グラフ

```
src/x/agent/llm/          mizchi/llm (外部)
  coord.mbt                  @ffi.exec_sync (shell)
  orchestrator.mbt           @json
  runner.mbt                 @strconv
  tools.mbt
  ← git 層への依存: ZERO

src/x/agent/               mizchi/bit (本体)
  types.mbt                  @git.ObjectId (型のみ)
  workflow.mbt               &@lib.ObjectStore (trait)
  policy.mbt                 &@lib.RefStore (trait)
                             &@lib.Clock (trait)
                             &@lib.WorkingTree (trait)
                             @hub.Hub
  ← git 層への依存: trait 参照のみ、実装非依存

src/x/agent/native/        mizchi/bit (本体)
  runner.mbt                 @git.*, @lib.ObjectDb
  server.mbt                 @pack, @protocol, @gitnative
  ← git 層への依存: TIGHT (native adapter)
```

## 結論: 切り出すべき。ただし切り出し粒度が重要

### agent/llm は今すぐ切り出せる

`src/x/agent/llm/` は git 層への依存がゼロ。依存は `mizchi/llm` (外部 LLM ライブラリ) とシェルコマンドのみ。これは独立パッケージとして成立する。

問題は **tools.mbt が raw shell で全てやっている** こと:

```moonbit
// 現在の tools.mbt — shell_escape + exec で直接操作
fn(input) {
  let path = resolve_path(work_dir, json_get_str(input, "path"))
  exec("cat " + shell_escape(path))
}
```

これは:
- セキュリティリスク (command injection の表面積が大きい)
- テスト不能 (実際のファイルシステムが必要)
- 環境依存 (macOS/Linux のコマンド差異)
- リプレイ不能 (実行は不可逆)

### agent/core は hub protocol 確定後に切り出せる

`src/x/agent/` の `workflow.mbt` と `policy.mbt` は trait 経由で git 層を使う。依存は:

- `@git.ObjectId` — 型のみ
- `&@lib.ObjectStore` / `&@lib.RefStore` / `&@lib.WorkingTree` / `&@lib.Clock` — trait 参照
- `@hub.Hub` — hub API

hub protocol が安定すれば、trait 定義とともに切り出せる。

### hub protocol の未確定事項

| 項目 | 影響 | 優先度 |
|------|------|--------|
| Vector clock merge semantics | 分散同期の正しさ | CRITICAL |
| Note commit timestamp (現在 0L 固定) | causality tracking | CRITICAL |
| PR source_commit の post-merge semantics | merge 後の状態管理 | HIGH |
| Tombstone compaction policy | ストレージ肥大化 | MEDIUM |
| Close vs Rejected 区別 | ワークフロー設計 | LOW |

## moonix をエージェント実行環境にすべきか: YES

### moonix が提供するもの

```
AgentRuntime
  ├── GitBackedFs (snapshot/rollback 付き仮想FS)
  ├── CapabilitySet (FsRead, FsWrite, NetConnect... ACL)
  ├── EffectLog (不可逆操作の監査ログ)
  ├── POSIX context (fd, env, cwd)
  ├── MCP client/server (ツール呼び出しプロトコル)
  └── A2A protocol (エージェント間通信)
```

### 現在の agent/llm vs moonix 上の agent

| 観点 | 現在 (shell 直叩き) | moonix 上 |
|------|-------------------|-----------|
| ファイル操作 | `exec("cat ...")` | `runtime.fs.read_file(path)` |
| 書き込み | `exec("printf ... > ...")` | `runtime.fs.write_file(path, data)` |
| スナップショット | git worktree + 手動 commit | `runtime.snapshot("checkpoint")` |
| ロールバック | 不可能 (worktree 削除のみ) | `runtime.rollback(commit_id)` |
| 権限制御 | なし | Capability-based ACL |
| 監査ログ | なし | EffectLog (全外部操作を記録) |
| テスト | 実 FS 必要 | MemFs でユニットテスト可能 |
| 並列エージェント | worktree 分離 | fork() で分岐 |
| セキュリティ | shell injection リスク | sandbox mode |

### moonix を使うと orchestration が根本的に変わる

現在のモデル:

```
Orchestrator (プロセス)
  ├── nohup bit agent llm ... &   ← OS プロセス spawn
  ├── coordination dir polling     ← ファイルシステム polling
  └── git merge                    ← shell command
```

moonix モデル:

```
Orchestrator (in-process)
  ├── runtime_0 = AgentRuntime::sandbox()
  │     runtime_0.fs = GitBackedFs (agent-0 の作業空間)
  ├── runtime_1 = AgentRuntime::sandbox()
  │     runtime_1.fs = GitBackedFs (agent-1 の作業空間)
  ├── 各 runtime に LLM agent loop を実行
  │     tool_call("write_file", ...) → runtime.fs.write_file(...)
  │     tool_call("read_file", ...)  → runtime.fs.read_file(...)
  │     tool_call("run_command", ...) → runtime.effect_log.record(...)
  ├── snapshot per step (自動)
  │     runtime.snapshot("step-3")
  ├── エラー時 rollback
  │     runtime.rollback(last_good_snapshot)
  └── merge: GitBackedFs 同士の 3-way merge
```

利点:
- **OS プロセス spawn 不要** — in-process で並列実行可能
- **coordination dir 不要** — runtime の状態を直接参照
- **snapshot/rollback が組み込み** — エージェントの試行錯誤が安全
- **fork で探索** — 複数アプローチを分岐して比較可能
- **EffectLog** — 外部 API 呼び出しの完全な監査証跡
- **Capability** — エージェントごとに権限を制限可能

### shell emulation について

moonix の shell parser は完成しているが **実行エンジンが xsh 待ちで disabled**。

2つの選択肢:

**A. shell emulation を待つ**
- `run_command` ツールが moonix 内で完結
- エージェントが `moon test` や `rg` を仮想シェルで実行
- 完全なサンドボックス

**B. shell は host delegation で先に進む**
- `run_command` は capability-gated で host の shell に委譲
- EffectLog に記録 (ProcessSpawn effect)
- moonix の FS 操作 + snapshot/rollback は使う
- shell emulation は後から差し替え

推奨: **B**。shell emulation の完成を待つと agent 開発がブロックされる。host delegation + EffectLog で十分な監査は可能。

## 提案するアーキテクチャ

### パッケージ構成

```
mizchi/bit                    # git 互換実装 (現在のまま)
  src/
  src/x/hub/              # hub protocol
  src/x/kv/                  # KV store + gossip

mizchi/moonix                 # 仮想実行環境 (現在のまま)
  src/runtime/
  src/gitfs/
  src/capability/
  src/effect/
  src/ai/                    # MCP, A2A types

mizchi/bit-agent (NEW)        # エージェントシステム
  src/
    core/                    # AgentConfig, AgentTask, TaskResult
    llm/                     # LLM providers, agent loop
    tools/                   # MCP-compatible tool definitions
    orchestrator/            # 並列 orchestration
    coord/                   # coordination protocol
  依存:
    mizchi/moonix            # 実行環境 (AgentRuntime, GitBackedFs)
    mizchi/llm               # LLM プロバイダ
    mizchi/bit               # (optional) native git adapter
    mizchi/bit/x/hub      # (optional) PR/review integration
```

### ツール定義の変更

現在 (`shell_escape + exec`):
```moonbit
registry.register("read_file", ..., fn(input) {
  exec("cat " + shell_escape(path))
})
```

moonix 上:
```moonbit
registry.register("read_file", ..., fn(input) {
  let bytes = runtime.fs.read_file(path)  // raise FsError
  @encoding.bytes_to_string(bytes)
})
```

### coordination の変更

現在 (ファイルシステム polling):
```moonbit
coord_write_status(dir, agent_id, Running)
// → printf 'running' > /tmp/.../agents/agent-0/status
```

moonix 上 (in-memory 直接参照):
```moonbit
// orchestrator が各 runtime の状態を直接持つ
agents[i].status = Running
agents[i].step = runtime.current_step()
agents[i].snapshot = runtime.fs.head()
```

coordination dir が不要になり、KV への移行パスも明確になる:
- ローカル: in-memory Map
- 分散: KV gossip

## 移行ステップ

### Phase 0: hub protocol 確定
- Vector clock merge semantics を仕様化
- Note timestamp 問題を解決
- `docs/hub-protocol.md` に contract を文書化

### Phase 1: moonix に agent tool adapter を追加
- `mizchi/moonix/src/ai/tools/` に MCP-compatible ツール定義
- `read_file`, `write_file`, `list_directory` → `runtime.fs.*`
- `run_command` → host delegation + EffectLog
- `search_text` → host delegation (rg) or in-memory grep

### Phase 2: bit-agent リポジトリ作成
- `src/x/agent/llm/` を移動
- tools.mbt を moonix adapter に差し替え
- runner.mbt の shell exec を `AgentRuntime` 経由に変更
- orchestrator を in-process 並列に書き換え

### Phase 3: coordination を KV 互換に
- in-memory coordination (ローカル)
- KV gossip coordination (分散)
- hub integration (PR/review)

## まとめ

| 判断 | 結論 | 理由 |
|------|------|------|
| agent を別リポに切り出すか | YES | llm 層は git 依存ゼロ、core 層は trait のみ |
| moonix 上で動かすか | YES | sandbox, snapshot/rollback, EffectLog, capability |
| shell emulation を待つか | NO | host delegation で先に進む |
| hub 確定が先か | YES | agent の workflow/policy が hub に依存 |
| いつ切り出すか | Phase 0 (hub) → Phase 1 (moonix tools) → Phase 2 (extract) |
