#!/bin/sh
#
# Test bit fetch output when up to date
#

test_description='bit fetch is quiet when up to date'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

if test -x "$BIT_BUILD_DIR/target/native/release/build/cmd/bit/bit.exe"; then
	BIT="$BIT_BUILD_DIR/target/native/release/build/cmd/bit/bit.exe"
elif test -x "$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit.exe"; then
	BIT="$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit.exe"
elif test -x "$BIT_BUILD_DIR/tools/git-shim/moon"; then
	BIT="$BIT_BUILD_DIR/tools/git-shim/moon"
fi

if ! test_have_prereq GIT; then
	test_skip "bit fetch up-to-date" "git not found"
	test_done
	exit 0
fi

if ! command -v node >/dev/null 2>&1; then
	test_skip "bit fetch up-to-date" "node not found"
	test_done
	exit 0
fi

cleanup_http() {
	if test -n "${SERVER_PID:-}"; then
		kill "$SERVER_PID" 2>/dev/null || true
	fi
}
trap 'cleanup_http; cleanup' EXIT

PORT=$((10000 + $$ % 50000))
SERVER_LOG="$TRASH_DIRECTORY/server.log"

# Setup: create upstream repository

test_expect_success 'setup: create upstream repository' '
	mkdir -p upstream &&
	(cd upstream &&
	 git init &&
	 git config user.email "test@test.com" &&
	 git config user.name "Test" &&
	 echo "Hello" > README.md &&
	 git add -A &&
	 git commit -m "Initial commit")
'

# Start HTTP server using real git backend

test_expect_success 'setup: start smart HTTP server' '
	USE_REAL_GIT=1 node "$BIT_BUILD_DIR/tools/http-test-server.js" \
	  "$TRASH_DIRECTORY/upstream" $PORT >"$SERVER_LOG" 2>&1 &
	SERVER_PID=$! &&
	sleep 1 &&
	kill -0 $SERVER_PID
'

# Clone via bit

test_expect_success 'clone via HTTP' '
	$BIT clone "http://localhost:$PORT" clone &&
	test_path_is_file clone/README.md
'

# First fetch may print new branch; ensure it succeeds

test_expect_success 'fetch primes remote refs' '
	(cd clone && $BIT fetch origin >"$TRASH_DIRECTORY/fetch1.out" 2>&1)
'

# Second fetch should be quiet when up to date

test_expect_success 'fetch is quiet when up to date' '
	(cd clone && $BIT fetch origin >"$TRASH_DIRECTORY/fetch2.out" 2>&1) &&
	test ! -s "$TRASH_DIRECTORY/fetch2.out"
'

# Add new commit to upstream

test_expect_success 'update upstream repository' '
	(cd upstream &&
	 echo "Updated" > README.md &&
	 git add -A &&
	 git commit -m "Update")
'

# Fetch should show update output

test_expect_success 'fetch shows update' '
	(cd clone && $BIT fetch origin >"$TRASH_DIRECTORY/fetch3.out" 2>&1) &&
	test -s "$TRASH_DIRECTORY/fetch3.out"
'

# Fetch again should be quiet

test_expect_success 'fetch is quiet again' '
	(cd clone && $BIT fetch origin >"$TRASH_DIRECTORY/fetch4.out" 2>&1) &&
	test ! -s "$TRASH_DIRECTORY/fetch4.out"
'

test_done
