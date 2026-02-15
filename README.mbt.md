# bit

Git implementation in [MoonBit](https://docs.moonbitlang.com) - fully compatible with some extensions.

> **Warning**: This is an experimental implementation. Do not use in production. Data corruption may occur in worst case scenarios. Always keep backups of important repositories.

## Install

**Supported platforms**: Linux x64, macOS arm64/x64

```bash
# One-line install
curl -fsSL https://raw.githubusercontent.com/mizchi/bit-vcs/main/install.sh | bash

# Or install via MoonBit toolchain
moon install mizchi/bit/cmd/bit
```

## Subdirectory Clone

Clone subdirectories directly from GitHub:

```bash
# Using @user/repo/path shorthand
bit clone mizchi/bit-vcs:src/x/fs

# Or paste GitHub browser URL
bit clone https://github.com/user/repo/tree/main/packages/core

# Single file download
bit clone https://github.com/user/repo/blob/main/README.md
```

Cloned subdirectories have their own `.git` directory. When placed inside another git repository, git automatically treats them as embedded repositories (like submodules) - the parent repo won't commit their contents.

## Standard Git Commands

```bash
bit clone https://github.com/user/repo
bit checkout -b feature
bit add .
bit commit -m "changes"
bit push origin feature
```

## Compatibility

- Hash algorithm: SHA-1 only.
- SHA-256 repositories and `--object-format=sha256` are not supported.
- Git config: reads global aliases from `~/.gitconfig` (or `GIT_CONFIG_GLOBAL`) only.
- Shell aliases (prefixed with `!`) are not supported.

### Standalone Test Coverage (Current)

Standalone coverage is validated with `git_cmd` in `t/test-lib-e2e.sh`, which runs `bit --no-git-fallback ...` (no real-git dependency in these tests).

Current standalone integration coverage (`t/t0001-*.sh` to `t/t0021-*.sh`) includes:

- repository lifecycle and core porcelain: `init`, `status`, `add`, `commit`, `branch`, `checkout`/`switch`, `reset`, `log`, `tag`
- transport-style workflows in standalone mode: `clone`, `fetch`, `pull`, `push`, `bundle`
- plumbing used by normal flows: `hash-object`, `cat-file`, `ls-files`, `ls-tree`, `write-tree`, `update-ref`, `fsck`
- feature flows: `hub`, `rebase-ai`, `mcp`, `hq`

Representative files: `t/t0001-init.sh`, `t/t0003-plumbing.sh`, `t/t0005-fallback.sh`, `t/t0018-commit-workflow.sh`, `t/t0019-clone-local.sh`, `t/t0020-push-fetch-pull.sh`, `t/t0021-hq-get.sh`.

### Explicitly Unsupported In Standalone Mode

The following are intentionally rejected with explicit standalone-mode errors (covered by `t/t0005-fallback.sh` and command-level checks):

- signed commit modes (`commit -S`, `commit --gpg-sign`)
- interactive rebase (`rebase -i`)
- reftable-specific paths (`clone --ref-format=reftable`, `update-ref` on reftable repo)
- cloning from local bundle file (`clone <bundle-file>`)
- SHA-256 object-format compatibility paths (`hash-object -w` with `compatObjectFormat=sha256`, `write-tree` on non-sha1 repo)
- `cat-file --batch-all-objects` with `%(objectsize:disk)`
- unsupported option sets for `index-pack` and `pack-objects`

### Where Git Fallback Exists

- Main `bit` command dispatch in `src/cmd/bit/main.mbt` does not auto-delegate unknown commands to system git.
- Git fallback/delegation is implemented in the shim layer `tools/git-shim/bin/git`.
  - The shim delegates to `SHIM_REAL_GIT` by default.
  - CI `git-compat` (`.github/workflows/ci.yml`) runs upstream `git/t` via this shim (`SHIM_REAL_GIT`, `SHIM_MOON`, `SHIM_CMDS`).

## Environment Variables

- `BIT_BENCH_GIT_DIR`: override .git path for bench_real (x/fs benchmarks).
- `BIT_PACK_CACHE_LIMIT`: max number of pack files to keep in memory (default: 2; 0 disables cache).
- `BIT_RACY_GIT`: when set, rehash even if stat matches to avoid racy-git false negatives.

## Extensions

### Fs - Virtual Filesystem

Mount any commit as a filesystem with lazy blob loading:

```moonbit
let fs = Fs::from_commit(fs, ".git", commit_id)
let files = fs.readdir(fs, "src")
let content = fs.read_file(fs, "src/main.mbt")
```

### Kv - Distributed KV Store

Git-backed key-value store with Gossip protocol sync:

```moonbit
let db = Kv::init(fs, fs, git_dir, node_id)
db.set(fs, fs, "users/alice/profile", value, ts)
db.sync_with_peer(fs, fs, peer_url)
```

### Hub - Git-Native Huboration

Pull Requests and Issues stored as Git objects:

```moonbit
let hub = Hub::init(fs, fs, git_dir)
let pr = hub.create_pr(fs, fs, "Fix bug", "...",
  source_branch, target_branch, author, ts)
```

## License

Apache-2.0
