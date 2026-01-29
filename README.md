# moonbit-git

A Git implementation in [MoonBit](https://docs.moonbitlang.com), focusing on packfile operations and protocol support.

## Features

### Core Git Operations
- **Packfile**: Create, parse, and verify Git packfiles with REF_DELTA and OFS_DELTA support
- **Pack Index**: Generate `.idx` files compatible with Git
- **Object Database**: Read/write loose objects and packed objects
- **SHA-1**: Pure MoonBit SHA-1 implementation

### Git Commands (via git-shim)
- `pack-objects`: Create packfiles from object lists or revision specs
- `index-pack`: Build pack index from packfiles
- `receive-pack`: Handle push operations (advertisement and data receive)
- `upload-pack`: Handle fetch operations

### Protocol Support
- Git protocol v1/v2
- Smart HTTP transport
- Pkt-line encoding/decoding

### Repository Operations
- `init`, `status`, `log`, `diff`
- `branch`, `checkout`, `reset`
- `merge`, `rebase`
- `.gitignore` parsing

## Project Structure

```
src/
├── packfile.mbt          # Packfile creation with delta compression
├── packfile_parse.mbt    # Packfile parsing
├── pack_index_write.mbt  # Pack index generation
├── object.mbt            # Git object types (blob, tree, commit, tag)
├── sha1.mbt              # SHA-1 implementation
├── pktline.mbt           # Pkt-line protocol
├── remote.mbt            # Remote operations
├── upload_pack_*.mbt     # Upload-pack implementation
├── lib/                  # High-level Git operations
│   ├── receive_pack.mbt  # Receive-pack implementation
│   ├── smart_http.mbt    # Smart HTTP helpers
│   ├── object_db.mbt     # Object database
│   └── ...
└── cmd/
    └── git_shim/         # Native git command interceptor
        ├── main.mbt
        ├── pack_objects.mbt
        ├── index_pack.mbt
        └── pack_helpers.mbt
```

## Quick Commands

```bash
just              # check + test
just fmt          # format code
just check        # type check (js + native)
just test         # run tests (js + native)
just release-check # fmt + info + check + test
```

## Git-Shim

The `git-shim` is a native binary that intercepts specific Git commands and handles them in MoonBit:

```bash
# Build the shim
moon build --target native

# Copy to tools directory
cp _build/native/release/build/cmd/git_shim/git_shim.exe tools/git-shim/moon
```

### Supported Commands

| Command | Status | Notes |
|---------|--------|-------|
| `pack-objects` | ✅ | `--revs`, `--all`, `--stdout`, `--delta-base-offset`, `--progress` |
| `index-pack` | ✅ | `--stdin`, `-o`, `--keep`, `--fix-thin` |
| `receive-pack` | ✅ | `--advertise-refs`, `--stateless-rpc` |
| `upload-pack` | ✅ | `--advertise-refs`, `--stateless-rpc` |

### Fallback Behavior

- Unsupported options automatically fall back to real Git
- SHA256 repositories fall back to real Git
- Set `SHIM_STRICT=1` to error on unsupported commands

### Configuration Support

- `pack.packSizeLimit`: Honors Git config for splitting large packs (minimum 1 MiB)

## Testing

### Unit Tests
```bash
just test  # Runs 260 tests (116 js + 144 native)
```

### Git Upstream Test Suite Compatibility

The implementation passes Git's official test suite:

```bash
just git-t-allowlist-shim      # Run with git-shim
```

| Category | Passed | Failed | Total |
|----------|--------|--------|-------|
| All (pack/fetch/push/clone/pull/protocol) | 3500 | 0 | 3542 |

**3500/3542 tests pass** with 0 failures (skipped tests are due to platform-specific prerequisites like GPG, MINGW, etc.).

### Oracle Testing

Native tests use Git as an oracle to verify correctness:
- Blob/Tree/Commit hash comparison with `git hash-object`
- Packfile verification with `git verify-pack` and `git unpack-objects`
- Tree format compatibility with `git write-tree`
- Protocol compatibility with `git cat-file`, `git diff-tree`, `git ls-files`

## Current Limitations

- SHA256 object format: Falls back to real Git
- SHA1 collision detection: Not implemented
- Thin pack resolution: Partial support
- Some advanced options (e.g., `--stdin-packs`, `--filter`, `--threads`)

## License

Apache-2.0
