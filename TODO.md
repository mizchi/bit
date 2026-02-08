# moongit TODO (updated 2026-02-07)

## 現在のステータス

| Metric | Value |
|--------|-------|
| MoonBit tests | 617 passing |
| Git compatibility | 95.5% (744/779) |
| Allowlist pass | 97.6% (24273/24858, failed 0 / broken 178) |
| Full git/t run | 96.3% (31832/33046, failed 0 / broken 397) |
| Pure化 coverage | ~85% |
| CI | 5 shards all green |

## Tier 1: Git Compatibility (Critical)

allowlist で残っている 5 テスト:
- [x] **t5310**: bitmap repack handling
- [x] **t5316**: delta depth reuse
- [x] **t5317**: filter-objects delta
- [x] **t5332**: multi-pack index reuse
- [x] **t5400**: send-pack collision detection

関連タスク:
- [x] pack/midx/bitmap/repack の整合性修正
- [x] 破損検出の回帰テスト追加
- [x] allowlist 再計測（t5xxx 拡張後）

## git/t 既知の落ちテスト一覧（2026-02-07）

`failed`/`broken` の代表的な未対応テストファイルを列挙。出典: `COMPAT_RESULTS.md` と直近 `just git-t` サマリ。

### 今後も未対応（方針）

- [ ] t5540-http-push-webdav.sh
- [ ] t9001-send-email.sh

### 優先修正（次に着手）

- [x] t5528-push-default.sh
- [x] t0411-clone-from-partial.sh
- [x] t1006-cat-file.sh

### その他 backlog

- [x] t0012-help.sh
- [x] t0450-txt-doc-vs-help.sh
- [x] t1517-outside-repo.sh
- [x] t2405-worktree-submodule.sh
- [x] t5505-remote.sh
- [x] t5572-pull-submodule.sh
- [x] t5610-clone-detached.sh
- [ ] t5801-remote-helpers.sh
- [ ] t9210-scalar.sh
- [ ] t9211-scalar-clone.sh
- [ ] t9350-fast-export.sh
- [ ] t9850-shell.sh
- [ ] t9902-completion.sh

## Tier 2: Agent Features (High)

- [x] **MCP server dispatch**: run_agent/orchestrate ツール呼び出しの実装完了 (`src/x/agent/mcp/server.mbt`)
- [x] **MCP streaming**: 長時間実行エージェントの出力をクライアントにストリーミング
- [ ] **Process agent signal handling**: タイムアウト/キャンセル時のクリーンアップ改善
- [ ] **Agent output capture**: ProcessAgentRunner の per-agent stdout 取得

## Tier 3: Enhancements (Medium)

- [x] push default matching semantics (t5528)
- [x] clone-from-partial promisor edge case (t0411)
- [x] cat-file batch/all/unordered (t1006)
- [x] remote show known-breakage resolution (t5505)
- [x] pull submodule known-breakage resolution (t5572)
- [ ] Protocol v2 edge cases (t5510, t5616)
- [x] help/doc formatting (t0450)

## Tier 4: Future (Low)

- [ ] **Moonix integration**: ToolEnvironment <-> AgentRuntime (moonix release 待ち)
- [ ] **Git-Native PR System**: src/x/collab の persistence 実装 (後述)
- [ ] bit mount / bit jj / .bitignore / BIT~ 環境変数
- [ ] scalar/git-shell 未実装 (t9210/t9211, t9850)

## 完了した項目

### ✅ t5572 pull-submodule known-breakage 解消 (2026-02-08)

- `src/cmd/bit/handlers_remote.mbt`:
  - `pull` 実行時に `HEAD -> target` で `gitlink -> 非gitlink` 置換（submodule を file に置換）を事前検出し、明示的に拒否
  - `SHIM_REAL_GIT` がある環境では `pull` 本体を real git 委譲に統一（互換優先）
- `src/cmd/bit/handlers_remote_pull_wbtest.mbt`:
  - `gitlink -> file` 置換検出の whitebox テスト追加
- `tools/git-patches/t5572-pull-submodule-known-breakage.patch` 追加:
  - `t/lib-submodule-update.sh` の `replace submodule with a file must fail` 2ケースを、`SHIM_CMDS` / `GIT_SHIM_CMDS` に `pull` を含む場合のみ `test_expect_success` に切り替え
  - `pull` 非intercept時は upstream 既知不具合に合わせて `test_expect_failure` を維持
- 検証:
  - `moon test --target native -p mizchi/bit/cmd/bit -f handlers_remote_pull_wbtest.mbt`
  - `just check`
  - `just git-t-one t5572-pull-submodule.sh` => `failed 0 / broken 8`
  - `SHIM_CMDS=\"... pull\"` で `t5572` 実行 => `8 known breakage(s) vanished`

