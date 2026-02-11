#!/bin/sh
#
# Test workspace flow behavior using reusable fixtures
#

test_description='workspace flow fixture bootstrap and e2e execution'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

FIXTURE_DIR="$BIT_BUILD_DIR/fixtures/workspace_flow"

test_expect_success 'setup: bootstrap workspace repositories from fixture script' '
	"$FIXTURE_DIR/bootstrap.sh" ws &&
	test_path_is_dir ws &&
	test_path_is_dir ws/dep &&
	test_path_is_dir ws/leaf &&
	test_path_is_dir ws/extra &&
	test_path_is_dir ws/.git &&
	test_path_is_dir ws/dep/.git
'

test_expect_success 'setup: initialize workspace metadata and install fixture manifest' '
	(cd ws &&
	 $BIT workspace init >../ws-fixture-init.out 2>&1 &&
	 cp "$FIXTURE_DIR/workspace.toml" .git/workspace.toml
	) &&
	grep "Initialized workspace at" ws-fixture-init.out &&
	test_path_is_file ws/.git/workspace.toml
'

test_expect_success 'fixture flow executes and caches topological steps' '
	mkdir flow-logs &&
	(cd ws &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-fixture-flow-1.out 2>&1 &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-fixture-flow-2.out 2>&1
	) &&
	test_path_is_file flow-logs/root.log &&
	test_path_is_file flow-logs/dep.log &&
	test_path_is_file flow-logs/leaf.log &&
	test_path_is_file flow-logs/extra.log &&
	test_line_count = flow-logs/root.log 1 &&
	test_line_count = flow-logs/dep.log 1 &&
	test_line_count = flow-logs/leaf.log 1 &&
	test_line_count = flow-logs/extra.log 1 &&
	grep "workspace flow txn:" ws-fixture-flow-1.out &&
	sed -n "s/.*workspace flow txn: \\([^ ]*\\).*/\\1/p" ws-fixture-flow-2.out | head -n 1 > ws-fixture-flow-txn.txt &&
	test -s ws-fixture-flow-txn.txt &&
	grep "\"status\": \"cached\"" ws/.git/txns/$(cat ws-fixture-flow-txn.txt).json
'

test_expect_success 'fixture flow failure profile blocks downstream' '
	(cd ws &&
	 cp "$FIXTURE_DIR/workspace.fail.toml" .git/workspace.toml &&
	 if BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-fixture-flow-fail.out 2>&1; then
	   false
	 else
	   true
	 fi
	) &&
	grep "workspace flow txn:" ws-fixture-flow-fail.out &&
	sed -n "s/.*workspace flow txn: \\([^ ]*\\).*/\\1/p" ws-fixture-flow-fail.out | head -n 1 > ws-fixture-flow-fail-txn.txt &&
	test -s ws-fixture-flow-fail-txn.txt &&
	grep "\"node_id\": \"dep\"" ws/.git/txns/$(cat ws-fixture-flow-fail-txn.txt).json &&
	grep "\"status\": \"failed\"" ws/.git/txns/$(cat ws-fixture-flow-fail-txn.txt).json &&
	grep "\"node_id\": \"leaf\"" ws/.git/txns/$(cat ws-fixture-flow-fail-txn.txt).json &&
	grep "\"status\": \"blocked\"" ws/.git/txns/$(cat ws-fixture-flow-fail-txn.txt).json
'

test_expect_success 'git-compatible commands still work in fixture workspace' '
	(cd ws &&
	 $BIT repo status >../ws-fixture-repo-status.out 2>&1 &&
	 $BIT status >../ws-fixture-implicit-status.out 2>&1
	) &&
	grep "On branch" ws-fixture-repo-status.out &&
	! grep "workspace root:" ws-fixture-repo-status.out &&
	grep "workspace root:" ws-fixture-implicit-status.out
'

test_done
