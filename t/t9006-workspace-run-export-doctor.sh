#!/bin/sh
#
# Test workspace run/export/doctor behavior with multiple nodes
#

test_description='workspace run --affected, export metadata, and doctor validation'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: create root repository and child repositories' '
	mkdir ws &&
	(cd ws &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "root" > root.txt &&
	 git add root.txt &&
	 git commit -m "root init") &&
	mkdir ws/pkg ws/extra &&
	(cd ws/pkg &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "pkg" > pkg.txt &&
	 git add pkg.txt &&
	 git commit -m "pkg init") &&
	(cd ws/extra &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "extra" > extra.txt &&
	 git add extra.txt &&
	 git commit -m "extra init")
'

test_expect_success 'setup: initialize workspace and write multi-node manifest' '
	(cd ws &&
	 $BIT workspace init >../ws-init.out 2>&1 &&
	 cat > .git/workspace.toml <<-\EOF
	version = 1

	[[nodes]]
	id = "root"
	path = "."
	required = true
	depends_on = []
	task.smoke = "echo root >> .ws-run.log"

	[[nodes]]
	id = "pkg"
	path = "pkg"
	required = true
	depends_on = ["root"]
	task.smoke = "echo pkg >> .ws-run.log"

	[[nodes]]
	id = "extra"
	path = "extra"
	required = true
	depends_on = []
	task.smoke = "echo extra >> .ws-run.log"
	EOF
	 if $BIT workspace commit --allow-empty -m "workspace baseline" >../ws-baseline-commit.out 2>&1; then
	   true
	 else
	   true
	 fi &&
	 $BIT workspace status >../ws-status.out 2>&1) &&
	grep "workspace root:" ws-status.out &&
	grep "pkg" ws-status.out &&
	grep "extra" ws-status.out
'

test_expect_success 'workspace run smoke executes configured tasks on all nodes' '
	(cd ws &&
	 $BIT workspace run smoke >../ws-run-all.out 2>&1) &&
	test_path_is_file ws/.ws-run.log &&
	test_path_is_file ws/pkg/.ws-run.log &&
	test_path_is_file ws/extra/.ws-run.log &&
	grep "root" ws/.ws-run.log &&
	grep "pkg" ws/pkg/.ws-run.log &&
	grep "extra" ws/extra/.ws-run.log
'

test_expect_success 'workspace run --affected excludes unrelated node' '
	rm -f ws/.ws-run.log ws/pkg/.ws-run.log ws/extra/.ws-run.log &&
	echo "dirty" >> ws/pkg/pkg.txt &&
	(cd ws &&
	 $BIT workspace run smoke --affected >../ws-run-affected.out 2>&1) &&
	test_path_is_file ws/.ws-run.log &&
	test_path_is_file ws/pkg/.ws-run.log &&
	test_path_is_missing ws/extra/.ws-run.log
'

test_expect_success 'workspace export writes git-interop metadata' '
	(cd ws &&
	 $BIT workspace export --format git-interop >../ws-export.out 2>&1) &&
	test_path_is_file ws/.git/workspace.git-interop.json &&
	grep "bit.workspace.git-interop.v1" ws/.git/workspace.git-interop.json &&
	grep "\"id\": \"root\"" ws/.git/workspace.git-interop.json &&
	grep "\"id\": \"pkg\"" ws/.git/workspace.git-interop.json &&
	grep "\"id\": \"extra\"" ws/.git/workspace.git-interop.json
'

test_expect_success 'workspace doctor reports ok on healthy manifest' '
	(cd ws &&
	 $BIT workspace doctor >../ws-doctor-ok.out 2>&1) &&
	grep "workspace doctor: ok" ws-doctor-ok.out
'

test_expect_success 'workspace doctor fails on unknown dependency' '
	(cat > ws/.git/workspace.toml <<-\EOF
	version = 1

	[[nodes]]
	id = "root"
	path = "."
	required = true
	depends_on = ["missing-dependency"]
	EOF
	) &&
	(cd ws &&
	 if $BIT workspace doctor >../ws-doctor-fail.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "depends on unknown node" ws-doctor-fail.out
'

test_done