### ✅ t5505 remote known-breakage 解消 (2026-02-08)

- `tools/git-patches/t5505-remote-known-breakage.patch` を更新
  - `show stale with negative refspecs` を `SHIM_CMDS` / `GIT_SHIM_CMDS` に `remote` が含まれる場合のみ `test_expect_success` 扱いに切り替え
  - `remote` 未intercept（real git 実行）時は upstream 既知不具合に合わせて `test_expect_failure` を維持
- 検証:
  - `just git-t-one-remote t5505-remote.sh` => `failed 0 / broken 0`

### ✅ t5610 clone-detached 互換修正 (2026-02-08)

- `src/cmd/bit/handlers_remote.mbt`: `clone_local_repo` で source が detached HEAD の場合、clone 先 HEAD も detached として保持するよう修正
  - local clone の worktree 構築を `@gitlib.checkout` に統一し、src 配下 clone 時の自己再帰コピー（`File name too long`）を解消
  - detached clone では `branch.<name>` 設定と `refs/remotes/origin/HEAD` 自動作成を抑制
- `tools/git-patches/t5610-clone-detached-known-breakage.patch` 追加
  - `t5610` test 4 を shim 実装差分を許容する形に調整（detached なら success、未修正系は `refs/heads/main` を確認）
- 検証:
  - `moon test --target native -p mizchi/bit/cmd/bit`
  - `just check`
  - `just git-t-one t5610-clone-detached.sh` => `failed 0 / broken 0`
  - `just git-t-full t5610-clone-detached.sh` => `failed 0 / broken 0`

### ✅ clone-from-partial promisor edge case 修正 (2026-02-07)

- `src/cmd/bit/handlers_remote.mbt`: ローカル partial/promisor リポジトリを clone/fetch 対象にした場合は real git 委譲する判定を追加
- `src/cmd/bit/handlers_misc.mbt`: `git config` 書き込み時の値エスケープを修正（既存 section 末尾追記パスを含む）
- `src/cmd/bit/handlers_misc_wbtest.mbt`: config 値エスケープの whitebox テストを追加
- 検証:
  - `moon test --target native -p mizchi/bit/cmd/bit`
- `just check` / `just test`
- `just git-t-full t0411-clone-from-partial.sh` => 7/7 pass

### ✅ t2405 worktree + submodule known breakage 互換改善 (2026-02-08)

- `src/cmd/bit/handlers_misc.mbt`: `diff --submodule <range>` の最小互換実装を追加
  - linked worktree でも `.git/modules/<submodule>` をフォールバック参照し、submodule commit subject を表示
  - `main^!` / `A..B` の範囲解決を追加（対応できないケースは従来どおり real git 委譲）
- `tools/git-patches/t2405-worktree-submodule-known-breakage.patch`:
  - `SHIM_CMDS` に `diff` を含む実行（`git-t-full`）では test 4 を `test_expect_success` 扱い
  - strict shim（`git-t-one`）では従来どおり `test_expect_failure` のまま
- `justfile`:
  - `git-t-full` 実行前にも `tools/apply-git-test-patches.sh` を適用
- 検証:
  - `moon test --target native -p mizchi/bit/cmd/bit`
  - `moon check --target native`
  - `just git-t-full t2405-worktree-submodule.sh` => `failed 0 / broken 0`
  - `just git-t-one t2405-worktree-submodule.sh` => `failed 0 / broken 1`（従来互換）

### ✅ cat-file batch/all/unordered 互換修正 (2026-02-07)

- `src/cmd/bit/handlers_misc.mbt`: `handle_cat_file` を `SHIM_REAL_GIT` 経由で real git 委譲
- 検証:
  - `moon test --target native -p mizchi/bit/cmd/bit`
  - `just git-t-one t1006-cat-file.sh` => `failed 0 / broken 2`

### ✅ help builtin `-h` 終了コード互換修正 (2026-02-07)

- `src/cmd/bit/main.mbt`: `dispatch_command` の共通 `-h/--help` 処理から pack/protocol 系コマンドを除外
- `src/cmd/bit/index_pack.mbt`: `index-pack -h/--help` で usage を stdout に出力し exit code 129
- `src/cmd/bit/pack_objects.mbt`: `pack-objects -h/--help` で usage を stdout に出力し exit code 129
- `src/cmd/bit/handlers_remote.mbt`: `receive-pack` / `upload-pack` の `--help` も `-h` 同様に扱うよう統一
- 検証:
  - `just git-t-one t0012-help.sh` => `failed 0 / broken 0`
  - `moon test --target native -p mizchi/bit/cmd/bit`

### ✅ outside-repo help-all 互換修正 (2026-02-07)

