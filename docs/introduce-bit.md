# bit - Git implementation for AI sandboxes

## What's this

A git-compatible VCS with blob operations plus some original extensions.

It is positioned like a MoonBit port of gitoxide (a Rust rewrite of git), but designed for AI sandboxes.

It is written in MoonBit and distributed as binaries for macOS/Linux.

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/bit/main/install.sh | bash
```

> **Warning**: Experimental. Do not use in production. Data loss is possible in the worst case.

## Why bit

- **WASI sandbox / in-memory support**: Backend storage is pluggable. Runs in browsers and WASM environments.
- **Subdirectory checkout**: A feature from svn/hg. Treat a subdirectory of a monorepo as an independent repo.
- **bit/x/fs**: Virtual filesystem backed by Git blobs.
- **bit/x/kv**: P2P-synced distributed KV store.

## Subdirectory Clone

In large monorepos, you often want only a subset of directories. Git has sparse-checkout and shallow clone, but it cannot treat an arbitrary subdirectory as the repository root.

```
modules/
  foo/
  bar/
```

Git cannot extract `foo` as a new root. (hg/svn could.)

So this is implemented as `bit clone` shorthand:

```bash
# extract only src/x/fs from mizchi/bit
$ bit clone mizchi/bit:src/x/fs
$ cd fs
$ ls
fs.mbt  types.mbt  ...
```

You can pin a branch/commit with `@<ref>` (short-hash allowed).

```bash
# branch
$ bit clone mizchi/bit@main:src/x/fs

# commit (short-hash OK)
$ bit clone mizchi/bit@<commit>:src/x/fs
```

You can also paste a GitHub URL directly.

```bash
# copy-paste browser URL (tree = subdirectory)
$ bit clone https://github.com/user/repo/tree/main/packages/core

# blob = single file download
$ bit clone https://github.com/user/repo/blob/main/README.md
```

You can use `subdir-clone` explicitly as well:

```bash
$ bit subdir-clone https://github.com/user/repo src/lib mylib
```

The destination name defaults to the last path component. Use `bit clone <src> <dest>` to override.

This is bidirectional: edit under `fs` and `bit push` will update the original repo.

```bash
cd fs
echo "// new code" >> fs.mbt
bit add .
bit commit -m "update"
bit push origin main  # pushes back to mizchi/bit
```

### Coexistence with the parent repo

From git's perspective, this is an embedded repository (like a submodule), so operations from the parent repo will not corrupt it.

```bash
# when you run git add from the parent
$ git add fs
warning: adding embedded git repository: fs
```

If you run git commands inside the subdir-clone, behavior is not fully validated. A pre-commit hook is injected to block operations, but total safety is unverified. If you want to avoid inconsistency in AI environments, alias `git` to `bit`.

## Experimental: bit/x/fs

A virtual filesystem backed by Git blobs.

```moonbit
let fs = Fs::from_commit(fs, ".git", commit_id)
let content = fs.read_file(fs, "src/main.mbt")  // lazy blob read
```

Like Nix, any state can be restored via hash. Within this FS, you can modify freely and roll back to any point.

Many AI agents already have snapshot features; this provides a guarantee at the Git protocol level. That is, you can use it as durable storage outside the agent's memory.

Blob resolution is lazy, so large repos can be accessed by reading only the needed parts.

## Experimental: bit/x/kv

A KV store intended for sharing Git blobs between P2P nodes. Inspired by blockchains.

```moonbit
let db = Kv::init(fs, fs, git_dir, node_id)
db.set(fs, fs, "users/alice/profile", value, ts)
db.sync_with_peer(fs, fs, peer_url)  // Gossip protocol
```

Use case: when many AI agents parallelize work from the same base state, they can synchronize that state quickly.

## Experimental: bit/x/hub

Git-native hub workflow without GitHub/GitLab. PRs and issues are stored under `refs/notes/bit-hub` and can be synchronized via `bit hub sync push/fetch`.

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

The CLI already supports `bit hub pr/issue/note/sync`, and `bit agent` builds on this layer for PR creation/review/merge workflows. It is still experimental, with ongoing work on provider abstraction for import and broader CLI test coverage.

## Limitations

Many Git tests pass for the implemented subset, but many commands remain unimplemented.

### Unsupported commands

- **Interactive operations**: `bit add -p`, `bit rebase -i` (no good abstraction yet)
- **GPG signing**: not implemented

### Performance

- `bit clone` is about 1.8x slower than git
- MoonBit is not multithreaded, so packfile decoding is the bottleneck

## Links

- GitHub: https://github.com/mizchi/bit
- MoonBit: https://www.moonbitlang.com/
