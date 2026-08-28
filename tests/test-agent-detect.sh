#!/bin/bash
# Tests for core/agent-detect.sh — comm/title-based live-pane agent identification.
# Requires a real tmux server (spawns throwaway sessions to exercise pane_current_command/
# pane_title, which can't be faked without an actual process running under that name) — skips
# cleanly if tmux is unavailable rather than failing the whole suite.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../core/test-runner.sh"
source "$SCRIPT_DIR/../core/agent-detect.sh"

echo "=== Test: agent-detect ==="
echo ""

if ! command -v tmux >/dev/null 2>&1 || ! tmux list-sessions >/dev/null 2>&1; then
    echo "SKIP: no tmux server available"
    zet_test_results
    exit 0
fi

_ZET_TEST_SESSIONS=()
_zet_test_pane() {
    # spawns a throwaway tmux session whose pane runs a real (harmless) process, optionally
    # under a given TITLE — pane_current_command is only meaningful for an ACTUALLY-running
    # process, so a synthetic string can't stand in for it. $3 (optional) names the foreground
    # command to run instead of the default shell — used to give a pane a real "node" comm,
    # since Pi's own detection depends on that exact process name, not a title alone.
    local name="$1" title="$2" cmd="${3:-}"
    if [ -n "$cmd" ]; then
        tmux new-session -d -s "$name" -x 80 -y 20 "$cmd"
    else
        tmux new-session -d -s "$name" -x 80 -y 20
    fi
    [ -n "$title" ] && tmux select-pane -t "$name" -T "$title" 2>/dev/null
    _ZET_TEST_SESSIONS+=("$name")
}
_zet_test_cleanup() {
    local s
    for s in "${_ZET_TEST_SESSIONS[@]}"; do tmux kill-session -t "$s" 2>/dev/null || true; done
}
trap _zet_test_cleanup EXIT

# --- pi detection: comm=node + title "π - <dirname>" ---
echo "--- pi ---"
_zet_test_pane "zet_test_pi_$$" "π - myproject" "node -e 'setTimeout(()=>{}, 30000)'"
sleep 0.3   # let tmux settle pane_current_command after select-pane
detected="$(zet_agent_detect "zet_test_pi_$$" || true)"
assert_equals "$detected" "pi" "node pane titled like Pi (comm=node, title-anchored) detected as pi"

# --- a real node process titled like an unrelated launcher must NOT be misdetected as pi ---
_zet_test_pane "zet_test_launcher_$$" "✳ Open Claude" "node -e 'setTimeout(()=>{}, 30000)'"
sleep 0.3
detected="$(zet_agent_detect "zet_test_launcher_$$" || true)"
assert_not_contains_str "$detected" "pi" "node pane with wrong title NOT detected as pi"

# --- an untitled plain shell must NOT match any registered agent ---
echo ""
echo "--- no false positives on a plain shell ---"
_zet_test_pane "zet_test_plain_$$" ""
sleep 0.3
detected="$(zet_agent_detect "zet_test_plain_$$" || true)"
assert_equals "$detected" "" "plain shell pane matches no registered agent"

# --- detect fails (empty + nonzero) for a nonexistent target ---
echo ""
echo "--- nonexistent target ---"
rc=0
zet_agent_detect "zet_test_does_not_exist_$$" >/dev/null 2>&1 || rc=$?
assert_exit_code "$rc" 1 "nonexistent tmux target returns failure, not a false match"

zet_test_results
