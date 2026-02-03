# MoonBit Project Commands

# Default task: check and test
default: check test

# Format code
fmt:
    moon fmt

# Type check (both js and native)
check:
    moon check --deny-warn --target js
    moon check --deny-warn --target native

# Run tests (js target: main packages only, native: all)
test:
    moon test --target js -p mizchi/bit -p mizchi/bit/lib
    moon test --target native

# Update snapshot tests (both js and native)
test-update:
    moon test --update --target js -p mizchi/bit -p mizchi/bit/lib
    moon test --update --target native

# Run main (native)
run:
    moon run src/main --target native

# Generate type definition files
info:
    moon info

# Clean build artifacts
clean:
    moon clean

# Build native binary
build:
    moon build --target native

# Install bit to ~/.local/bin
install: build
    @mkdir -p ~/.local/bin
    @cp _build/native/release/build/cmd/bit/bit.exe ~/.local/bin/bit
    @chmod +x ~/.local/bin/bit
    @echo "Installed bit to ~/.local/bin/bit"

# Uninstall bit
uninstall:
    @rm -f ~/.local/bin/bit
    @echo "Removed ~/.local/bin/bit"

# Run e2e tests (bit integration tests)
e2e:
    bash e2e/run-tests.sh

# Run subdir-clone/push integration tests (t/ directory)
test-subdir:
    @bash t/run-tests.sh

# Pre-release check
release-check: fmt info check test e2e

# Run Git's upstream test suite (submodule at third_party/git)
git-t:
    @tools/apply-git-test-patches.sh
    make -C third_party/git test

# Run pack-related Git tests (useful as an oracle for pack behavior)
git-t-pack:
    @tools/apply-git-test-patches.sh
    make -C third_party/git test T='t5300-pack-object.sh t5302-pack-index.sh t5303-pack-corruption-resilience.sh t5315-pack-objects-compression.sh t5316-pack-delta-depth.sh t5351-unpack-large-objects.sh'

# Run a broader pack/idx/bitmap test set
git-t-pack-more:
    @tools/apply-git-test-patches.sh
    make -C third_party/git test T='t5300-pack-object.sh t5302-pack-index.sh t5303-pack-corruption-resilience.sh t5306-pack-nobase.sh t5307-pack-missing-commit.sh t5308-pack-detect-duplicates.sh t5309-pack-delta-cycles.sh t5310-pack-bitmaps.sh t5311-pack-bitmaps-shallow.sh t5313-pack-bounds-checks.sh t5314-pack-cycle-detection.sh t5315-pack-objects-compression.sh t5316-pack-delta-depth.sh t5319-multi-pack-index.sh t5321-pack-large-objects.sh t5326-multi-pack-bitmaps.sh t5327-multi-pack-bitmaps-rev.sh t5329-pack-objects-cruft.sh t5331-pack-objects-stdin.sh t5332-multi-pack-reuse.sh t5334-incremental-multi-pack-index.sh t5351-unpack-large-objects.sh'

# Run protocol/fetch/push logic-heavy tests (no network dependencies)
git-t-hard:
    @tools/apply-git-test-patches.sh
    make -C third_party/git test T='t5500-fetch-pack.sh t5504-fetch-receive-strict.sh t5512-ls-remote.sh t5515-fetch-merge-logic.sh t5516-fetch-push.sh t5528-push-default.sh t5529-push-errors.sh t5533-push-cas.sh t5535-fetch-push-symref.sh t5537-fetch-shallow.sh t5538-push-shallow.sh t5700-protocol-v1.sh t5702-protocol-v2.sh t5703-upload-pack-ref-in-want.sh t5704-protocol-violations.sh t5705-session-id-in-capabilities.sh'

# Run additional fetch/push edge cases (includes refspec, multi-remote, and http shallow)
git-t-hard-more:
    @tools/apply-git-test-patches.sh
    make -C third_party/git test T='t5510-fetch.sh t5511-refspec.sh t5513-fetch-track.sh t5514-fetch-multiple.sh t5518-fetch-exit-status.sh t5525-fetch-tagopt.sh t5527-fetch-odd-refs.sh t5530-upload-pack-error.sh t5536-fetch-conflicts.sh t5539-fetch-http-shallow.sh'

