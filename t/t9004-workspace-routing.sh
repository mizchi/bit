#!/bin/sh
#
# Test workspace command routing and git-compat fallback behavior
#

test_description='workspace/ws routing, implicit translation, and repo escape compatibility'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: create repository with initial commit' '
	mkdir repo &&
	(cd repo &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "hello" > README.md &&
	 git add README.md &&
	 git commit -m "initial commit")
'

test_expect_success 'workspace init writes metadata under git dir' '
	(cd repo &&
	 $BIT workspace init >../ws-init.out 2>&1 &&
	 test_path_is_file .git/workspace.toml &&
	 test_path_is_file .git/workspace.lock.json) &&
	grep "Initialized workspace at" ws-init.out
'

test_expect_success 'ws alias works for status' '
	(cd repo &&
	 $BIT ws status >../ws-status.out 2>&1) &&
	grep "workspace root:" ws-status.out &&
	grep -- "- root (.)" ws-status.out
'

test_expect_success 'implicit translation maps bit status to workspace status inside workspace' '
	(cd repo &&
	 $BIT status >../implicit-status.out 2>&1) &&
	grep "workspace root:" implicit-status.out
'

test_expect_success 'repo escape runs normal status output' '
	(cd repo &&
	 $BIT repo status >../repo-status.out 2>&1) &&
	grep "On branch" repo-status.out &&
	! grep "workspace root:" repo-status.out
'

test_expect_success 'non-workspace command still dispatches normally in workspace directory' '
	(cd repo &&
	 $BIT branch >../branch.out 2>&1) &&
	grep "main" branch.out
'

test_expect_success 'bit help remains global help output' '
	(cd repo &&
	 $BIT help >../help.out 2>&1) &&
	grep "start a working area" help.out &&
	! grep "Usage: bit workspace" help.out
'

test_expect_success 'outside workspace status remains regular git-compatible status output' '
	mkdir plain &&
	(cd plain &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "x" > file.txt &&
	 git add file.txt &&
	 git commit -m "plain init" &&
	 $BIT status >../plain-status.out 2>&1) &&
	! grep "workspace root:" plain-status.out &&
	grep "On branch" plain-status.out
'

test_done
