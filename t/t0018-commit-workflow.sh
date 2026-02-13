#!/bin/bash
#
# Test commit workflow: add, commit, status, log, diff, rm, reset
# All tests use git_cmd (--no-git-fallback), no real git required.

source "$(dirname "$0")/test-lib-e2e.sh"

# =============================================================================
# Group 1: add + commit (7)
# =============================================================================

test_expect_success 'add single file and commit with -m' '
    git_cmd init &&
    echo "hello" > file.txt &&
    git_cmd add file.txt &&
    git_cmd commit -m "add file" &&
    git_cmd log | grep -q "add file"
'

test_expect_success 'add multiple files' '
    git_cmd init &&
    echo "a" > a.txt &&
    echo "b" > b.txt &&
    echo "c" > c.txt &&
    git_cmd add a.txt b.txt c.txt &&
    git_cmd ls-files > ls_out &&
    grep -q "a.txt" ls_out &&
    grep -q "b.txt" ls_out &&
    grep -q "c.txt" ls_out
'

test_expect_success 'add -A stages untracked, modified, and deleted' '
    git_cmd init &&
    echo "keep" > keep.txt &&
    echo "delete" > delete.txt &&
    git_cmd add keep.txt delete.txt &&
    git_cmd commit -m "initial" &&
    echo "modified" > keep.txt &&
    rm delete.txt &&
    echo "new" > new.txt &&
    git_cmd add -A &&
    git_cmd status --porcelain > status_out &&
    grep -q "M  keep.txt" status_out &&
    grep -q "D  delete.txt" status_out &&
    grep -q "A  new.txt" status_out
'

test_expect_success 'commit -a stages modified and commits' '
    git_cmd init &&
    echo "original" > file.txt &&
    git_cmd add file.txt &&
    git_cmd commit -m "initial" &&
    echo "changed" > file.txt &&
    git_cmd commit -a -m "auto stage" &&
    git_cmd log | grep -q "auto stage" &&
    git_cmd status | grep -q "nothing to commit"
'

test_expect_success 'commit --allow-empty creates empty commit' '
    git_cmd init &&
    echo "x" > x.txt &&
    git_cmd add x.txt &&
    git_cmd commit -m "first" &&
    git_cmd commit --allow-empty -m "empty commit" &&
    git_cmd log --oneline > log_out &&
    grep -q "empty commit" log_out
'

test_expect_success 'commit --amend changes last commit message' '
    git_cmd init &&
    echo "a" > a.txt &&
    git_cmd add a.txt &&
    git_cmd commit -m "original msg" &&
    git_cmd commit --amend -m "amended msg" &&
    git_cmd log --oneline > log_out &&
    grep -q "amended msg" log_out &&
    ! grep -q "original msg" log_out
'

test_expect_success 'commit --amend preserves tree when no staged changes' '
    git_cmd init &&
    echo "content" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "first" &&
    tree_before=$(git_cmd cat-file -p HEAD | grep "^tree " | cut -d" " -f2) &&
    git_cmd commit --amend -m "new message" &&
    tree_after=$(git_cmd cat-file -p HEAD | grep "^tree " | cut -d" " -f2) &&
    test "$tree_before" = "$tree_after"
'

test_expect_success 'commit runs pre-commit hook and aborts on non-zero exit' '
    git_cmd init src &&
    echo "base" > src/base.txt &&
    (
        cd src &&
        git_cmd add base.txt &&
        git_cmd commit -m "base"
    ) &&
    git_cmd init dst &&
    cat > dst/.git/hooks/pre-commit <<-\EOF &&
#!/bin/sh
git clone ../src ../cloned-from-hook
exit 1
EOF
    chmod +x dst/.git/hooks/pre-commit &&
    echo "work" > dst/work.txt &&
    (
        cd dst &&
        git_cmd add work.txt &&
        test_must_fail git_cmd commit -m "blocked by hook"
    ) &&
    test_dir_exists cloned-from-hook &&
    test_file_exists cloned-from-hook/base.txt
'

# =============================================================================
# Group 2: status formats (5)
# =============================================================================

test_expect_success 'status --porcelain shows XY format' '
    git_cmd init &&
    echo "new" > new.txt &&
    git_cmd add new.txt &&
    git_cmd status --porcelain > out &&
    grep -q "^A" out
'

test_expect_success 'status -s short format' '
    git_cmd init &&
    echo "new" > new.txt &&
    git_cmd add new.txt &&
    git_cmd status -s > out &&
    grep -q "new.txt" out
'

test_expect_success 'status -sb shows branch name' '
    git_cmd init &&
    echo "x" > x.txt &&
    git_cmd add x.txt &&
    git_cmd commit -m "init" &&
    git_cmd status -sb > out &&
    grep -q "^##" out
'

test_expect_success 'status distinguishes staged vs unstaged' '
    git_cmd init &&
    echo "orig" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "init" &&
    echo "staged change" > f.txt &&
    git_cmd add f.txt &&
    echo "unstaged change" > f.txt &&
    git_cmd status --porcelain > out &&
    grep -q "^MM" out
'

test_expect_success 'status clean after all committed' '
    git_cmd init &&
    echo "a" > a.txt &&
    git_cmd add a.txt &&
    git_cmd commit -m "done" &&
    git_cmd status | grep -q "nothing to commit"
