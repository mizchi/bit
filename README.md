# moonbit-git

**Git as a library** - A Git implementation in [MoonBit](https://docs.moonbitlang.com) that you can embed, extend, and use programmatically.

## Why moonbit-git?

| | Git CLI | moonbit-git |
|---|---------|-------------|
| Compatibility | - | ✅ 4,205 tests pass |
| Use as library | ❌ | ✅ Embed in your app |
| Virtual filesystem | ❌ | ✅ GitFs API |
| Lazy loading | ❌ | ✅ Instant mount |
| Partial clone | ✅ | ✅ + on-demand fetch API |
| Target platforms | Native | Native, WASM, JS |

## What You Can Do

### 1. Mount Repository as Virtual Filesystem

```moonbit
// Mount and browse without checkout
let gitfs = GitFs::from_commit(fs, ".git", commit_id)

// List files (instant - no blob loading)
let files = gitfs.readdir(fs, "src")

// Read file (fetches blob on-demand if partial clone)
let content = gitfs.read_file(fs, "src/main.mbt")

// Check what needs fetching
let pending = gitfs.get_pending_fetches(fs, 100)
```

### 2. Partial Clone with Smart Prefetch

```bash
# Clone metadata only (100KB vs full clone)
moongit clone --filter=blob:none https://github.com/user/repo
```

```moonbit
// Prefetch files matching pattern
gitfs.prefetch_glob(fs, fs, "src/**/*.mbt")

// Or prefetch in breadth-first order (shallow files first)
gitfs.prefetch_bfs(fs, fs, limit=50)
```

### 3. Full Git Compatibility

All standard Git operations work:

```bash
moongit clone https://github.com/user/repo
moongit checkout -b feature
moongit commit -m "changes"
moongit push origin feature
```

### 4. Subdir - Work with Subdirectories as Independent Repos

Treat any subdirectory as an independent git repository while keeping it in the parent repo:

```bash
# Initialize subdirectory as module
moongit subdir init src/lib

# Standard git commands now work from within the subdirectory
cd src/lib
git status    # shows only subdirectory changes
git log       # shows commits affecting subdirectory

# View subdirectory info
moongit subdir show src/lib
moongit subdir log src/lib

# Commit subdirectory changes
moongit subdir commit src/lib -m "Update lib"

# Checkout specific version
moongit subdir checkout src/lib abc123

# Extract subdirectory to another location
moongit subdir extract src/lib /tmp/lib-standalone

# Push/pull subdirectory to separate remote
moongit subdir push src/lib https://github.com/user/lib
moongit subdir pull src/lib https://github.com/user/lib
```

**Sparse checkout** for subdirectories:

```bash
# Enable sparse checkout
moongit subdir sparse-checkout init src/lib

# Set patterns (only checkout matching files)
moongit subdir sparse-checkout set src/lib "*.mbt" "moon.pkg.json"

# Add more patterns
moongit subdir sparse-checkout add src/lib "tests/"

# List current patterns
moongit subdir sparse-checkout list src/lib

# Disable sparse checkout
moongit subdir sparse-checkout disable src/lib
```

**Checkout part of a remote repository** (e.g., monorepo):

```bash
# Clone with sparse checkout enabled (metadata only)
moongit clone --filter=blob:none --sparse https://github.com/user/monorepo
cd monorepo

# Checkout only specific directories
moongit sparse-checkout set packages/core packages/utils

# Or use subdir to work with a specific package
moongit subdir init packages/core
cd packages/core
git status  # scoped to this directory

# Pull a subdirectory from another repository into your project
cd /your/project
mkdir -p vendor/lib
moongit subdir pull vendor/lib https://github.com/user/lib-repo --branch main
```

## Performance

```
GitFs Access Pattern:
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

# Install CLI
just install

# Use as library
moon add mizchi/git
```

## Supported Commands

**Core**: `init`, `clone`, `status`, `add`, `commit`, `log`, `show`, `diff`

**Branching**: `branch`, `checkout`, `switch`, `merge`, `rebase`, `reset`, `cherry-pick`

**Remote**: `remote`, `fetch`, `pull`, `push`

**Plumbing**: `pack-objects`, `index-pack`, `receive-pack`, `upload-pack`, `cat-file`, `hash-object`, `ls-files`, `ls-tree`, `rev-parse`, `verify-pack`, `bundle`, `config`

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Your Application                               │
├─────────────────────────────────────────────────┤
│  GitFs (Virtual Filesystem)                     │
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
