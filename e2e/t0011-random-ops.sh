#!/bin/bash
#
# Randomized operation log applied to git and bit, compare trees and fsck

source "$(dirname "$0")/test-lib.sh"

LCG_STATE=0
RAND_VALUE=0

lcg_next() {
    LCG_STATE=$(( (LCG_STATE * 1103515245 + 12345) & 0x7fffffff ))
}

rand_range() {
    local n="$1"
    if [ "$n" -le 0 ]; then
        RAND_VALUE=0
        return
    fi
    lcg_next
    RAND_VALUE=$(( LCG_STATE % n ))
}

gen_ops() {
    local seed="$1"
    local steps="$2"
    local max_branches="$3"
    local out="$4"

    LCG_STATE="$seed"

    declare -a branches
    declare -A next_id
    declare -A last_file

    branches=("main")
    next_id["main"]=0
    last_file["main"]=""

    local cur="main"
    local branch_seq=1

    echo "init" > "$out"

    local file="${cur}_${next_id[$cur]}.txt"
    next_id[$cur]=$((next_id[$cur] + 1))
    last_file[$cur]="$file"
    echo "commit-new $file seed${seed}_0" >> "$out"

    local step=1
    while [ "$step" -le "$steps" ]; do
        local op
        rand_range 6
        op=$RAND_VALUE
        case "$op" in
            0)
                file="${cur}_${next_id[$cur]}.txt"
                next_id[$cur]=$((next_id[$cur] + 1))
                last_file[$cur]="$file"
                echo "commit-new $file seed${seed}_${step}" >> "$out"
                ;;
            1)
                if [ -n "${last_file[$cur]}" ]; then
                    echo "commit-mod ${last_file[$cur]} seed${seed}_${step}" >> "$out"
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            2)
                if [ -n "${last_file[$cur]}" ]; then
                    echo "commit-rm ${last_file[$cur]}" >> "$out"
                    last_file[$cur]=""
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            3)
                if [ "${#branches[@]}" -lt "$max_branches" ]; then
                    local b="b${branch_seq}"
                    branch_seq=$((branch_seq + 1))
                    branches+=("$b")
                    next_id["$b"]=0
                    last_file["$b"]=""
                    echo "branch $b" >> "$out"
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            4)
                if [ "${#branches[@]}" -gt 1 ]; then
                    local idx
                    rand_range "${#branches[@]}"
                    idx=$RAND_VALUE
                    local target="${branches[$idx]}"
                    if [ "$target" = "$cur" ]; then
                        idx=$(( (idx + 1) % ${#branches[@]} ))
                        target="${branches[$idx]}"
                    fi
                    echo "switch $target" >> "$out"
                    cur="$target"
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
            5)
                if [ "$cur" = "main" ] && [ "${#branches[@]}" -gt 1 ]; then
                    local idx
                    rand_range "${#branches[@]}"
                    idx=$RAND_VALUE
                    local target="${branches[$idx]}"
                    if [ "$target" = "$cur" ]; then
                        idx=$(( (idx + 1) % ${#branches[@]} ))
                        target="${branches[$idx]}"
                    fi
                    echo "merge $target" >> "$out"
                else
                    file="${cur}_${next_id[$cur]}.txt"
                    next_id[$cur]=$((next_id[$cur] + 1))
                    last_file[$cur]="$file"
                    echo "commit-new $file seed${seed}_${step}" >> "$out"
                fi
                ;;
        esac
        step=$((step + 1))
    done
}

apply_ops() {
    local tool="$1"
    local repo="$2"
    local opfile="$3"

    local run_cmd
    if [ "$tool" = "git" ]; then
        run_cmd="git"
    else
        run_cmd="git_cmd"
    fi

    local base_date=1700000000
    local commit_seq=0

    mkdir -p "$repo"
    local old_dir
    old_dir=$(pwd)
    cd "$repo"

    while read -r op arg1 arg2; do
        case "$op" in
            init)
                $run_cmd init
                ;;
            branch)
                $run_cmd branch "$arg1"
                ;;
            switch)
                $run_cmd switch "$arg1"
                ;;
            merge)
                local ts=$((base_date + commit_seq))
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd merge -m "merge $arg1" "$arg1"
                commit_seq=$((commit_seq + 1))
                ;;
            commit-new)
                local ts=$((base_date + commit_seq))
                echo "$arg2" > "$arg1"
                $run_cmd add "$arg1"
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "commit $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            commit-mod)
                local ts=$((base_date + commit_seq))
                echo "$arg2" >> "$arg1"
                $run_cmd add "$arg1"
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "commit $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            commit-rm)
                local ts=$((base_date + commit_seq))
                $run_cmd rm "$arg1"
                GIT_AUTHOR_DATE="${ts} +0000" GIT_COMMITTER_DATE="${ts} +0000" \
                    $run_cmd commit -m "commit $commit_seq"
                commit_seq=$((commit_seq + 1))
                ;;
            *)
                echo "unknown op: $op" >&2
                return 1
                ;;
        esac
    done < "$opfile"

    cd "$old_dir"
}

compare_repos() {
    local repo_git="$1"
    local repo_bit="$2"

    git -C "$repo_git" fsck --strict
    git -C "$repo_bit" fsck --strict

    local heads_git
    local heads_bit
    heads_git=$(git -C "$repo_git" for-each-ref --format='%(refname:short)' refs/heads | sort)
    heads_bit=$(git -C "$repo_bit" for-each-ref --format='%(refname:short)' refs/heads | sort)

    [ "$heads_git" = "$heads_bit" ]

    local b
    for b in $heads_git; do
        local tree_git
        local tree_bit
        tree_git=$(git -C "$repo_git" rev-parse "$b^{tree}")
        tree_bit=$(git -C "$repo_bit" rev-parse "$b^{tree}")
        [ "$tree_git" = "$tree_bit" ]
    done

    local status_git
    local status_bit
    status_git=$(git -C "$repo_git" status --porcelain)
    status_bit=$(git -C "$repo_bit" status --porcelain)
    [ -z "$status_git" ]
    [ -z "$status_bit" ]
}

run_case() {
    local seed="$1"
    local steps="$2"
    local max_branches="$3"
    local work="$TRASH_DIR/work_$seed"
    mkdir -p "$work"

    local ops="$work/ops.log"
    gen_ops "$seed" "$steps" "$max_branches" "$ops"

    apply_ops git "$work/repo_git" "$ops"
    apply_ops bit "$work/repo_bit" "$ops"

    compare_repos "$work/repo_git" "$work/repo_bit"
}

test_expect_success 'random ops seed=1' '
    run_case 1 25 3
'

test_expect_success 'random ops seed=2' '
    run_case 2 25 3
'

test_expect_success 'random ops seed=3' '
    run_case 3 25 3
'

test_done
