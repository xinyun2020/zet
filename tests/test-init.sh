#!/bin/bash
# Tests for zet init — end-to-end scaffold and first-run experience
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../core/test-runner.sh"

ZET_BIN="$SCRIPT_DIR/../bin/zet"

echo "=== Test: zet init (first-run experience) ==="
echo ""

# --- Fresh init creates expected files ---
zet_test_setup

echo "--- Scaffold a new project ---"
"$ZET_BIN" init "$TEST_TMP/my-project" >/dev/null

assert_file_exists "$TEST_TMP/my-project/zet.toml" "creates zet.toml"
assert_dir_exists "$TEST_TMP/my-project/templates" "creates templates/"
assert_dir_exists "$TEST_TMP/my-project/hooks" "creates hooks/"
assert_dir_exists "$TEST_TMP/my-project/tests" "creates tests/"
assert_file_exists "$TEST_TMP/my-project/model-roles.conf" "creates model-roles.conf"
assert_file_exists "$TEST_TMP/my-project/templates/hello_prompt_template.md" "creates example template"

echo ""
echo "--- zet.toml has correct structure ---"
assert_contains "$TEST_TMP/my-project/zet.toml" "\[project\]" "has [project] section"
assert_contains "$TEST_TMP/my-project/zet.toml" "\[paths\]" "has [paths] section"
assert_contains "$TEST_TMP/my-project/zet.toml" "\[model-roles\]" "has [model-roles] section"

echo ""
echo "--- Example template is valid ---"
assert_contains "$TEST_TMP/my-project/templates/hello_prompt_template.md" "type: skill" "example has type: skill"
assert_contains "$TEST_TMP/my-project/templates/hello_prompt_template.md" "description:" "example has description"

echo ""
echo "--- Double init is rejected ---"
output=$("$ZET_BIN" init "$TEST_TMP/my-project" 2>&1 || true)
assert_output_contains "$output" "Already initialized" "rejects double init"

echo ""
echo "--- validate works on fresh project ---"
cd "$TEST_TMP/my-project"
output=$(ZET_ROOT="$TEST_TMP/my-project" "$ZET_BIN" validate 2>&1)
assert_output_contains "$output" "All templates valid" "validate passes on fresh init"

echo ""
echo "--- Scaffolded files contain only generic content ---"
all_files=$(cat "$TEST_TMP/my-project/zet.toml" "$TEST_TMP/my-project/templates/hello_prompt_template.md" "$TEST_TMP/my-project/model-roles.conf")
# Verify scaffolded files don't contain hardcoded paths or author-specific content
assert_output_not_contains "$all_files" "/Users/" "no hardcoded user paths in scaffolded files"
assert_output_not_contains "$all_files" "/home/" "no hardcoded home paths in scaffolded files"
assert_output_not_contains "$all_files" "CHANGEME" "no placeholder tokens in scaffolded files"

zet_test_teardown

zet_test_results
