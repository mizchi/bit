#!/bin/sh
set -eu

usage() {
	echo "usage: $0 <target-dir>" >&2
	exit 1
}

target_dir="${1:-}"
test -n "$target_dir" || usage

mkdir -p "$target_dir"

init_repo() {
	repo_dir="$1"
	file_name="$2"
	file_content="$3"
	commit_message="$4"

	mkdir -p "$repo_dir"
	(
		cd "$repo_dir"
		git init -q
		git config user.email "fixture@example.com"
		git config user.name "Fixture User"
		printf "%s\n" "$file_content" > "$file_name"
		git add "$file_name"
		git commit -q -m "$commit_message"
	)
}

init_repo "$target_dir" "root.txt" "root-v1" "root init"
init_repo "$target_dir/dep" "dep.txt" "dep-v1" "dep init"
init_repo "$target_dir/leaf" "leaf.txt" "leaf-v1" "leaf init"
init_repo "$target_dir/extra" "extra.txt" "extra-v1" "extra init"
