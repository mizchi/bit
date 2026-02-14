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

test_expect_success 'init works even if SHIM_REAL_GIT points to false' '
    SHIM_REAL_GIT=false git_cmd init repo &&
    test_dir_exists repo/.git
'

test_expect_success 'config works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=/no/such git_cmd config user.name "bit-test" &&
        test "$(git_cmd config --get user.name)" = "bit-test"
    )
'

test_expect_success 'add missing path reports pathspec even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false test_must_fail git_cmd add missing.txt >out 2>err &&
        grep -q "pathspec" err
    )
'

test_expect_success 'signed commit is explicitly unsupported even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        SHIM_REAL_GIT=false test_must_fail git_cmd commit -S -m "signed" >out 2>err &&
        grep -Eiq "standalone|not supported" err
    )
'

test_expect_success 'update-ref works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        head_oid="$(git_cmd rev-parse HEAD)" &&
        SHIM_REAL_GIT=/no/such git_cmd update-ref refs/heads/smoke "$head_oid" &&
        test "$(git_cmd rev-parse refs/heads/smoke)" = "$head_oid"
    )
'

test_expect_success 'update-ref on reftable is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init --ref-format=reftable repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false test_must_fail git_cmd update-ref refs/heads/smoke 0123456789012345678901234567890123456789 >out 2>err &&
        grep -Eiq "standalone|not supported|reftable" err
    )
'

test_expect_success 'branch works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        head_oid="$(git_cmd rev-parse HEAD)" &&
        SHIM_REAL_GIT=/no/such git_cmd branch smoke "$head_oid" &&
        test "$(git_cmd rev-parse refs/heads/smoke)" = "$head_oid"
		)
'

test_expect_success 'branch listing works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=false git_cmd branch >actual &&
        grep -q "^\* " actual
    )
'

test_expect_success 'tag works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=false git_cmd tag smoke &&
        test "$(git_cmd rev-parse refs/tags/smoke)" = "$(git_cmd rev-parse HEAD)"
    )
'

test_expect_success 'log works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=/no/such git_cmd log --oneline -1 >actual &&
        grep -Eq "^[0-9a-f]{7} " actual
    )
'

test_expect_success 'log --oneline works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=false git_cmd log --oneline >actual &&
        grep -Eq "^[0-9a-f]{7} " actual
    )
'

test_expect_success 'log -1 works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=/no/such git_cmd log -1 >actual &&
        grep -q "^commit [0-9a-f]\\{40\\}$" actual
    )
'

test_expect_success 'checkout works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        git_cmd branch smoke &&
        SHIM_REAL_GIT=/no/such git_cmd checkout smoke &&
        git_cmd branch | grep -q "\\* smoke"
    )
'

test_expect_success 'checkout -b works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=false git_cmd checkout -b smoke &&
        git_cmd branch | grep -q "\\* smoke"
    )
'

test_expect_success 'bisect help works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false git_cmd bisect help >actual &&
        grep -q "usage: git bisect" actual
    )
'

test_expect_success 'submodule status works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false git_cmd submodule status >actual &&
        test_must_be_empty actual
    )
'

test_expect_success 'rebase works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit" &&
        git_cmd checkout -b feature &&
        echo feature >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "feature commit" &&
        git_cmd checkout main &&
        echo main >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "main commit" &&
        git_cmd checkout feature &&
        SHIM_REAL_GIT=false git_cmd rebase main &&
        test "$(git_cmd rev-parse --abbrev-ref HEAD)" = "feature"
    )
'

test_expect_success 'rebase -i is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit" &&
        git_cmd checkout -b feature &&
        echo feature >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "feature commit" &&
        SHIM_REAL_GIT=false test_must_fail git_cmd rebase -i main >out 2>err &&
        grep -Eiq "standalone|not supported|rebase" err
    )
'

test_expect_success 'merge works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        git_cmd config user.name "bit-test" &&
        git_cmd config user.email "bit-test@example.com" &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit" &&
        base_branch="$(git_cmd rev-parse --abbrev-ref HEAD)" &&
        git_cmd checkout -b feature &&
        echo feature >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "feature commit" &&
        git_cmd checkout "$base_branch" &&
        SHIM_REAL_GIT=/no/such git_cmd merge feature &&
        test "$(git_cmd rev-parse HEAD)" = "$(git_cmd rev-parse feature)"
    )
