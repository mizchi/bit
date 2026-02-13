#!/bin/bash
#
# Test git plumbing commands: cat-file, ls-files, hash-object, etc.

source "$(dirname "$0")/test-lib-e2e.sh"

test_expect_success 'git hash-object computes sha1' '
    git_cmd init &&
    echo "test content" > test.txt &&
    hash=$(git_cmd hash-object test.txt) &&
    test -n "$hash" &&
    test ${#hash} -eq 40
'

test_expect_success 'git hash-object -w writes object' '
    git_cmd init &&
    echo "test content" > test.txt &&
    hash=$(git_cmd hash-object -w test.txt) &&
    test -f ".git/objects/${hash:0:2}/${hash:2}"
'

test_expect_success 'git cat-file -t shows object type' '
    git_cmd init &&
    echo "test content" > test.txt &&
    hash=$(git_cmd hash-object -w test.txt) &&
    type=$(git_cmd cat-file -t "$hash") &&
    test "$type" = "blob"
'

test_expect_success 'git cat-file -s shows object size' '
    git_cmd init &&
    echo "test content" > test.txt &&
    hash=$(git_cmd hash-object -w test.txt) &&
    size=$(git_cmd cat-file -s "$hash") &&
    test "$size" -gt 0
'

test_expect_success 'git cat-file -p shows blob content' '
    git_cmd init &&
    echo "test content" > test.txt &&
    hash=$(git_cmd hash-object -w test.txt) &&
    git_cmd cat-file -p "$hash" | grep -q "test content"
'

test_expect_success 'git ls-files shows staged files' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd ls-files | grep -q "test.txt"
'

test_expect_success 'git ls-files -s shows staged files with hash' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd ls-files -s | grep -q "100644"
'

test_expect_success 'git ls-files -s respects pathspec filter' '
    git_cmd init &&
    mkdir -p dir1 dir2 &&
    echo "one" > dir1/one.txt &&
    echo "two" > dir2/two.txt &&
    git_cmd add dir1/one.txt dir2/two.txt &&
    git_cmd ls-files -s dir1/one.txt > out &&
    test "$(wc -l < out)" -eq 1 &&
    grep -q "dir1/one.txt" out &&
    ! grep -q "dir2/two.txt" out
'

test_expect_success 'git write-tree creates tree from index' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    tree=$(git_cmd write-tree) &&
    test -n "$tree" &&
    test ${#tree} -eq 40
'

test_expect_success 'git ls-tree shows tree entries' '
    git_cmd init &&
    echo "hello" > test.txt &&
    git_cmd add test.txt &&
    git_cmd commit -m "first commit" &&
    head=$(git_cmd rev-parse HEAD) &&
    commit_tree=$(git_cmd cat-file -p "$head" | grep "^tree" | cut -d" " -f2) &&
    git_cmd ls-tree "$commit_tree" | grep -q "test.txt"
'

test_done
