#!/bin/bash
#
# Test --no-git-fallback behavior

source "$(dirname "$0")/test-lib-e2e.sh"

test_expect_failure 'unsupported command fails with --no-git-fallback' '
    git_cmd init &&
    git_cmd blame README.md
'

test_expect_success 'version command works with --no-git-fallback' '
    git_cmd --version | grep -q "git version"
'

test_expect_success 'help command works with --no-git-fallback' '
    git_cmd --help | grep -q "bit is a Git implementation"
'

test_expect_success 'config works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=/no/such git_cmd config user.name "bit-test" &&
        test "$(git_cmd config --get user.name)" = "bit-test"
    )
'

test_done