'

test_expect_success 'merge works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        git_cmd config user.name "bit-test" &&
        git_cmd config user.email "bit-test@example.com" &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit" &&
        base_branch="$(git_cmd rev-parse --abbrev-ref HEAD)" &&
        git_cmd checkout -b feature &&
        echo feature >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "feature commit" &&
        git_cmd checkout "$base_branch" &&
        SHIM_REAL_GIT=false git_cmd merge feature &&
        test "$(git_cmd rev-parse HEAD)" = "$(git_cmd rev-parse feature)"
    )
'

test_expect_success 'bundle works even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        git_cmd config user.name "bit-test" &&
        git_cmd config user.email "bit-test@example.com" &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=/no/such git_cmd bundle create ../smoke.bundle HEAD &&
        SHIM_REAL_GIT=/no/such git_cmd bundle list-heads ../smoke.bundle >actual &&
        grep -Eq "^[0-9a-f]{40} HEAD$" actual
	)
'

test_expect_success 'bundle works even if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        git_cmd config user.name "bit-test" &&
        git_cmd config user.email "bit-test@example.com" &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=false git_cmd bundle create ../smoke.bundle HEAD &&
        SHIM_REAL_GIT=false git_cmd bundle list-heads ../smoke.bundle >actual &&
        grep -Eq "^[0-9a-f]{40} HEAD$" actual
    )
'

test_expect_success 'clone works even if SHIM_REAL_GIT points to false' '
    git_cmd init upstream &&
    (
        cd upstream &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit"
    ) &&
    SHIM_REAL_GIT=false git_cmd clone upstream work &&
    test_dir_exists work/.git &&
    test_file_exists work/a.txt
'

test_expect_success 'clone --ref-format=reftable is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init upstream &&
    (
        cd upstream &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit"
    ) &&
    SHIM_REAL_GIT=false test_must_fail git_cmd clone --ref-format=reftable upstream work >out 2>err &&
    grep -Eiq "standalone|not supported|reftable" err
'

test_expect_success 'clone from local bundle is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init upstream &&
    (
        cd upstream &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        git_cmd bundle create ../src.bundle HEAD
    ) &&
    SHIM_REAL_GIT=false test_must_fail git_cmd clone src.bundle work >out 2>err &&
    grep -Eiq "standalone|not supported|bundle" err
'

test_expect_success 'fetch works even if SHIM_REAL_GIT is invalid' '
    git_cmd init upstream &&
    (
        cd upstream &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit"
    ) &&
    git_cmd clone upstream work &&
    (
        cd upstream &&
        echo next >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "next commit" &&
        git_cmd rev-parse HEAD >../expected
    ) &&
    (
        cd work &&
        branch="$(git_cmd rev-parse --abbrev-ref HEAD)" &&
        SHIM_REAL_GIT=/no/such git_cmd fetch origin &&
        test_file_exists .git/FETCH_HEAD &&
        test "$(git_cmd rev-parse "refs/remotes/origin/$branch")" = "$(cat ../expected)"
	)
'

test_expect_success 'fetch works even if SHIM_REAL_GIT points to false' '
    git_cmd init upstream &&
    (
        cd upstream &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit"
    ) &&
    git_cmd clone upstream work &&
    (
        cd upstream &&
        echo next >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "next commit" &&
        git_cmd rev-parse HEAD >../expected
    ) &&
    (
        cd work &&
        branch="$(git_cmd rev-parse --abbrev-ref HEAD)" &&
        SHIM_REAL_GIT=false git_cmd fetch origin &&
        test_file_exists .git/FETCH_HEAD &&
        test "$(git_cmd rev-parse "refs/remotes/origin/$branch")" = "$(cat ../expected)"
    )
'

test_expect_success 'pull works even if SHIM_REAL_GIT is invalid' '
    git_cmd init upstream &&
    (
        cd upstream &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit"
    ) &&
    git_cmd clone upstream work &&
    (
        cd upstream &&
        echo next >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "next commit" &&
        git_cmd rev-parse HEAD >../expected
    ) &&
    (
        cd work &&
        SHIM_REAL_GIT=/no/such git_cmd pull &&
        test "$(git_cmd rev-parse HEAD)" = "$(cat ../expected)"
	)
'

