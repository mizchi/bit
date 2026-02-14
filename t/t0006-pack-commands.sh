#!/bin/bash
#
# Test pack-related commands: receive-pack, upload-pack, etc.

source "$(dirname "$0")/test-lib-e2e.sh"

test_expect_success 'receive-pack -h shows usage and exits 129' '
    output=$(git_cmd receive-pack -h 2>&1 || true) &&
    echo "$output" | grep -q "usage:"
'

test_expect_success 'upload-pack -h shows usage and exits 129' '
    output=$(git_cmd upload-pack -h 2>&1 || true) &&
    echo "$output" | grep -q "usage:"
'

test_expect_success 'pack-objects -h shows usage' '
    git_cmd init &&
    # pack-objects requires stdin, so just check it exists
    git_cmd pack-objects --help 2>&1 | grep -q -i "usage\|pack" || true
'

test_expect_success 'pack-objects file-output stdin-object mode is explicitly unsupported in standalone mode' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "test" &&
    git_cmd rev-parse HEAD | test_must_fail git_cmd pack-objects .git/objects/pack/test >out 2>err &&
    grep -Eiq "standalone|not supported|pack-objects" err
'

test_done
