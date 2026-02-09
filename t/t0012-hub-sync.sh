#!/bin/bash
#
# e2e: hub sync between two clones over Smart HTTP

source "$(dirname "$0")/test-lib-e2e.sh"

TEST_COUNT=1
PASS_COUNT=0
FAIL_COUNT=0

CASE_NAME='hub sync replicates PR and issue across two clones'
SERVER_PID=""

cleanup_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

run_case() {
    setup_test_dir
    trap 'cleanup_server; cleanup_test_dir' EXIT

    mkdir upstream
    (
        cd upstream
        git init -q
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo "init" > README.md
        git add README.md
        git commit -m "init" >/dev/null
    )

    local port=$((11000 + $$ % 30000))
    local server_log="$TRASH_DIR/hub-server.log"

    USE_REAL_GIT=1 node "$PROJECT_ROOT/tools/http-test-server.js" \
        "$TRASH_DIR/upstream" "$port" >"$server_log" 2>&1 &
    SERVER_PID=$!
    sleep 1
    kill -0 "$SERVER_PID"

    git_cmd clone "http://localhost:$port" node-a >/dev/null
    git_cmd clone "http://localhost:$port" node-b >/dev/null

    (
        cd node-a
        git_cmd checkout -b main >/dev/null
        git_cmd checkout -b feature/hub >/dev/null
        echo "from node-a" > feature.txt
        git_cmd add feature.txt
        git_cmd commit -m "node-a feature" >/dev/null
        git_cmd hub init >/dev/null
        git_cmd hub pr create \
            --title "Add feature from node-a" \
            --body "sync test pr" \
            --source refs/heads/feature/hub \
            --target refs/heads/main >/dev/null
        git_cmd hub pr propose \
            --title "Proposal from node-a" \
            --body "sync test proposal" \
            --source refs/heads/feature/hub \
            --target refs/heads/main >/dev/null
        git_cmd hub sync push "http://localhost:$port" >/dev/null
    )

    (
        cd node-b
        git_cmd hub init >/dev/null
        cat > .git/hooks/hub-notify <<EOF
#!/bin/sh
echo "\$1 \$2 \$3" >> "$TRASH_DIR/hub-notify.log"
EOF
        chmod +x .git/hooks/hub-notify
        git_cmd hub sync fetch "http://localhost:$port" >/dev/null
        git_cmd hub pr list | grep -q "Add feature from node-a"
        git_cmd hub pr proposals | grep -q "Proposal from node-a"
        grep -q "hub.pr.proposal pr-proposal hub/proposal/pr/" "$TRASH_DIR/hub-notify.log"
        git_cmd hub issue create \
            --title "Track rollout from node-b" \
            --body "sync test issue" >/dev/null
        git_cmd hub sync push "http://localhost:$port" >/dev/null
    )

    (
        cd node-a
        git_cmd hub sync fetch "http://localhost:$port" >/dev/null
        git_cmd hub issue list | grep -q "Track rollout from node-b"
    )

    cleanup_server
    cleanup_test_dir
    trap - EXIT
}

if ! command -v node >/dev/null 2>&1; then
    SKIP_COUNT=1
    echo -e "${YELLOW}ok 1${NC} - $CASE_NAME # SKIP node not found"
    test_done
fi

if ! command -v git >/dev/null 2>&1; then
    SKIP_COUNT=1
    echo -e "${YELLOW}ok 1${NC} - $CASE_NAME # SKIP git not found"
    test_done
fi

if run_case 2>/dev/null; then
    PASS_COUNT=1
    echo -e "${GREEN}ok 1${NC} - $CASE_NAME"
else
    FAIL_COUNT=1
    echo -e "${RED}not ok 1${NC} - $CASE_NAME"
fi

test_done
