# bit

Git implementation in [MoonBit](https://docs.moonbitlang.com) - fully compatible with some extensions.

> **Warning**: This is an experimental implementation. Do not use in production. Data corruption may occur in worst case scenarios. Always keep backups of important repositories.

## Install

**Supported platforms**: Linux x64, macOS arm64/x64

```bash
# One-line install
curl -fsSL https://raw.githubusercontent.com/mizchi/bit/main/install.sh | bash

# Or build from source
git clone https://github.com/mizchi/bit
cd bit
just install  # requires MoonBit toolchain
```

Installs to `~/.local/bin/bit`.

## Shell Completion

```bash
# bash (~/.bashrc)
eval "$(bit completion bash)"

# zsh (~/.zshrc)
eval "$(bit completion zsh)"
```

## Subdirectory Clone

Clone subdirectories directly from GitHub:

```bash
# Using @user/repo/path shorthand
bit clone mizchi/bit:src/x/fs

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

### Git Test Suite (git/t)

706 test files from the official Git test suite are in the allowlist.

Allowlist run (`just git-t-allowlist-shim-strict`) on macOS:

| | Count |
|---|---|
| success | 24,274 |
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

### Local test snapshot (2026-02-08)

- `just check`: pass
- `just test`: pass (`js/lib 215 pass`, `native 724 pass`)
- `just e2e` (`t/run-tests.sh t00`): pass
- `just test-subdir` (`t/run-tests.sh t900`): pass
- `just git-t-allowlist`: pass (`success 24,274 / failed 0 / broken 177`)

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
