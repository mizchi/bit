#!/bin/bash
#
# Test local clone operations
# All tests use git_cmd (--no-git-fallback), no real git required.
# Source repos are also created with git_cmd for full standalone.

source "$(dirname "$0")/test-lib-e2e.sh"

# Helper: create a source repo with a couple of commits
make_source_repo() {
    git_cmd init source &&
    (cd source &&
        echo "file1" > file1.txt &&
        git_cmd add file1.txt &&
        git_cmd commit -m "first commit" &&
        echo "file2" > file2.txt &&
        git_cmd add file2.txt &&
        git_cmd commit -m "second commit"
    )
}

make_source_repo_with_subdir() {
    git_cmd init source &&
    (cd source &&
        mkdir -p vibe/std vibe/encoding docs &&
        echo "std1" > vibe/std/a.vibe &&
        echo "enc1" > vibe/encoding/b.vibe &&
        echo "doc1" > docs/readme.md &&
        git_cmd add -A &&
        git_cmd commit -m "init subdir repo"
    )
}

setup_fake_ssh_command() {
    mkdir -p mock-bin &&
    cat > mock-bin/ssh <<'EOF' &&
#!/bin/sh
log_file="${BIT_TEST_SSH_LOG:-}"
if [ -n "$log_file" ]; then
    printf '%s\n' "$*" >> "$log_file"
fi
host="$1"
shift
if [ "${1:-}" = "env" ]; then
    shift
    export "$1"
    shift
fi
cmd="$1"
shift
exec "$cmd" "$@"
EOF
    chmod +x mock-bin/ssh &&
    export PATH="$(pwd)/mock-bin:$PATH"
}

# =============================================================================
# Basic clone (4)
# =============================================================================

test_expect_success 'clone local repo creates working copy' '
    make_source_repo &&
    git_cmd clone source dest &&
    test_dir_exists dest/.git &&
    test_file_exists dest/file1.txt &&
    test_file_exists dest/file2.txt
'

test_expect_success 'clone sets up origin remote config' '
    make_source_repo &&
    git_cmd clone source dest &&
    git_cmd -C dest remote -v > out &&
    grep -q "origin" out
'

test_expect_success 'clone checkout matches source HEAD content' '
    make_source_repo &&
    git_cmd clone source dest &&
    diff source/file1.txt dest/file1.txt &&
    diff source/file2.txt dest/file2.txt
'

test_expect_success 'clone --bare creates bare repository' '
    make_source_repo &&
    git_cmd clone --bare source dest.git &&
    test_file_exists dest.git/HEAD &&
    test_dir_exists dest.git/objects &&
    test_dir_exists dest.git/refs &&
    test_path_is_missing dest.git/file1.txt
'

test_expect_success 'clone -n does not checkout files' '
    make_source_repo &&
    git_cmd clone -n source dest &&
    test_dir_exists dest/.git &&
    test_path_is_missing dest/file1.txt &&
    test_path_is_missing dest/file2.txt &&
    git_cmd -C dest rev-parse HEAD >/dev/null
'

test_expect_success 'clone fails with excess positional args' '
    make_source_repo &&
    test_must_fail git_cmd clone -n source dest extra
'

# =============================================================================
# History and branches (3)
# =============================================================================

test_expect_success 'clone preserves commit history' '
    make_source_repo &&
    git_cmd clone source dest &&
    src_count=$(git_cmd -C source log --oneline | wc -l | tr -d " ") &&
    dst_count=$(git_cmd -C dest log --oneline | wc -l | tr -d " ") &&
    test "$src_count" = "$dst_count"
'

test_expect_success 'clone preserves multiple branches in packed-refs' '
    make_source_repo &&
    (cd source && git_cmd branch feature) &&
    git_cmd clone source dest &&
    grep -q "refs/remotes/origin/feature" dest/.git/packed-refs
'

test_skip 'clone with -b checks out specified branch' 'clone -b not yet supported'

# =============================================================================
# Directory creation (3)
# =============================================================================

test_expect_success 'clone creates new directory automatically' '
    make_source_repo &&
    test_path_is_missing mydir &&
    git_cmd clone source mydir &&
    test_dir_exists mydir/.git
'

test_expect_success 'clone deep path (a/b/c)' '
    make_source_repo &&
    test_path_is_missing a &&
    git_cmd clone source a/b/c &&
    test_dir_exists a/b/c/.git &&
    test_file_exists a/b/c/file1.txt
'

test_expect_success 'clone local bare repo as source' '
    make_source_repo &&
    git_cmd clone --bare source bare.git &&
    git_cmd clone bare.git dest &&
    test_file_exists dest/file1.txt &&
    test_file_exists dest/file2.txt
'

test_expect_success 'clone file:// local repo works' '
    make_source_repo &&
    git_cmd clone "file://$(pwd)/source" dest &&
    test_dir_exists dest/.git &&
    test_file_exists dest/file1.txt &&
    test_file_exists dest/file2.txt
'

test_expect_success 'clone ./local repo works' '
    make_source_repo &&
    git_cmd clone ./source dest &&
    test_dir_exists dest/.git &&
    test_file_exists dest/file1.txt &&
    test_file_exists dest/file2.txt
'

test_expect_success 'clone absolute local path works' '
    make_source_repo &&
    git_cmd clone "$(pwd)/source" dest &&
    test_dir_exists dest/.git &&
    test_file_exists dest/file1.txt &&
    test_file_exists dest/file2.txt
'

test_expect_success 'clone git@host:path via ssh transport works' '
    command -v git-upload-pack >/dev/null &&
    make_source_repo &&
    git_cmd clone --bare source source.git &&
    setup_fake_ssh_command &&
    export BIT_TEST_SSH_LOG="$(pwd)/ssh.log" &&
    git_cmd clone "git@localhost:$(pwd)/source.git" dest &&
    test_dir_exists dest/.git &&
    test_file_exists dest/file1.txt &&
    test_file_exists dest/file2.txt &&
    test_grep "git-upload-pack" "$BIT_TEST_SSH_LOG"
'

test_expect_success 'subdir-clone local path works' '
    make_source_repo_with_subdir &&
    git_cmd subdir-clone source vibe out &&
    test_dir_exists out/.git &&
    test_file_exists out/std/a.vibe &&
    test_file_exists out/encoding/b.vibe &&
    test_path_is_missing out/docs/readme.md
'

test_expect_success 'subdir-clone file:// local repo works' '
    make_source_repo_with_subdir &&
    git_cmd subdir-clone "file://$(pwd)/source" vibe out &&
    test_dir_exists out/.git &&
    test_file_exists out/std/a.vibe &&
    test_file_exists out/encoding/b.vibe &&
    test_path_is_missing out/docs/readme.md
'

# =============================================================================
# Edge cases (2)
# =============================================================================

test_expect_success 'clone detached HEAD source' '
    make_source_repo &&
    (cd source &&
        first_hash=$(git_cmd rev-parse HEAD~1) &&
        git_cmd checkout "$first_hash"
    ) &&
    git_cmd clone source dest &&
    test_file_exists dest/file1.txt
'

test_skip 'clone empty repo (no commits yet)' 'empty repo clone not yet supported'

test_done
