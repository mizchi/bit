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

## Shell Completion

```bash
# bash (~/.bashrc)
eval "$(bit completion bash)"

# zsh (~/.zshrc)
eval "$(bit completion zsh)"
```

## Project Management Extensions (Experimental)

- **Partial checkout for nested projects**: `bit clone <repo>:<subdir>` can extract a subdirectory as an independent repository with its own `.git` (usable as an embedded repo inside a parent workspace).
- **Distributed filesystem primitives**: `x/fs` (Git-backed virtual filesystem) and `x/kv` (Gossip-synced KV on Git objects) are designed as building blocks for distributed state sharing.
- **Workspace fingerprint extension**: `bit workspace flow` cache keys include per-node directory fingerprints. Default `git` mode is aligned with `git add -A` style snapshots (includes staged + unstaged changes).

## Bit Extension Commands Quick Guide

### bit fingerprint

`bit fingerprint` is currently a feature set (workspace/hub integration), not a standalone top-level command.

```bash
# Workspace flow uses per-node directory fingerprints
BIT_WORKSPACE_FINGERPRINT_MODE=git bit workspace flow test
BIT_WORKSPACE_FINGERPRINT_MODE=fast bit workspace flow test

# Hub workflow records can carry a workspace fingerprint
bit hub pr workflow submit 123 \
  --task test --status success \
  --fingerprint <workspace-fingerprint> \
  --txn <txn-id>
```

### bit subdir

Use `bit subdir-clone` (or clone shorthand) to work on a repository subdirectory as an independent repo.

```bash
# Explicit command
bit subdir-clone https://github.com/user/repo src/lib mylib

# Shorthand via clone
bit clone user/repo:src/lib
bit clone user/repo@main:src/lib
```

After clone, use normal commands in the extracted repo (`bit status`, `bit rebase`, `bit push`).

### bit hub

Git-native PR/Issue workflow stored in repository data.

```bash
bit hub init

# PR / Issue
bit hub pr list --open
bit hub issue list --open

# Sync metadata
bit hub sync push
bit hub sync fetch

# Search
bit hub search "cache" --type pr --state open

# Shortcuts
bit pr list --open
bit issue list --open
```

### bit rebase-ai

AI-assisted rebase conflict resolution (OpenRouter, default model `moonshotai/kimi-k2`).

```bash
export OPENROUTER_API_KEY=...

# Start / continue / abort / skip
bit rebase-ai main
bit rebase-ai --continue
bit rebase-ai --abort
bit rebase-ai --skip

# Options
bit rebase-ai --model moonshotai/kimi-k2 --max-ai-rounds 16 main
bit rebase-ai --agent-loop --agent-max-steps 24 main
```

### bit mcp

Start the MCP server via `bit mcp` (native target).

```bash
# Start MCP server (stdio)
bit mcp

# Help
bit mcp --help
bit help mcp

# Standalone MoonBit entrypoint (equivalent server implementation)
moon run src/x/mcp --target native
```

### bit hq

`ghq`-compatible repository manager (default root: `~/bhq`).

```bash
bit hq get mizchi/git
bit hq get -u mizchi/git
bit hq get --shallow mizchi/git
bit hq list
bit hq list mizchi
bit hq root
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
- Intentionally unsupported (for now): `http-push-webdav` and `send-email` paths.

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

### Storage Abstraction For Agents

`bit` core operations can be run against any storage backend that implements:

- `@git.FileSystem` (write side)
- `@git.RepoFileSystem` (read side)

Entry point:

- `/Users/mz/ghq/github.com/mizchi/bit/src/cmd/bit/storage_runtime.mbt`
- `run_storage_command(fs, rfs, root, cmd, args)`

One in-memory implementation is `@git.TestFs`, which can be used as agent storage:

```moonbit
let fs = @git.TestFs::new()
let root = "/agent-repo"
run_storage_command(fs, fs, root, "init", ["-q"])
fs.write_string(root + "/note.txt", "hello")
run_storage_command(fs, fs, root, "add", ["note.txt"])
run_storage_command(fs, fs, root, "commit", ["-m", "agent snapshot"])
```

### Git Test Suite (git/t)

706 test files from the official Git test suite are in the allowlist.

Allowlist run (`just git-t-allowlist-shim-strict`) on macOS:

| | Count |
|---|---|
| success | 24,279 |
| failed | 0 |
| broken (prereq skip) | 177 |
| total | 24,858 |

177 broken tests are skipped due to missing prerequisites, not failures:

| Category | Prereqs | Skips | Notes |
|---|---|---|---|
| Platform | MINGW, WINDOWS, NATIVE_CRLF, SYMLINKS_WINDOWS | ~72 | Windows-only tests |
| GPG signing | GPG, GPG2, GPGSM, RFC1991 | ~127 | `brew install gnupg` to enable |
| Terminal | TTY | ~33 | Requires interactive terminal |
| Build config | EXPENSIVE, BIT_SHA256, PCRE, HTTP2, SANITIZE_LEAK, RUNTIME_PREFIX | ~30 | Optional build/test flags |
| Filesystem | SETFACL, LONG_REF, TAR_HUGE, TAR_NEEDS_PAX_FALLBACK | ~10 | Platform-specific capabilities |
| Negative prereqs | !AUTOIDENT, !CASE_INSENSITIVE_FS, !LONG_IS_64BIT, !PTHREADS, !SYMLINKS | ~7 | Tests requiring feature absence |

5 test files are excluded from the allowlist: t5310 (bitmap), t5316 (delta depth), t5317 (filter-objects), t5332 (multi-pack reuse), t5400 (send-pack).

Full upstream run (`just git-t`) summary on macOS (2026-02-07):

| | Count |
|---|---|
| success | 31,832 |
| failed | 0 |
| broken (known breakage / prereq skip) | 397 |
| total | 33,046 |

### Local test snapshot (2026-02-12)

- `just check`: pass
- `just test`: pass (`js/lib 215 pass`, `native 811 pass`)
- `just e2e` (`t/run-tests.sh t00`): pass
- `just test-subdir` (`t/run-tests.sh t900`): pass
- `just git-t-allowlist`: pass (`success 24,279 / failed 0 / broken 177`)

### Performance (2026-02-12)

| Operation | Time |
|---|---|
| checkout 100 files | 37.25 ms |
| commit 100 files | 9.86 ms |
| create_packfile 100 | 6.62 ms |
| create_packfile_with_delta 100 | 10.03 ms |
| add_paths 100 files | 7.42 ms |
| status clean (small) | 2.38 ms |

### Distributed/Agent testing

- `just test-distributed`: run focused checks for `x/agent`, `x/hub`, `x/kv`
- testing strategy and invariants: `docs/distributed-testing.md`

## Environment Variables

- `BIT_BENCH_GIT_DIR`: override .git path for bench_real (x/fs benchmarks).
- `BIT_PACK_CACHE_LIMIT`: max number of pack files to keep in memory (default: 2; 0 disables cache).
- `BIT_RACY_GIT`: when set, rehash even if stat matches to avoid racy-git false negatives.
- `BIT_WORKSPACE_FINGERPRINT_MODE`: workspace fingerprint mode (`git` default, `fast` optional). `git` mode follows add-all-style Git-compatible directory snapshots for flow cache decisions.

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
