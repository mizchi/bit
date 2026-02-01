#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_dir="$root/tools/git-patches"
repo="$root/third_party/git"

if [ ! -d "$patch_dir" ]; then
  exit 0
fi

shopt -s nullglob
for patch in "$patch_dir"/*.patch; do
  if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "git test patch already applied: $(basename "$patch")"
    continue
  fi
  if git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
    git -C "$repo" apply --whitespace=nowarn "$patch"
    echo "applied git test patch: $(basename "$patch")"
    continue
  fi
  echo "git test patch failed to apply: $patch" >&2
  exit 1
done
