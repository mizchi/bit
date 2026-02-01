# bit

**Git as a library** - A Git implementation in [MoonBit](https://docs.moonbitlang.com) that you can embed, extend, and use programmatically.

## Why bit?

| | Git CLI | bit |
|---|---------|-------------|
| Compatibility | - | ✅ 4,205 tests pass |
| Use as library | ❌ | ✅ Embed in your app |
| Virtual filesystem | ❌ | ✅ Fs API |
| Lazy loading | ❌ | ✅ Instant mount |
| Partial clone | ✅ | ✅ + on-demand fetch API |
| Target platforms | Native | Native, WASM, JS |

## What You Can Do

### 1. Mount Repository as Virtual Filesystem

```moonbit
// Mount and browse without checkout
let fs = Fs::from_commit(fs, ".git", commit_id)

// List files (instant - no blob loading)
let files = fs.readdir(fs, "src")

// Read file (fetches blob on-demand if partial clone)
let content = fs.read_file(fs, "src/main.mbt")

// Check what needs fetching
let pending = fs.get_pending_fetches(fs, 100)
```

### 2. Partial Clone with Smart Prefetch

```bash
# Clone metadata only (100KB vs full clone)
bit clone --filter=blob:none https://github.com/user/repo
```

```moonbit
// Prefetch files matching pattern
fs.prefetch_glob(fs, fs, "src/**/*.mbt")

// Or prefetch in breadth-first order (shallow files first)
fs.prefetch_bfs(fs, fs, limit=50)
```

### 3. Full Git Compatibility

All standard Git operations work:

```bash
bit clone https://github.com/user/repo
bit checkout -b feature
bit commit -m "changes"
bit push origin feature
```

### 4. GitHub Shorthand

Clone from GitHub using `@user/repo` shorthand or paste browser URLs directly:

```bash
# Clone full repository
bit clone @mizchi/bit

# Clone subdirectory only
bit clone @mizchi/bit/src/x/fs

# Paste GitHub browser URL directly (directory)
bit clone https://github.com/mizchi/crater/tree/main/js

# Paste GitHub browser URL (single file → downloads raw file)
bit clone https://github.com/mizchi/crater/blob/main/README.md

# With custom destination
bit clone @mizchi/bit/src/x/fs myfs
```

The `@` prefix distinguishes shorthand from local paths. Browser URLs with `/tree/` clone subdirectories, `/blob/` downloads single files.

### 5. Subdir - Work with Subdirectories as Independent Repos

Treat any subdirectory as an indepencollabt git repository while keeping it in the parent repo:

```bash
# Initialize subdirectory as module
bit subdir init src/lib

# Standard git commands now work from within the subdirectory
cd src/lib
git status    # shows only subdirectory changes
git log       # shows commits affecting subdirectory

# View subdirectory info
bit subdir show src/lib
bit subdir log src/lib

# Commit subdirectory changes
bit subdir commit src/lib -m "Update lib"

# Checkout specific version
bit subdir checkout src/lib abc123

# Extract subdirectory to another location
bit subdir extract src/lib /tmp/lib-standalone

# Push/pull subdirectory to separate remote
bit subdir push src/lib https://github.com/user/lib
bit subdir pull src/lib https://github.com/user/lib
```

**Sparse checkout** for subdirectories:

```bash
# Enable sparse checkout
bit subdir sparse-checkout init src/lib

# Set patterns (only checkout matching files)
bit subdir sparse-checkout set src/lib "*.mbt" "moon.pkg.json"

# Add more patterns
bit subdir sparse-checkout add src/lib "tests/"

# List current patterns
bit subdir sparse-checkout list src/lib

# Disable sparse checkout
bit subdir sparse-checkout disable src/lib
```

**Checkout part of a remote repository** (e.g., monorepo):

```bash
# Clone with sparse checkout enabled (metadata only)
bit clone --filter=blob:none --sparse https://github.com/user/monorepo
cd monorepo

# Checkout only specific directories
bit sparse-checkout set packages/core packages/utils

# Or use subdir to work with a specific package
bit subdir init packages/core
cd packages/core
git status  # scoped to this directory

# Pull a subdirectory from another repository into your project
cd /your/project
mkdir -p vendor/lib
bit subdir pull vendor/lib https://github.com/user/lib-repo --branch main
```

## Performance

```
Fs Access Pattern:
─────────────────────────────────────────
Mount:        Instant (HEAD ref only)
readdir:      Local (tree from pack)
is_file:      Local (metadata)
needs_fetch:  Local (existence check)
read_file:    Network only if blob missing
─────────────────────────────────────────
All metadata operations are local and instant.
```

## Test Coverage

**4,205 tests pass** from Git's official test suite:

| Category | Tests |
|----------|-------|
| init / config | 587 |
| branch / checkout | 399 |
| fetch / push / clone | 1,200+ |
| pack operations | 200+ |
| worktree | 296 |
| merge / rebase | 200+ |
| **Total** | **4,205** |

```bash
just test             # 380+ unit tests
just git-t-allowlist  # Git compatibility tests
```

## Quick Start

```bash
# Build native binary
moon build --target native

# Install CLI (installs to ~/.local/bin/bit)
just install

# Use as library
moon add mizchi/bit
```

## Supported Commands

**Core**: `init`, `clone`, `status`, `add`, `commit`, `log`, `show`, `diff`

**Branching**: `branch`, `checkout`, `switch`, `merge`, `rebase`, `reset`, `cherry-pick`

**Remote**: `remote`, `fetch`, `pull`, `push`

**Plumbing**: `pack-objects`, `index-pack`, `receive-pack`, `upload-pack`, `cat-file`, `hash-object`, `ls-files`, `ls-tree`, `rev-parse`, `verify-pack`, `bundle`, `config`

## Extensions (src/x/)

Experimental features built on top of the core Git implementation.

### Fs - Virtual Filesystem

Mount any commit as a filesystem with lazy blob loading:

```moonbit
let fs = Fs::from_commit(fs, ".git", commit_id)
let files = fs.readdir(fs, "src")      // Instant (tree only)
let content = fs.read_file(fs, "src/main.mbt")  // Fetches on-demand
```

### Subdir-Clone - Clone Subdirectory as Independent Repo

Clone a subdirectory from a remote repository as a standalone git repo:

```bash
# Clone only src/lib from a monorepo
bit subdir-clone https://github.com/user/monorepo src/lib

# Creates mylib/ with src/lib contents at root
bit subdir-clone https://github.com/user/monorepo src/lib mylib
cd mylib

# Standard commands detect subdir-clone automatically
bit status      # Shows subdir-clone info
bit fetch       # Fetches from original remote
bit rebase origin/main  # Rebases only subdir changes
```

### Collab - Git-Native Collaboration (WIP)

Pull Requests, Issues, and Notes stored as Git objects in `_collab` branch:

```moonbit
let collab = Collab::init(fs, fs, git_dir)

// Create PR
let pr = collab.create_pr(fs, fs, "Fix bug", "Description",
  "refs/heads/fix", "refs/heads/main", "alice@example.com", ts)

// Add review
collab.submit_review(fs, fs, pr.id, "bob@example.com",
  Approved, "LGTM", commit_id, ts)

// Sync with remote (standard git push/fetch)
collab.push(fs, fs, remote_url)
collab.fetch(fs, fs, remote_url)
```

### Kv - Distributed KV Store (WIP)

Git-backed key-value store with Gossip protocol sync:

```moonbit
let db = Kv::init(fs, fs, git_dir, node_id)

// Hierarchical keys → Git tree structure
db.set(fs, fs, "users/alice/profile", value, ts)
let data = db.get(fs, "users/alice/profile")

// P2P sync via Gossip protocol
db.sync_with_peer(fs, fs, peer_url)
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Your Application                               │
├─────────────────────────────────────────────────┤
│  Fs (Virtual Filesystem)                     │
│  - Mount any commit as filesystem               │
│  - Lazy blob loading                            │
│  - Prefetch APIs (glob, BFS)                    │
├─────────────────────────────────────────────────┤
│  PromisorDb (On-demand Fetch)                   │
│  - Partial clone support                        │
│  - Transparent remote fetching                  │
├─────────────────────────────────────────────────┤
│  ObjectDb (Object Database)                     │
│  - Pack/loose object access                     │
│  - Lazy index parsing                           │
├─────────────────────────────────────────────────┤
│  Git Protocol v1/v2                             │
│  - Smart HTTP transport                         │
│  - Packfile encoding/decoding                   │
└─────────────────────────────────────────────────┘
```

## License

Apache-2.0
