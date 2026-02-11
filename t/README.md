# Test Suite for bit

This directory contains shell-based integration tests for bit, following the Git project's testing conventions.

## Running Tests

```bash
# Run all tests
./t/run-tests.sh

# Run legacy e2e subset (t00xx)
./t/run-tests.sh t00

# Run subdir-focused subset (t900x)
./t/run-tests.sh t900

# Run a single test
./t/t9000-subdir-clone.sh

# Run with verbose output
./t/run-tests.sh -v t9000

# Keep trash directories for debugging
BIT_TEST_KEEP_TRASH=1 ./t/t9000-subdir-clone.sh
```

## Test Naming Convention

Tests are numbered in the format `tNNNN-description.sh`:

- `t00xx` - Legacy e2e/integration scenarios (migrated from `e2e/`)
- `t0xxx` - Basic functionality
- `t1xxx` - Object handling
- `t2xxx` - Index operations
- `t3xxx` - Branch operations
- `t5xxx` - Remote operations
- `t9xxx` - bit-specific features (subdir-clone, etc.)

## Writing Tests

Tests use two helper libs:

- `test-lib.sh` for git-style shell integration tests (`t1xxx`, `t3xxx`, `t9xxx`, etc.)
- `test-lib-e2e.sh` for the migrated `t000x` scenarios (`git_cmd`, isolated temp dir per case)

Common helpers include:

- `test_expect_success 'description' 'commands'` - Run a test
- `test_expect_failure 'description' 'commands'` - Expect failure
- `test_skip 'description' 'reason'` - Skip a test
- `test_cmp file1 file2` - Compare files
- `test_path_is_file path` - Check file exists
- `test_path_is_dir path` - Check directory exists
- `test_path_is_missing path` - Check path doesn't exist
- `test_done` - Finish and report results

Example:

```sh
#!/bin/sh
test_description='My test'
. ./test-lib.sh

test_expect_success 'create a file' '
    echo "content" > file.txt &&
    test_path_is_file file.txt
'

test_done
```

## Test Files

| File | Description |
|------|-------------|
| `t9000-subdir-clone.sh` | Subdir-clone: cloning subdirectories |
| `t9001-subdir-push.sh` | Subdir-push: pushing changes back upstream |
| `t9002-shallow-sparse.sh` | Shallow clone and sparse checkout |
| `t9004-workspace-routing.sh` | Workspace command routing, implicit translation, and repo escape |
| `t9005-workspace-commit-push.sh` | Workspace commit/push transaction and resume behavior |
| `t9006-workspace-run-export-doctor.sh` | Workspace run/export/doctor with multi-node manifests |
| `t9007-workspace-nested-translation.sh` | Nested directory translation and fallback behavior |
| `t9008-workspace-flow-cache.sh` | Workspace flow PoC: topological task execution with cache and dependency blocking |
| `t9009-workspace-flow-fixture.sh` | Workspace flow fixture bootstrap and e2e verification |
| `t90010-workspace-git-compat.sh` | Workspace flow/commit/push compatibility checks against native git behavior |
| `t9011-workspace-init-template.sh` | Workspace init template scaffolding (`--template flow`) and invalid template validation |
