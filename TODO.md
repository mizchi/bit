# moongit TODO (updated 2026-02-07)

## 現在のステータス

| Metric | Value |
|--------|-------|
| MoonBit tests | 617 passing |
| Git compatibility | 95.5% (744/779) |
| Allowlist pass | 97.7% (4650/4760) |
| Pure化 coverage | ~85% |
| CI | 5 shards all green |

## Tier 1: Git Compatibility (Critical)

allowlist で残っている 5 テスト:
- [ ] **t5310**: bitmap repack handling
- [ ] **t5316**: delta depth reuse
- [ ] **t5317**: filter-objects delta
- [ ] **t5332**: multi-pack index reuse
- [ ] **t5400**: send-pack collision detection

関連タスク:
- [ ] pack/midx/bitmap/repack の整合性修正
- [ ] 破損検出の回帰テスト追加
- [ ] allowlist 再計測（t5xxx 拡張後）

## Tier 2: Agent Features (High)

- [ ] **MCP server dispatch**: run_agent/orchestrate ツール呼び出しの実装完了 (`src/x/agent/mcp/server.mbt`)
- [ ] **MCP streaming**: 長時間実行エージェントの出力をクライアントにストリーミング
- [ ] **Process agent signal handling**: タイムアウト/キャンセル時のクリーンアップ改善
- [ ] **Agent output capture**: ProcessAgentRunner の per-agent stdout 取得

## Tier 3: Enhancements (Medium)

- [ ] Promisor protocol v2 エッジケース (t0411)
- [ ] Protocol v2 edge cases (t5510, t5616)
- [ ] cat-file batch/unordered (t1006)
- [ ] help/doc formatting (t0012, t0450)

## Tier 4: Future (Low)

- [ ] **Moonix integration**: ToolEnvironment <-> AgentRuntime (moonix release 待ち)
- [ ] **Git-Native PR System**: src/x/collab の persistence 実装 (後述)
- [ ] bit mount / bit jj / .bitignore / BIT~ 環境変数
- [ ] scalar/git-shell 未実装 (t9210/t9211, t9850)

## 完了した項目

### ✅ Agent E2E テスト + パッケージ独立化 + run_agent async 化 (2026-02-07)

- BitKvAdapter を `src/x/agent/llm/adapter/` に分離、親パッケージから `@kv/@git/@lib/@utf8` 依存削除
- LlmAgentConfig に provider DI (`BoxedProvider?`) 追加
- E2E テスト 5 件 (read/write, max_steps, loop detection, coordination, no_tool_calls)
- mizchi/llm に pub MockProvider + run_agent_cancellable 追加
- run_llm_agent に should_cancel パラメータ追加、InProcessAgentRunner にキャンセルフラグ

### ✅ Agent Inner Loop 改善 + Orchestrator リファクタ (2026-02-07)

- 5-phase system prompt、LoopTracker (連続検出+進捗検出)
- SubtaskPlan (task + files スコープ)、AgentRunner trait 抽象化
- KvCoordinationBackend + KvStore trait

### ✅ Agent trait 抽象化 + Collab protocol 修正 (2026-02-07)

- ToolEnvironment trait + CoordinationBackend trait
- CollabRecord.version + PullRequest.merge_commit
- Clock trait dependency injection

### ✅ t5xxx allowlist 拡張 (2026-02-06)

- 70 → 166/171 (97.1%) テスト拡張
- 96 テスト新規追加、10 テスト復活

### ✅ PromisorDb pure化 + x/fs, x/subdir pure化 (2026-02-06)

- PromisorDb, x/fs (~3,690 LOC), x/subdir (~4,878 LOC) を pure化

### ✅ Protocol v2 filter/packfile-uris 対応 (2026-02-01)

**修正済み:**
- `src/cmd/bit/pack_objects.mbt`: `--filter` オプション対応 (blob:none, blob:limit, tree:depth)
- `src/cmd/bit/handlers_remote.mbt`: `GIT_CONFIG_OVERRIDES` 環境変数からの設定読み込み
- `src/lib/upload_pack.mbt`: filter spec のパースと適用

**テスト結果:**
- t5702-protocol-v2.sh テスト 42 (filter): パス
- t5702-protocol-v2.sh テスト 60 (packfile-uris): パス

### ✅ `-h` オプション対応

**修正済み:** `src/cmd/moongit/handlers_remote.mbt`
- `receive-pack -h` → usage を stdout に出力、exit code 129
- `upload-pack -h` → usage を stdout に出力、exit code 129

### ✅ git-shim `-c` オプション修正

**修正済み:** `tools/git-shim/bin/git`
- `git branch -c` が config オプションとして誤認識される問題を修正
- サブコマンド検出後のみ `-c` 検証を行うように変更

### ✅ CRC32 バグ修正 (2026-02-01)

**修正済み:** pack ファイルの CRC32 計算が正しく動作するよう修正

### ✅ index-pack SHA1 collision detection 対応 (2026-02-01)

**修正済み:** pack 解析時に SHA1 collision を検出して失敗するよう修正

---

## 追加タスク（メモ）

- [ ] bit mount: ファイルシステムにマウントする機能
- [ ] bit mcp: MCP 対応
- [ ] gitconfig サポート
- [ ] BIT~ 環境変数の対応
- [ ] .bitignore 対応
- [ ] .bit 対応
- [ ] bit jj: jj 相当の対応

---

## 新機能: Git-Native PR システム (src/x/collab)

**計画ファイル:** `~/.claude/plans/lexical-beaming-valley.md`

GitHub/GitLab に依存しない、Git ネイティブな Pull Request システム。
専用ブランチ `_prs` に全 PR データを Git オブジェクト（blob/tree）として保存し、標準の fetch/push で同期。

### 実装ステップ

- [ ] **Step 1: 基盤 (types.mbt, format.mbt)**
  - 型定義 (PullRequest, PrComment, PrReview, PrState, ReviewVerdict)
  - Git スタイルテキストのシリアライズ/パース

- [ ] **Step 2: PR 操作 (pr.mbt)**
  - PrSystem 構造体
  - create, get, list, close

- [ ] **Step 3: コメント・レビュー (comment.mbt, review.mbt)**
  - add_comment, list_comments
  - submit_review, is_approved

- [ ] **Step 4: マージ (merge.mbt)**
  - can_merge, merge_pr
  - 既存の src/lib/merge.mbt を活用

- [ ] **Step 5: 同期 (sync.mbt)**
  - push, fetch
  - conflict resolution

### ファイル構成

```
src/x/collab/
├── moon.pkg.json
├── types.mbt          # 型定義
├── format.mbt         # シリアライズ/デシリアライズ
├── pr.mbt             # PrSystem, create/list/show/close
├── comment.mbt        # コメント操作
├── review.mbt         # レビュー操作
├── merge.mbt          # PR マージ
├── sync.mbt           # fetch/push 同期
└── pr_test.mbt        # テスト
```

### 検証方法

```bash
moon check
moon test --target native -p mizchi/git/x/collab
```
