#!/bin/sh
#
# Test workspace flow PoC engine behavior
#

test_description='workspace flow topological execution, cache reuse, and git-compatible escape'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: create workspace root and nested repositories' '
	mkdir flow-logs &&
	mkdir ws &&
	(cd ws &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "root-v1" > root.txt &&
	 git add root.txt &&
	 git commit -m "root init") &&
	mkdir ws/dep ws/leaf ws/extra &&
	(cd ws/dep &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "dep-v1" > dep.txt &&
	 git add dep.txt &&
	 git commit -m "dep init") &&
	(cd ws/leaf &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "leaf-v1" > leaf.txt &&
	 git add leaf.txt &&
	 git commit -m "leaf init") &&
	(cd ws/extra &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "extra-v1" > extra.txt &&
	 git add extra.txt &&
	 git commit -m "extra init")
'

test_expect_success 'setup: initialize workspace manifest with topological dependencies' '
	(cd ws &&
	 $BIT workspace init >../ws-flow-init.out 2>&1 &&
	 cat > .git/workspace.toml <<-\EOF
	version = 1

	[[nodes]]
	id = "root"
	path = "."
	required = true
	depends_on = []
	task.test = "echo root >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/root.log\""

	[[nodes]]
	id = "dep"
	path = "dep"
	required = true
	depends_on = ["root"]
	task.test = "echo dep >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/dep.log\""

	[[nodes]]
	id = "leaf"
	path = "leaf"
	required = true
	depends_on = ["dep"]
	task.test = "echo leaf >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/leaf.log\""

	[[nodes]]
	id = "extra"
	path = "extra"
	required = true
	depends_on = []
	task.test = "echo extra >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/extra.log\""
	EOF
	) &&
	grep "Initialized workspace at" ws-flow-init.out
'

test_expect_success 'workspace flow executes all nodes and writes cache file' '
	(cd ws &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-flow-first.out 2>&1) &&
	test_path_is_file flow-logs/root.log &&
	test_path_is_file flow-logs/dep.log &&
	test_path_is_file flow-logs/leaf.log &&
	test_path_is_file flow-logs/extra.log &&
	test_line_count = flow-logs/root.log 1 &&
	test_line_count = flow-logs/dep.log 1 &&
	test_line_count = flow-logs/leaf.log 1 &&
	test_line_count = flow-logs/extra.log 1 &&
	test_path_is_file ws/.git/workspace.flow-cache.json &&
	grep "workspace flow txn:" ws-flow-first.out
'

test_expect_success 'workspace flow reuses cache without rerunning tasks' '
	(cd ws &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-flow-second.out 2>&1) &&
	test_line_count = flow-logs/root.log 1 &&
	test_line_count = flow-logs/dep.log 1 &&
	test_line_count = flow-logs/leaf.log 1 &&
	test_line_count = flow-logs/extra.log 1 &&
	sed -n "s/.*workspace flow txn: \\([^ ]*\\).*/\\1/p" ws-flow-second.out | head -n 1 > ws-flow-second-txn.txt &&
	test -s ws-flow-second-txn.txt &&
	grep "\"status\": \"cached\"" ws/.git/txns/$(cat ws-flow-second-txn.txt).json
'

test_expect_success 'workspace flow cache is isolated by fingerprint mode switch' '
	(cd ws &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" BIT_WORKSPACE_FINGERPRINT_MODE=fast $BIT workspace flow test >../ws-flow-fast-first.out 2>&1 &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" BIT_WORKSPACE_FINGERPRINT_MODE=fast $BIT workspace flow test >../ws-flow-fast-second.out 2>&1) &&
	test_line_count = flow-logs/root.log 2 &&
	test_line_count = flow-logs/dep.log 2 &&
	test_line_count = flow-logs/leaf.log 2 &&
	test_line_count = flow-logs/extra.log 2 &&
	sed -n "s/.*workspace flow txn: \\([^ ]*\\).*/\\1/p" ws-flow-fast-second.out | head -n 1 > ws-flow-fast-second-txn.txt &&
	test -s ws-flow-fast-second-txn.txt &&
	grep "\"status\": \"cached\"" ws/.git/txns/$(cat ws-flow-fast-second-txn.txt).json
'

test_expect_success 'workspace flow reruns dependent chain when upstream repository changes' '
	echo "root-dirty" >> ws/root.txt &&
	(cd ws &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-flow-third.out 2>&1) &&
	test_line_count = flow-logs/root.log 3 &&
	test_line_count = flow-logs/dep.log 3 &&
	test_line_count = flow-logs/leaf.log 3 &&
	test_line_count = flow-logs/extra.log 3
'

test_expect_success 'workspace flow failure blocks downstream dependent node' '
	(cd ws &&
	 cat > .git/workspace.toml <<-\EOF
	version = 1

	[[nodes]]
	id = "root"
	path = "."
	required = true
	depends_on = []
	task.test = "echo root >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/root.log\""

	[[nodes]]
	id = "dep"
	path = "dep"
	required = true
	depends_on = ["root"]
	task.test = "false"

	[[nodes]]
	id = "leaf"
	path = "leaf"
	required = true
	depends_on = ["dep"]
	task.test = "echo leaf >> \"$BIT_WORKSPACE_FLOW_LOG_DIR/leaf.log\""
	EOF
	 if BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-flow-fail.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "workspace flow txn:" ws-flow-fail.out &&
	sed -n "s/.*workspace flow txn: \\([^ ]*\\).*/\\1/p" ws-flow-fail.out | head -n 1 > ws-flow-fail-txn.txt &&
	test -s ws-flow-fail-txn.txt &&
	grep "\"node_id\": \"dep\"" ws/.git/txns/$(cat ws-flow-fail-txn.txt).json &&
	grep "\"status\": \"failed\"" ws/.git/txns/$(cat ws-flow-fail-txn.txt).json &&
	grep "\"node_id\": \"leaf\"" ws/.git/txns/$(cat ws-flow-fail-txn.txt).json &&
	grep "\"status\": \"blocked\"" ws/.git/txns/$(cat ws-flow-fail-txn.txt).json &&
	test_line_count = flow-logs/leaf.log 3
'

test_expect_success 'git-compatible escape still works inside workspace after flow runs' '
	(cd ws &&
	 $BIT repo status >../ws-flow-repo-status.out 2>&1 &&
	 $BIT status >../ws-flow-implicit-status.out 2>&1) &&
	grep "On branch" ws-flow-repo-status.out &&
	! grep "workspace root:" ws-flow-repo-status.out &&
	grep "workspace root:" ws-flow-implicit-status.out
'

test_done