# Run remaining protocol v2 bundle-uri and serve tests
git-t-proto-more:
    @tools/apply-git-test-patches.sh
    make -C third_party/git test T='t5701-git-serve.sh t5710-promisor-remote-capability.sh t5730-protocol-v2-bundle-uri-file.sh t5731-protocol-v2-bundle-uri-git.sh t5732-protocol-v2-bundle-uri-http.sh t5750-bundle-uri-parse.sh'

# Run tests from allowlist file (tools/git-test-allowlist.txt)
git-t-allowlist:
    @tools/apply-git-test-patches.sh
    @prefix=$(brew --prefix gettext); \
    CPATH="$prefix/include" LDFLAGS="-L$prefix/lib" LIBRARY_PATH="$prefix/lib" \
    make -C third_party/git test T="$(rg -v '^[[:space:]]*#' tools/git-test-allowlist.txt | rg -v '^[[:space:]]*$' | tr '\n' ' ')"

# Run allowlist using git-shim (defaults to system git fallback)
git-t-allowlist-shim:
    @tools/apply-git-test-patches.sh
    @prefix=$(brew --prefix gettext); \
    real_git="$(pwd)/third_party/git/git"; \
    if [ -x "$real_git" ]; then \
      exec_path="$(pwd)/third_party/git"; \
    else \
      real_git=$(/usr/bin/which git); \
      exec_path=$($real_git --exec-path); \
    fi; \
    shim_dir="$(pwd)/tools/git-shim/bin"; \
    echo "$real_git" > tools/git-shim/real-git-path; \
    SHIM_REAL_GIT="$real_git" SHIM_EXEC_PATH="$exec_path" \
    SHIM_MOON="$(pwd)/tools/git-shim/moon" SHIM_CMDS="receive-pack" \
    GIT_TEST_INSTALLED="$shim_dir" GIT_TEST_EXEC_PATH="$exec_path" \
    GIT_TEST_DEFAULT_HASH=sha1 \
    CPATH="$prefix/include" LDFLAGS="-L$prefix/lib" LIBRARY_PATH="$prefix/lib" \
    make -C third_party/git test T="$(rg -v '^[[:space:]]*#' tools/git-test-allowlist.txt | rg -v '^[[:space:]]*$' | tr '\n' ' ')"

# Run allowlist and force shim to error on specified subcommands
git-t-allowlist-shim-strict:
    @tools/apply-git-test-patches.sh
    @prefix=$(brew --prefix gettext); \
    real_git="$(pwd)/third_party/git/git"; \
    if [ -x "$real_git" ]; then \
      exec_path="$(pwd)/third_party/git"; \
    else \
      real_git=$(/usr/bin/which git); \
      exec_path=$($real_git --exec-path); \
    fi; \
    shim_dir="$(pwd)/tools/git-shim/bin"; \
    echo "$real_git" > tools/git-shim/real-git-path; \
    SHIM_REAL_GIT="$real_git" SHIM_EXEC_PATH="$exec_path" \
    SHIM_CMDS="receive-pack upload-pack pack-objects index-pack" SHIM_STRICT=1 \
    GIT_TEST_INSTALLED="$shim_dir" GIT_TEST_EXEC_PATH="$exec_path" \
    GIT_TEST_DEFAULT_HASH=sha1 \
    CPATH="$prefix/include" LDFLAGS="-L$prefix/lib" LIBRARY_PATH="$prefix/lib" \
    make -C third_party/git test T="$(rg -v '^[[:space:]]*#' tools/git-test-allowlist.txt | rg -v '^[[:space:]]*$' | tr '\n' ' ')"

# Generate compatibility table from allowlist
compat-table:
    @bash tools/generate-compat-table.sh

