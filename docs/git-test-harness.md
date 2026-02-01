# Git Test Harness (shim)

This repo can run Git upstream tests (`third_party/git/t`) in two modes:

1. **Direct upstream Git** (default):
   - Runs the Git submodule's own binaries.
   - Useful for sanity-checking the allowlist, but does **not** test this repo's implementation.

2. **Shim mode** (git-shim):
   - Routes `git` invocations through `tools/git-shim/bin/git`.
   - The shim can:
     - **Pass through** to system Git (default), or
     - **Fail** specific subcommands to show what's missing, or
   - **Delegate** to a custom implementation via `SHIM_MOON` (or `GIT_SHIM_MOON` outside the test harness).

## Usage

Run allowlist with shim (pass-through to system Git):

```
just git-t-allowlist-shim
```

Run allowlist with shim in **strict** mode (fails selected subcommands):

```
just git-t-allowlist-shim-strict
```

## Environment Variables (git-shim)

The upstream test harness unsets `GIT_*` variables, so prefer `SHIM_*` when
running via `make test`:

- `SHIM_REAL_GIT` (or `GIT_SHIM_REAL_GIT`): absolute path to system git (required)
- `SHIM_EXEC_PATH` (or `GIT_SHIM_EXEC_PATH`): exec-path for dashed commands (optional)
- `SHIM_CMDS` (or `GIT_SHIM_CMDS`): space-separated subcommands to intercept (e.g. `pack-objects index-pack`)
- `SHIM_STRICT=1` (or `GIT_SHIM_STRICT=1`): fail intercepted subcommands
- `SHIM_MOON` (or `GIT_SHIM_MOON`): command to execute instead of system git for intercepted subcommands
- `SHIM_LOG` (or `GIT_SHIM_LOG`): optional log file for shim decisions
- `tools/git-shim/real-git-path` should contain an absolute path to a real `git`
  binary (not the shim), or the shim will refuse to run to avoid recursion.

## Notes

- The allowlist is in `tools/git-test-allowlist.txt`.
- Upstream tests are patched at runtime via `tools/apply-git-test-patches.sh`;
  patch files live in `tools/git-patches/`.
- Shim mode is scaffolding: it doesn't test this repo's implementation until
  `SHIM_MOON` points to a real CLI that calls MoonBit code.
- On Apple Git, `git version --build-options` does not emit `default-hash`,
  so `GIT_DEFAULT_HASH` becomes empty and `git init` fails. The `just` shim
  targets set `GIT_TEST_DEFAULT_HASH=sha1` to avoid this.
- `tools/git-shim/moon` is a MoonBit entrypoint used by the shim. It currently
  handles `receive-pack` via MoonBit and forwards other subcommands to the
  system Git.