'

# =============================================================================
# Group 3: log (4)
# =============================================================================

test_expect_success 'log shows commits in reverse chronological order' '
    git_cmd init &&
    echo "1" > f.txt &&
    git_cmd add f.txt &&
    GIT_COMMITTER_DATE="1000000000" git_cmd commit -m "first" &&
    echo "2" > f.txt &&
    git_cmd add f.txt &&
    GIT_COMMITTER_DATE="1000000001" git_cmd commit -m "second" &&
    git_cmd log > log_out &&
    first_pos=$(grep -n "second" log_out | head -1 | cut -d: -f1) &&
    second_pos=$(grep -n "first" log_out | head -1 | cut -d: -f1) &&
    test "$first_pos" -lt "$second_pos"
'

test_expect_success 'log --oneline compact format' '
    git_cmd init &&
    echo "x" > x.txt &&
    git_cmd add x.txt &&
    git_cmd commit -m "my commit" &&
    git_cmd log --oneline > out &&
    line_count=$(wc -l < out) &&
    test "$line_count" -eq 1 &&
    grep -q "my commit" out
'

test_expect_success 'log -N limits output count' '
    git_cmd init &&
    echo "1" > f.txt && git_cmd add f.txt && git_cmd commit -m "c1" &&
    echo "2" > f.txt && git_cmd add f.txt && git_cmd commit -m "c2" &&
    echo "3" > f.txt && git_cmd add f.txt && git_cmd commit -m "c3" &&
    git_cmd log -2 --oneline > out &&
    line_count=$(wc -l < out) &&
    test "$line_count" -eq 2
'

test_expect_success 'log --format=%h shows short hash' '
    git_cmd init &&
    echo "x" > x.txt &&
    git_cmd add x.txt &&
    git_cmd commit -m "test" &&
    git_cmd log --format=%h > out &&
    hash=$(cat out | head -1 | tr -d " \n") &&
    len=${#hash} &&
    test "$len" -ge 7 &&
    test "$len" -le 12
'

# =============================================================================
# Group 4: diff (4)
# =============================================================================

test_expect_success 'diff shows unstaged changes' '
    git_cmd init &&
    echo "original" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "init" &&
    echo "changed" > f.txt &&
    git_cmd diff > out &&
    grep -q "changed" out
'

test_expect_success 'diff --cached shows staged changes' '
    git_cmd init &&
    echo "original" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "init" &&
    echo "staged" > f.txt &&
    git_cmd add f.txt &&
    git_cmd diff --cached > out &&
    grep -q "staged" out
'

test_expect_success 'diff --name-only lists changed files' '
    git_cmd init &&
    echo "a" > a.txt &&
    echo "b" > b.txt &&
    git_cmd add a.txt b.txt &&
    git_cmd commit -m "init" &&
    echo "aa" > a.txt &&
    echo "bb" > b.txt &&
    git_cmd diff --name-only > out &&
    grep -q "a.txt" out &&
    grep -q "b.txt" out
'

test_expect_success 'diff --stat shows statistics' '
    git_cmd init &&
    echo "hello world" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "init" &&
    echo "goodbye world" > f.txt &&
    git_cmd diff --stat > out &&
    grep -q "f.txt" out &&
    grep -q "1" out
'

# =============================================================================
# Group 5: rm (2)
# =============================================================================

test_expect_success 'rm --cached removes from index but keeps file' '
    git_cmd init &&
    echo "keep me" > file.txt &&
    git_cmd add file.txt &&
    git_cmd commit -m "init" &&
    git_cmd rm --cached file.txt &&
    test_file_exists file.txt &&
    git_cmd status --porcelain > out &&
    grep -q "^D" out
'

test_expect_success 'rm removes file and stages deletion' '
    git_cmd init &&
    echo "remove me" > file.txt &&
    git_cmd add file.txt &&
    git_cmd commit -m "init" &&
    git_cmd rm file.txt &&
    test_path_is_missing file.txt &&
    git_cmd status --porcelain > out &&
    grep -q "^D" out
'

# =============================================================================
# Group 6: reset (3)
# =============================================================================

test_expect_success 'reset HEAD unstages all (mixed default)' '
    git_cmd init &&
    echo "a" > a.txt &&
    git_cmd add a.txt &&
    git_cmd commit -m "init" &&
    echo "changed" > a.txt &&
    git_cmd add a.txt &&
    git_cmd reset HEAD &&
    git_cmd status --porcelain | grep -q "^ M"
'

test_expect_success 'reset --soft keeps staged changes' '
    git_cmd init &&
    echo "1" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "first" &&
    echo "2" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "second" &&
    git_cmd reset --soft HEAD~1 &&
    git_cmd status --porcelain > out &&
    grep -q "^M" out
'

test_expect_success 'reset --hard discards working tree changes' '
    git_cmd init &&
    echo "original" > f.txt &&
    git_cmd add f.txt &&
    git_cmd commit -m "init" &&
    echo "dirty" > f.txt &&
    git_cmd reset --hard HEAD &&
    content=$(cat f.txt) &&
    test "$content" = "original"
'

test_done