# Run a single test file in strict shim mode (e.g., just git-t-one t3200-branch.sh)
git-t-one test_file:
    @tools/apply-git-test-patches.sh
    @prefix=$(brew --prefix gettext); \
    real_git="$(pwd)/third_party/git/git"; \
    if [ -x "$real_git" ]; then \
      exec_path="$(pwd)/third_party/git"; \
    else \
      real_git=$(/usr/bin/which git); \
      exec_path=$($real_git --exec-path); \
    fi; \
    shim_dir="$(pwd)/tools/git-shim/bin"; \
    echo "$real_git" > tools/git-shim/real-git-path; \
    SHIM_REAL_GIT="$real_git" SHIM_EXEC_PATH="$exec_path" \
    SHIM_CMDS="receive-pack upload-pack pack-objects index-pack" SHIM_STRICT=1 \
    GIT_TEST_INSTALLED="$shim_dir" GIT_TEST_EXEC_PATH="$exec_path" \
    GIT_TEST_DEFAULT_HASH=sha1 \
    CPATH="$prefix/include" LDFLAGS="-L$prefix/lib" LIBRARY_PATH="$prefix/lib" \
    make -C third_party/git test T="{{test_file}}"

# Run a single test file in strict shim mode with remote intercepted
git-t-one-remote test_file:
    @tools/apply-git-test-patches.sh
    @prefix=$(brew --prefix gettext); \
    real_git="$(pwd)/third_party/git/git"; \
    if [ -x "$real_git" ]; then \
      exec_path="$(pwd)/third_party/git"; \
    else \
      real_git=$(/usr/bin/which git); \
      exec_path=$($real_git --exec-path); \
    fi; \
    shim_dir="$(pwd)/tools/git-shim/bin"; \
    echo "$real_git" > tools/git-shim/real-git-path; \
    SHIM_REAL_GIT="$real_git" SHIM_EXEC_PATH="$exec_path" \
    SHIM_CMDS="receive-pack upload-pack pack-objects index-pack remote" SHIM_STRICT=1 \
    GIT_TEST_INSTALLED="$shim_dir" GIT_TEST_EXEC_PATH="$exec_path" \
    GIT_TEST_DEFAULT_HASH=sha1 \
    CPATH="$prefix/include" LDFLAGS="-L$prefix/lib" LIBRARY_PATH="$prefix/lib" \
    make -C third_party/git test T="{{test_file}}"

# Compare bit vs real git performance
compare-real-git:
    bash tools/compare-real-git.sh

# Compare with custom repo (e.g., just compare-real-git-repo https://github.com/foo/bar.git)
compare-real-git-repo repo_url:
    REPO_URL="{{repo_url}}" bash tools/compare-real-git.sh

# Run a single test with ALL moongit commands (no fallback)
git-t-full test_file:
    @prefix=$(brew --prefix gettext); \
    real_git="$(pwd)/third_party/git/git"; \
    if [ -x "$real_git" ]; then \
      exec_path="$(pwd)/third_party/git"; \
    else \
      real_git=$(/usr/bin/which git); \
      exec_path=$($real_git --exec-path); \
    fi; \
    shim_dir="$(pwd)/tools/git-shim/bin"; \
    echo "$real_git" > tools/git-shim/real-git-path; \
    SHIM_REAL_GIT="$real_git" SHIM_EXEC_PATH="$exec_path" \
    SHIM_CMDS="init status add commit log show branch checkout switch reset rebase stash cherry-pick diff merge tag rm mv config sparse-checkout rev-parse cat-file ls-files hash-object ls-tree write-tree show-ref update-ref symbolic-ref reflog worktree gc clean grep submodule revert notes bisect describe blame format-patch shortlog remote clone fetch pull push receive-pack upload-pack pack-objects index-pack" SHIM_STRICT=1 \
    GIT_TEST_INSTALLED="$shim_dir" GIT_TEST_EXEC_PATH="$exec_path" \
    GIT_TEST_DEFAULT_HASH=sha1 \
    CPATH="$prefix/include" LDFLAGS="-L$prefix/lib" LIBRARY_PATH="$prefix/lib" \
    make -C third_party/git test T="{{test_file}}"
