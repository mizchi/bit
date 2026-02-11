#!/bin/sh
#
# Test workspace init template scaffolding
#

test_description='workspace init can scaffold template manifests'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

FIXTURE_DIR="$BIT_BUILD_DIR/fixtures/workspace_flow"

test_expect_success 'setup: prepare nested repositories from fixture bootstrap' '
	"$FIXTURE_DIR/bootstrap.sh" ws &&
	test_path_is_dir ws &&
	test_path_is_dir ws/dep &&
	test_path_is_dir ws/leaf &&
	test_path_is_dir ws/extra
'

test_expect_success 'workspace init --template flow writes scaffold manifest and flow works' '
	mkdir flow-logs &&
	(cd ws &&
	 $BIT workspace init --template flow >../ws-init-template-flow.out 2>&1 &&
	 grep "id = \"root\"" .git/workspace.toml &&
	 grep "id = \"dep\"" .git/workspace.toml &&
	 grep "id = \"leaf\"" .git/workspace.toml &&
	 grep "id = \"extra\"" .git/workspace.toml &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-init-template-flow-run.out 2>&1
	) &&
	test_path_is_file flow-logs/root.log &&
	test_path_is_file flow-logs/dep.log &&
	test_path_is_file flow-logs/leaf.log &&
	test_path_is_file flow-logs/extra.log &&
	test_line_count = flow-logs/root.log 1 &&
	test_line_count = flow-logs/dep.log 1 &&
	test_line_count = flow-logs/leaf.log 1 &&
	test_line_count = flow-logs/extra.log 1
'

test_expect_success 'workspace init default keeps minimal manifest shape' '
	"$FIXTURE_DIR/bootstrap.sh" ws-default &&
	(cd ws-default &&
	 $BIT workspace init >../ws-init-default.out 2>&1 &&
	 grep "id = \"root\"" .git/workspace.toml &&
	 ! grep "id = \"dep\"" .git/workspace.toml)
'

test_expect_success 'workspace init fails on unknown template' '
	"$FIXTURE_DIR/bootstrap.sh" ws-bad &&
	(cd ws-bad &&
	 if $BIT workspace init --template nope >../ws-init-bad.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "unknown workspace template" ws-init-bad.out
'

test_done
