#!/bin/sh
#
# Regression tests for multi-pack-index corruption detection
#

test_description='multi-pack-index corruption regressions'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

if test -x "$BIT_BUILD_DIR/target/native/release/build/cmd/bit/bit.exe"; then
	BIT="$BIT_BUILD_DIR/target/native/release/build/cmd/bit/bit.exe"
elif test -x "$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit.exe"; then
	BIT="$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit.exe"
elif test -x "$BIT_BUILD_DIR/tools/git-shim/moon"; then
	BIT="$BIT_BUILD_DIR/tools/git-shim/moon"
fi

if ! test_have_prereq GIT; then
	test_skip "midx corruption regression" "git not found"
	test_done
	exit 0
fi

test_expect_success 'setup: repository with pack and midx' '
	mkdir repo &&
	(
		cd repo &&
		git init &&
		git config user.email "test@test.com" &&
		git config user.name "Test" &&
		echo "base" > file.txt &&
		git add file.txt &&
		git commit -m "base" &&
		git repack -ad &&
		$BIT multi-pack-index write &&
		test -f .git/objects/pack/multi-pack-index
	)
'

test_expect_success 'verify succeeds on clean midx' '
	(
		cd repo &&
		$BIT multi-pack-index verify
	)
'

test_expect_success 'verify detects checksum corruption' '
	(
		cd repo &&
		midx=.git/objects/pack/multi-pack-index &&
		cp "$midx" "$midx.bak" &&
		size=$(wc -c <"$midx") &&
		pos=$((size - 10)) &&
		printf "\377\377\377\377\377\377\377\377\377\377" |
			dd of="$midx" bs=1 seek="$pos" conv=notrunc >/dev/null 2>&1 &&
		! $BIT multi-pack-index verify 2>err &&
		grep "incorrect checksum" err &&
		mv "$midx.bak" "$midx"
	)
'

test_expect_success 'verify detects chunk table corruption' '
	(
		cd repo &&
		midx=.git/objects/pack/multi-pack-index &&
		cp "$midx" "$midx.bak" &&
		printf "\001" | dd of="$midx" bs=1 seek=6 conv=notrunc >/dev/null 2>&1 &&
		! $BIT multi-pack-index verify 2>err &&
		grep "final chunk has non-zero id" err &&
		mv "$midx.bak" "$midx"
	)
'

test_expect_success 'write fails when pack is missing but midx exists' '
	(
		cd repo &&
		pack=$(ls .git/objects/pack/pack-*.pack) &&
		mv "$pack" "$pack.bak" &&
		! $BIT multi-pack-index write 2>err &&
		grep "could not load pack" err &&
		mv "$pack.bak" "$pack"
	)
'

test_done
