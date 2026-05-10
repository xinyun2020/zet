#!/bin/bash
# Tests for hooks/ — check-datetime, pre-push, post-edit
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../core/test-runner.sh"

echo "=== Test: hooks ==="
echo ""

# --- check-datetime.sh ---
echo "--- check-datetime ---"
output=$(bash "$SCRIPT_DIR/../hooks/check-datetime.sh")
assert_output_contains "$output" "Current:" "outputs current datetime prefix"
assert_output_contains "$output" "$(date +'%Y')" "includes current year"

# --- pre-push.sh ---
echo ""
echo "--- pre-push (clean repo) ---"
zet_test_setup
mkdir -p "$TEST_TMP/repo"
git -C "$TEST_TMP/repo" init -q
git -C "$TEST_TMP/repo" config user.email "test@test.com"
git -C "$TEST_TMP/repo" config user.name "Test"
git -C "$TEST_TMP/repo" commit --allow-empty -m "init" -q

# Clean repo should pass
REPO_PATH="$TEST_TMP/repo" bash "$SCRIPT_DIR/../hooks/pre-push.sh" >/dev/null 2>&1
assert_exit_code $? 0 "clean repo passes"

# Dirty repo should block
echo "dirty" > "$TEST_TMP/repo/file.txt"
output=$(REPO_PATH="$TEST_TMP/repo" bash "$SCRIPT_DIR/../hooks/pre-push.sh" 2>&1 || true)
# pre-push checks uncommitted changes
assert_output_contains "$output" "BLOCKED" "dirty repo blocked"

zet_test_teardown

# --- post-edit.sh ---
echo ""
echo "--- post-edit (non-template) ---"
# Non-template file should be no-op (exit 0)
EDITED_FILE="/tmp/random_file.md" bash "$SCRIPT_DIR/../hooks/post-edit.sh"
assert_exit_code $? 0 "non-template file is no-op"

# Template file triggers (but zet binary may not exist — just check it doesn't error)
EDITED_FILE="/tmp/foo_prompt_template.md" bash "$SCRIPT_DIR/../hooks/post-edit.sh"
assert_exit_code $? 0 "template file doesn't crash"

# --- Scanner: orphaned hooks detection ---
echo ""
echo "--- Orphaned hooks (scanner) ---"
zet_test_setup
export ZET_ROOT="$TEST_HOME/project"
export ZET_TEMPLATES="$ZET_ROOT/templates"
export ZET_SKILLS="$TEST_HOME/output/skills"
export ZET_AGENTS="$TEST_HOME/output/agents"
export ZET_RULES="$TEST_HOME/output/rules"
export ZET_HOOKS="$ZET_ROOT/hooks"
export ZET_SETTINGS="$ZET_ROOT/settings.json"

mkdir -p "$ZET_TEMPLATES" "$ZET_SKILLS" "$ZET_AGENTS" "$ZET_RULES" "$ZET_HOOKS"

# Create hook not referenced anywhere
echo '#!/bin/bash' > "$ZET_HOOKS/orphan.sh"

# Create hook referenced in settings.json
echo '#!/bin/bash' > "$ZET_HOOKS/referenced.sh"
echo '{"hooks": "referenced.sh"}' > "$ZET_ROOT/settings.json"

# Create zet.toml (scanner reads it for hooks config)
cat > "$ZET_ROOT/zet.toml" <<'EOF'
[project]
name = "test"
[paths]
hooks = "hooks/"
EOF

output=$(bash "$SCRIPT_DIR/../core/scanner.sh" --json 2>&1)
assert_contains_str "$output" "orphan.sh" "detects orphaned hook"
assert_not_contains_str "$output" "referenced.sh" "referenced hook not flagged"
zet_test_teardown

zet_test_results
