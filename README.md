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

## Subdirectory Clone

Clone subdirectories directly from GitHub:

```bash
# Using @user/repo/path shorthand
bit clone @mizchi/bit/src/x/fs

# Or paste GitHub browser URL
bit clone https://github.com/user/repo/tree/main/packages/core

# Single file download
bit clone https://github.com/user/repo/blob/main/README.md
```

## Standard Git Commands

```bash
bit clone https://github.com/user/repo
bit checkout -b feature
bit add .
bit commit -m "changes"
bit push origin feature
```

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

### Collab - Git-Native Collaboration

Pull Requests and Issues stored as Git objects:

```moonbit
let collab = Collab::init(fs, fs, git_dir)
let pr = collab.create_pr(fs, fs, "Fix bug", "...",
  source_branch, target_branch, author, ts)
```

## License

Apache-2.0
