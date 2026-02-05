# Pure Implementation Plan (gitoxide-style modularization)

## 目的

- CLI 以外のモジュールを **全ターゲット（js/wasm/wasm-gc/native）で pure に動作**させる。
- 依存境界を **最小インターフェース**に絞り、gitoxide 風の分割構成にする。
- `bit/x/fs` は **target-agnostic を目指す**（現状が native-only に見えていても前提にしない）。

---

## 前提（bitfs 計画を反映）

- `bit/x/fs` は Git 最適化 FS として **target-agnostic** を目標にする。
- Moonix では `RepoFileSystem` / `FileSystem` を適合させる adapter を用意。
- WASI / native 依存は adapter 側に閉じ、bitfs 側は Git 互換を優先。

---

## 目標アーキテクチャ（gitoxide 風）

### Pure Core（IOなし）

- `bit/core/object` : blob/tree/commit/tag の parse/serialize
- `bit/core/pack` : packfile 読み書き・delta
- `bit/core/refs` : ref 解析、packed-refs
- `bit/core/revwalk` : DAG walk
- `bit/core/index` : index 読み書き
- `bit/core/protocol` : upload-pack / receive-pack メッセージ

### 最小インターフェース（lib の境界）

以下のみを core が依存するように設計する。

```
ObjectStore:
  get(id) -> GitObject?
  put(obj_type, bytes) -> ObjectId
  has(id) -> Bool

RefStore:
  resolve(ref_name) -> ObjectId?
  update(ref_name, id) -> Unit
  list(prefix) -> Array[String]

Clock:
  now() -> Int64

Random:
  short() -> String

Transport:
  fetch(remote, wants) -> Pack
  push(remote, updates) -> Result
```

※ Worktree / OS / HTTP / process は core に置かない。

---

## Adapters（CLI / 実行環境専用）

bitfs 計画に従い、実行環境依存の実装は adapter に閉じ込める。

- `bit/adapters/bitfs_native` : ObjectStore/RefStore 実装（必要に応じて）
- `bit/adapters/transport_http_native`
- `bit/adapters/transport_process_native`
- `bit/adapters/clock_native`
- `bit/adapters/random_native`

CLI (`cmd/bit`) がこれらを組み立てて core に注入する。

---

## 依存グラフ（目標）

```
core (pure)
  ↑
lib (pure: traits + algorithms)
  ↑
x/collab (pure) / x/kv (pure)
  ↑
adapters/bitfs_native (native-only)
  ↑
cmd/bit (native-only)
```

`bit/x/fs` は可能な限り pure / target-agnostic を維持。

---

## 具体的な移行ステップ

### Step 1: lib の API 境界を抽象化

- `src/lib` に **trait/record 定義**を追加（`ObjectStore`, `RefStore`, `Transport`, `Clock`, `Random`）。
- `EnvProvider` を追加し、環境変数/カレントディレクトリ取得を **注入可能**にする。
- `src/lib/moon.pkg` から native import を 제거:
  - `moonbitlang/async/process`
  - `moonbitlang/x/sys`
  - `moonbitlang/core/env`
  - `moonbitlang/async/http`
  - `moonbitlang/async/fs` は `worktree` / `gitignore` の抽象化後に 제거予定
- native 専用実装は `src/lib/native` に移動。

### Step 2: `x/collab` を pure に

- `CollabStore` を `ObjectStore + RefStore + Clock` だけに依存させる。
- notes backend は ref/objects 経由で動作させる。

### Step 2.5: `worktree` / `gitignore` の async/fs 依存を抽象化

- `worktree_probe` と `list_working_files` を target 依存層へ寄せる。
- cache/mtime など OS 依存は adapter 側に閉じる。

### Step 3: `x/kv` を pure に

- `x/fs` 依存を 제거し、`ObjectStore + TreeBuilder` のみで commit 生成。
- sync/merge は純粋に tree 操作で実装。

### Step 4: transport を純/不純に分割

- protocol (pack format / msg) は pure に集約。
- http/process は adapter。

---

## 優先順位

1. lib の境界抽象化（最小 interface 定義）
2. x/collab の pure 化
3. x/kv の pure 化
4. transport の分離

---

## リスクと留意点

- `bit/x/fs` に依存する箇所は **pure 側に置かない**。
- `ObjectStore` の責務は **Git object read/write の最小化**に限る。
- 追加の IO 要求は **adapter に閉じ込める**。

---

## 検証方針

- core: 既存テストを JS/wasm で通す
- adapter: native テストのみ
- CLI: e2e は native のみ

---

## 注記

この計画は `../mizchi/moonix/docs/bitfs.md` の方針と整合するように設計している。