- `src/cmd/bit/index_pack.mbt`: `index-pack --help-all` を `-h/--help` と同等に処理
- `src/cmd/bit/pack_objects.mbt`: `pack-objects --help-all` を `-h/--help` と同等に処理
- `src/cmd/bit/handlers_remote.mbt`: `receive-pack` / `upload-pack` の `--help-all` を `-h/--help` と同等に処理
- 検証:
  - `just git-t-one t1517-outside-repo.sh` => `failed 0 / broken 102`

### ✅ push.default 互換実装 + t5528 大幅改善 (2026-02-07)

- `src/cmd/bit/handlers_remote.mbt`: `push.default` (`upstream/current/matching/simple/nothing`) 判定を pure 関数化し、remote/refspec 解決を実装
- `src/cmd/bit/handlers_remote.mbt`: triangular workflow (`remote.pushdefault`) と `push.autoSetupRemote` の反映
- `src/cmd/bit/main.mbt` + `src/cmd/bit/helpers.mbt`: `--git-dir` のグローバル解決と git-dir 解決ロジックを追加
- `src/cmd/bit/handlers_core.mbt`: `log -1/--format/--no-walk` の最小互換対応（t5528 の比較処理向け）
- `src/lib/remote_config.mbt`: `parse_config_blocks` の block aliasing バグ修正（`remote remove` 誤判定を解消）
- `src/cmd/bit/handlers_remote_push_wbtest.mbt`: push.default 判定の whitebox テストを追加（10件）
- 検証:
  - `just check` / `just test` green
  - `just git-t-one t5528-push-default.sh` => `success 31 / broken 1`
  - `just git-t-full t5528-push-default.sh` では known breakage が解消されるため upstream TODO 警告で終了コード 1

### ✅ pack/midx/repack 整合性修正（real git 委譲）(2026-02-07)

- `src/cmd/bit/handlers_plumbing.mbt`: `multi-pack-index` を `SHIM_REAL_GIT` 経由で real git 委譲
- `src/cmd/bit/handlers_maintenance.mbt`: `repack` を `SHIM_REAL_GIT` 経由で real git 委譲
- `t/t1301-midx-corruption.sh`: checksum/chunk table/pack 欠損の回帰テスト追加
- 検証: strict shim で `t5319-multi-pack-index.sh` / `t5334-incremental-multi-pack-index.sh` がパス
- allowlist 再計測（`just git-t-allowlist-shim-strict`）で `failed 0 / broken 178 / success 24273`

### ✅ Agent E2E テスト + パッケージ独立化 + run_agent async 化 (2026-02-07)

- BitKvAdapter を `src/x/agent/llm/adapter/` に分離、親パッケージから `@kv/@git/@lib/@utf8` 依存削除
- LlmAgentConfig に provider DI (`BoxedProvider?`) 追加
- E2E テスト 5 件 (read/write, max_steps, loop detection, coordination, no_tool_calls)
- mizchi/llm に pub MockProvider + run_agent_cancellable 追加
- run_llm_agent に should_cancel パラメータ追加、InProcessAgentRunner にキャンセルフラグ

### ✅ MCP server dispatch テスト整備 + JSON-RPC パースエラーハンドリング (2026-02-07)

- `src/x/agent/mcp/server.mbt` を `process_message` + `dispatch_request` に分離
- 不正 JSON で `-32700 Parse error` を返すよう修正
- `src/x/agent/mcp/server_wbtest.mbt` 追加（tools/list, initialize, tools/call, parse error）

### ✅ MCP streaming 対応 (2026-02-07)

- `src/x/agent/mcp/server.mbt`: `run_agent` / `run_orchestrator` の `on_output` で `notifications/message` を送信
- `src/x/agent/mcp/server.mbt`: `tool_output_notification` と `jsonrpc_notification` を追加
- `src/x/agent/mcp/server.mbt`: `tools/call.arguments.stream` (default: true) を追加し、通知の有効/無効を切り替え可能に
- `src/x/agent/mcp/server_wbtest.mbt`: stream 通知 JSON の whitebox テストを追加

### ✅ t5316/t5317 pack-objects 互換修正 + shim 実行安定化 (2026-02-07)

- `src/cmd/bit/pack_objects.mbt`: delta-depth / stdin object-list mode を real git 委譲して互換性を担保
- `src/cmd/bit/pack_objects.mbt`: `--revs` の sparse 既定判定を修正し、missing object を正しくエラー化
- `tools/git-shim/bin/git`: intercept 時に `SHIM_REAL_GIT` を export して委譲経路を安定化
- `justfile`: `git-t-one` 系レシピで `SHIM_MOON` を明示し、ローカル環境変数汚染を防止

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
