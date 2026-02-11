#!/bin/sh
#
# Test implicit workspace translation from nested directories
#

test_description='workspace implicit translation works from deep subdirectories without breaking repo fallback'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: create repository and nested directories' '
	mkdir nested &&
	(cd nested &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 mkdir -p a/b/c &&
	 echo "base" > a/b/c/file.txt &&
	 git add a/b/c/file.txt &&
	 git commit -m "init" &&
	 $BIT workspace init)
'

test_expect_success 'nested status is translated to workspace status' '
	$BIT -C nested/a/b/c status > nested-status.out 2>&1 &&
	grep "workspace root:" nested-status.out &&
	grep -- "- root (.)" nested-status.out
'

test_expect_success 'repo status bypasses workspace translation at workspace root' '
	$BIT -C nested repo status > nested-repo-status.out 2>&1 &&
	grep "On branch" nested-repo-status.out &&
	! grep "workspace root:" nested-repo-status.out
'

test_expect_success 'repo status from deep nested path fails as plain repo command' '
	if $BIT -C nested/a/b/c repo status > nested-repo-nested.out 2>&1; then
	  false
	else
	  true
	fi &&
	grep "Not a git repository" nested-repo-nested.out
'

test_expect_success 'implicit commit from workspace root performs workspace commit' '
	echo "changed" >> nested/a/b/c/file.txt &&
	$BIT -C nested add a/b/c/file.txt > nested-add.out 2>&1 &&
	$BIT -C nested commit -m "nested implicit workspace commit" > nested-commit.out 2>&1 &&
	(cd nested && git log -1 --pretty=%B > ../nested-head-msg.txt) &&
	grep "Bit-Workspace-Txn:" nested-head-msg.txt
'

test_expect_success 'regular commands outside workspace remain unaffected' '
	mkdir plain &&
	(cd plain &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "plain" > plain.txt &&
	 git add plain.txt &&
	 git commit -m "plain init") &&
	$BIT -C plain status > plain-status.out 2>&1 &&
	grep "On branch" plain-status.out &&
	! grep "workspace root:" plain-status.out
'

test_done
