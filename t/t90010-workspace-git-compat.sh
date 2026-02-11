#!/bin/sh
#
# Git compatibility checks for workspace flow/commit/push
#

test_description='workspace fixtures keep git-compatible behavior across flow/commit/push'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

FIXTURE_DIR="$BIT_BUILD_DIR/fixtures/workspace_flow"

test_expect_success 'setup: bootstrap fixture repositories and attach local remotes' '
	"$FIXTURE_DIR/bootstrap.sh" ws &&
	base_dir=$(pwd) &&
	git init --bare upstream-root.git &&
	git init --bare upstream-dep.git &&
	git init --bare upstream-leaf.git &&
	git init --bare upstream-extra.git &&
	(cd ws &&
	 git remote add origin "$base_dir/upstream-root.git" &&
	 git push -u origin main) &&
	(cd ws/dep &&
	 git remote add origin "$base_dir/upstream-dep.git" &&
	 git push -u origin main) &&
	(cd ws/leaf &&
	 git remote add origin "$base_dir/upstream-leaf.git" &&
	 git push -u origin main) &&
	(cd ws/extra &&
	 git remote add origin "$base_dir/upstream-extra.git" &&
	 git push -u origin main)
'

test_expect_success 'setup: initialize workspace metadata from fixture manifest' '
	(cd ws &&
	 $BIT workspace init >../ws-compat-init.out 2>&1 &&
	 cp "$FIXTURE_DIR/workspace.toml" .git/workspace.toml) &&
	grep "Initialized workspace at" ws-compat-init.out &&
	test_path_is_file ws/.git/workspace.toml
'

test_expect_success 'workspace flow keeps all repositories git-clean and metadata untracked' '
	mkdir flow-logs &&
	(cd ws &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-compat-flow-1.out 2>&1 &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-compat-flow-2.out 2>&1) &&
	for repo in ws ws/dep ws/leaf ws/extra
	do
		out=$(mktemp) &&
		git -C "$repo" status --porcelain >"$out" &&
		test_path_is_file "$out" &&
		! test -s "$out" &&
		rm -f "$out"
	done &&
	git -C ws ls-files > tracked-files.out &&
	! grep -q "workspace.toml" tracked-files.out &&
	! grep -q "workspace.lock.json" tracked-files.out &&
	! grep -q "workspace.flow-cache.json" tracked-files.out
'

test_expect_success 'bit repo status --porcelain matches git status --porcelain for dirty repo' '
	echo "dep-dirty" >> ws/dep/dep.txt &&
	(cd ws/dep &&
	 git status --porcelain >../../dep-git-status.out &&
	 $BIT repo status --porcelain >../../dep-bit-status.out 2>&1) &&
	test_cmp dep-git-status.out dep-bit-status.out
'

test_expect_success 'workspace commit writes git-visible transaction trailer and consistent HEADs' '
	echo "root-dirty" >> ws/root.txt &&
	git -C ws add root.txt &&
	git -C ws/dep add dep.txt &&
	(cd ws &&
	 $BIT workspace commit -m "workspace git-compat commit" >../ws-compat-commit.out 2>&1) &&
	git -C ws log -1 --pretty=%B > root-head-msg.out &&
	git -C ws/dep log -1 --pretty=%B > dep-head-msg.out &&
	grep "Bit-Workspace-Txn:" root-head-msg.out &&
	grep "Bit-Workspace-Txn:" dep-head-msg.out &&
	(cd ws &&
	 git rev-parse HEAD > ../root-head-git.out &&
	 $BIT repo rev-parse HEAD > ../root-head-bit.out) &&
	(cd ws/dep &&
	 git rev-parse HEAD > ../../dep-head-git.out &&
	 $BIT repo rev-parse HEAD > ../../dep-head-bit.out) &&
	test_cmp root-head-git.out root-head-bit.out &&
	test_cmp dep-head-git.out dep-head-bit.out
'

test_expect_success 'git native push after workspace operations keeps remote refs aligned and repositories pass fsck' '
	git -C ws push origin main &&
	git -C ws/dep push origin main &&
	git -C ws/leaf push origin main &&
	git -C ws/extra push origin main &&
	git --git-dir=upstream-root.git rev-parse refs/heads/main > root-remote-head.out &&
	git --git-dir=upstream-dep.git rev-parse refs/heads/main > dep-remote-head.out &&
	git --git-dir=upstream-leaf.git rev-parse refs/heads/main > leaf-remote-head.out &&
	git --git-dir=upstream-extra.git rev-parse refs/heads/main > extra-remote-head.out &&
	git -C ws rev-parse HEAD > root-local-head.out &&
	git -C ws/dep rev-parse HEAD > dep-local-head.out &&
	git -C ws/leaf rev-parse HEAD > leaf-local-head.out &&
	git -C ws/extra rev-parse HEAD > extra-local-head.out &&
	test_cmp root-local-head.out root-remote-head.out &&
	test_cmp dep-local-head.out dep-remote-head.out &&
	test_cmp leaf-local-head.out leaf-remote-head.out &&
	test_cmp extra-local-head.out extra-remote-head.out &&
	git -C ws fsck --full &&
	git -C ws/dep fsck --full &&
	git -C ws/leaf fsck --full &&
	git -C ws/extra fsck --full
'

test_expect_success 'git native commit after workspace operations remains visible from bit and workspace status' '
	echo "extra-git-native" >> ws/extra/extra.txt &&
	git -C ws/extra add extra.txt &&
	git -C ws/extra commit -m "git native commit after bit workspace flow" &&
	git -C ws/extra rev-parse HEAD > extra-native-git-head.out &&
	(cd ws/extra &&
	 $BIT repo rev-parse HEAD > ../../extra-native-bit-head.out) &&
	test_cmp extra-native-git-head.out extra-native-bit-head.out &&
	(cd ws &&
	 $BIT workspace status >../ws-compat-status-after-git.out 2>&1) &&
	grep "extra" ws-compat-status-after-git.out &&
	grep "drift=yes" ws-compat-status-after-git.out
'

test_done