test_expect_success 'pull works even if SHIM_REAL_GIT points to false' '
    git_cmd init upstream &&
    (
        cd upstream &&
        echo base >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "base commit"
    ) &&
    git_cmd clone upstream work &&
    (
        cd upstream &&
        echo next >>a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "next commit" &&
        git_cmd rev-parse HEAD >../expected
    ) &&
    (
        cd work &&
        SHIM_REAL_GIT=false git_cmd pull &&
        test "$(git_cmd rev-parse HEAD)" = "$(cat ../expected)"
    )
'

test_expect_success 'push works even if SHIM_REAL_GIT is invalid' '
    git_cmd init --bare origin.git &&
    git_cmd clone origin.git work &&
    (
        cd work &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        branch="$(git_cmd rev-parse --abbrev-ref HEAD)" &&
        SHIM_REAL_GIT=/no/such git_cmd push origin "HEAD:refs/heads/$branch" &&
        echo "$branch" >../branch_name &&
        git_cmd rev-parse HEAD >../expected
	) &&
	test "$(git_cmd --git-dir=origin.git rev-parse "refs/heads/$(cat branch_name)")" = "$(cat expected)"
'

test_expect_success 'push works even if SHIM_REAL_GIT points to false' '
    git_cmd init --bare origin.git &&
    git_cmd clone origin.git work &&
    (
        cd work &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        branch="$(git_cmd rev-parse --abbrev-ref HEAD)" &&
        SHIM_REAL_GIT=false git_cmd push origin "HEAD:refs/heads/$branch" &&
        echo "$branch" >../branch_name &&
        git_cmd rev-parse HEAD >../expected
    ) &&
    test "$(git_cmd --git-dir=origin.git rev-parse "refs/heads/$(cat branch_name)")" = "$(cat expected)"
'

test_expect_success 'hash-object -w compatObjectFormat=sha256 is explicitly unsupported even if SHIM_REAL_GIT is invalid' '
    git_cmd init repo &&
    (
        cd repo &&
        git_cmd config extensions.compatObjectFormat sha256 &&
        echo hello >a.txt &&
        SHIM_REAL_GIT=/no/such test_must_fail git_cmd hash-object -w a.txt >out 2>err &&
        grep -Eiq "standalone|not supported|compatobjectformat|sha256" err
    )
'

test_expect_success 'hash-object -w compatObjectFormat=sha256 is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        git_cmd config extensions.compatObjectFormat sha256 &&
        echo hello >a.txt &&
        SHIM_REAL_GIT=false test_must_fail git_cmd hash-object -w a.txt >out 2>err &&
        grep -Eiq "standalone|not supported|compatobjectformat|sha256" err
    )
'

test_expect_success 'cat-file --batch-all-objects objectsize:disk is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        echo hello >a.txt &&
        git_cmd add a.txt &&
        git_cmd commit -m "first commit" &&
        SHIM_REAL_GIT=false test_must_fail git_cmd cat-file --batch-check=%\(objectsize:disk\) --batch-all-objects < /dev/null >out 2>err &&
        grep -Eiq "standalone|not supported|objectsize:disk|batch-all-objects" err
    )
'

test_expect_success 'multi-pack-index write --bitmap is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false test_must_fail git_cmd multi-pack-index write --bitmap >out 2>err &&
        grep -Eiq "standalone|not supported|multi-pack-index|bitmap" err
    )
'

test_expect_success 'index-pack unsupported options are explicitly rejected in standalone mode' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false test_must_fail git_cmd index-pack --threads=2 >out 2>err &&
        grep -Eiq "standalone|not supported|unsupported|index-pack" err
    )
'

test_expect_success 'pack-objects unsupported options are explicitly rejected in standalone mode' '
    git_cmd init repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false test_must_fail git_cmd pack-objects --threads=2 out >out 2>err &&
        grep -Eiq "standalone|not supported|unsupported|pack-objects" err
    )
'

test_expect_success 'write-tree on non-sha1 repo is explicitly unsupported if SHIM_REAL_GIT points to false' '
    git_cmd init --object-format=sha256 repo &&
    (
        cd repo &&
        SHIM_REAL_GIT=false test_must_fail git_cmd write-tree >out 2>err &&
        grep -Eiq "standalone|not supported|object format|sha1" err
    )
'

test_done
