#!/bin/sh
#
# Test workspace commit/push flow with saga-style resume behavior
#

test_description='workspace commit/push transactions, trailer, txns, and resume path'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: create upstream bare repository and working clone' '
	mkdir upstream.git &&
	(cd upstream.git && git init --bare) &&
	git clone upstream.git work &&
	(cd work &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "v1" > app.txt &&
	 git add app.txt &&
	 git commit -m "initial" &&
	 git push origin main)
'

test_expect_success 'setup: initialize workspace metadata in working clone' '
	(cd work &&
	 $BIT workspace init >../ws-init.out 2>&1 &&
	 test_path_is_file .git/workspace.toml &&
	 test_path_is_dir .git/txns) &&
	grep "Initialized workspace at" ws-init.out
'

test_expect_success 'implicit commit creates workspace commit with transaction trailer' '
	(cd work &&
	 echo "v2" > app.txt &&
	 $BIT add app.txt &&
	 $BIT commit -m "workspace implicit commit" >../implicit-commit.out 2>&1 &&
	 git log -1 --pretty=%B >../head-msg-1.txt) &&
	grep "Bit-Workspace-Txn:" head-msg-1.txt
'

test_expect_success 'explicit workspace commit also includes transaction trailer' '
	(cd work &&
	 echo "v3" > app.txt &&
	 $BIT add app.txt &&
	 $BIT workspace commit -m "workspace explicit commit" >../explicit-commit.out 2>&1 &&
	 git log -1 --pretty=%B >../head-msg-2.txt) &&
	grep "Bit-Workspace-Txn:" head-msg-2.txt &&
	ls work/.git/txns/*.json >/dev/null 2>&1
'

test_expect_success 'workspace push always records transaction output and file' '
	(cd work &&
	 if $BIT workspace push >../ws-push.out 2>&1; then
	   true
	 else
	   true
	 fi &&
	 ls .git/txns/*.json >/dev/null 2>&1) &&
	grep "workspace push txn:" ws-push.out
'

test_expect_success 'workspace push fails on required missing node and prints txn id' '
	cat > work/.git/workspace.toml <<-\EOF
	version = 1

	[[nodes]]
	id = "root"
	path = "."
	required = false
	depends_on = []

	[[nodes]]
	id = "missing"
	path = "missing-repo"
	required = true
	depends_on = ["root"]
	EOF
	(cd work &&
	 if $BIT workspace push >../ws-push-fail.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "workspace push txn:" ws-push-fail.out &&
	grep "partial_failed" ws-push-fail.out &&
	sed -n "s/.*workspace push txn: \\([^ ]*\\).*/\\1/p" ws-push-fail.out | head -n 1 > ws-resume-id.txt &&
	test -s ws-resume-id.txt
'

test_expect_success 'workspace push --resume succeeds after manifest repair' '
	cat > work/.git/workspace.toml <<-\EOF
	version = 1

	[[nodes]]
	id = "root"
	path = "."
	required = false
	depends_on = []

	[[nodes]]
	id = "missing"
	path = "missing-repo"
	required = false
	depends_on = []
	EOF
	txn_id=$(cat ws-resume-id.txt) &&
	(cd work &&
	 $BIT workspace push --resume "$txn_id" >../ws-push-resume.out 2>&1) &&
	grep "workspace push txn: $txn_id" ws-push-resume.out &&
	grep "(completed)" ws-push-resume.out
'

test_done
