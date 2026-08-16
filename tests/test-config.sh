#!/bin/bash
# Tests for core/config.sh — section-aware TOML reader
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../core/test-runner.sh"

echo "=== Test: zet config ==="
echo ""

# --- Setup: create a test zet.toml ---
zet_test_setup
cat > "$TEST_TMP/zet.toml" <<'EOF'
# Zet config test file

[project]
name = "test-harness"
version = "0.2.0"

[paths]
templates = "templates/"
skills = "~/.claude/skills/"
agents = "output/agents/"
rules = "output/rules/"
hooks = "hooks/"

[model-roles]
audit = "haiku"
execute = "sonnet"
think = "opus"
EOF

source "$SCRIPT_DIR/../core/config.sh"

echo "--- Basic value reading ---"
zet_config_init "$TEST_TMP"
val=$(zet_config_get "project" "name" "")
assert_equals "$val" "test-harness" "reads project name"

val=$(zet_config_get "project" "version" "")
assert_equals "$val" "0.2.0" "reads project version"

echo ""
echo "--- Path reading with tilde expansion ---"
val=$(zet_config_get "paths" "skills" "")
assert_equals "$val" "$HOME/.claude/skills/" "expands tilde in paths"

val=$(zet_config_get "paths" "templates" "")
assert_equals "$val" "templates/" "reads non-tilde path"

echo ""
echo "--- Default values ---"
val=$(zet_config_get "paths" "nonexistent" "fallback/")
assert_equals "$val" "fallback/" "returns default for missing key"

val=$(zet_config_get "nosection" "nokey" "default-val")
assert_equals "$val" "default-val" "returns default for missing section"

echo ""
echo "--- Model roles ---"
val=$(zet_config_get "model-roles" "audit" "")
assert_equals "$val" "haiku" "reads model role audit"

val=$(zet_config_get "model-roles" "think" "")
assert_equals "$val" "opus" "reads model role think"

echo ""
echo "--- Section listing ---"
section_out=$(zet_config_section "model-roles")
assert_output_contains "$section_out" "audit" "section lists audit key"
assert_output_contains "$section_out" "execute" "section lists execute key"
assert_output_contains "$section_out" "think" "section lists think key"

echo ""
echo "--- Missing config file ---"
ZET_CONFIG_FILE="$TEST_TMP/nonexistent.toml"
val=$(zet_config_get "project" "name" "no-file-default")
assert_equals "$val" "no-file-default" "missing file returns default"

echo ""
echo "--- Config exists check ---"
zet_config_init "$TEST_TMP"
zet_config_exists
assert_exit_code $? 0 "config exists returns 0 for real file"

ZET_CONFIG_FILE="$TEST_TMP/nope.toml"
zet_config_exists || code=$?
assert_exit_code "${code:-0}" 1 "config exists returns 1 for missing"

echo ""
echo "--- Inline comments ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
[project]
name = "my-proj" # project name here
version = "1.0.0"   # the version

[paths]
templates = "tpl/"  # template dir
EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"

val=$(zet_config_get "project" "name" "")
assert_equals "$val" "my-proj" "strips inline comment from quoted value"

val=$(zet_config_get "project" "version" "")
assert_equals "$val" "1.0.0" "strips inline comment from quoted version"

val=$(zet_config_get "paths" "templates" "")
assert_equals "$val" "tpl/" "strips inline comment from path value"

echo ""
echo "--- Whitespace handling ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
[  project  ]
  name  =  "spacy"
  version = "2.0.0"
EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"

val=$(zet_config_get "project" "name" "")
assert_equals "$val" "spacy" "handles extra whitespace around key/value"

echo ""
echo "--- Empty and comment-only file ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
# This file has no sections
# Just comments

EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"

val=$(zet_config_get "project" "name" "empty-default")
assert_equals "$val" "empty-default" "returns default for comment-only file"

echo ""
echo "--- Validation: well-formed file ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
[project]
name = "valid"
version = "1.0.0"
EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"
zet_config_validate
assert_exit_code $? 0 "valid file passes validation"
assert_equals "${#ZET_CONFIG_ERRORS[@]}" "0" "no errors for valid file"

echo ""
echo "--- Validation: malformed section header ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
[project
name = "broken"
EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"
zet_config_validate || vcode=$?
assert_exit_code "${vcode:-0}" 1 "malformed section header fails validation"
assert_not_empty "${ZET_CONFIG_ERRORS[0]}" "error message populated for bad section"

echo ""
echo "--- Validation: key outside section ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
name = "orphan"

[project]
version = "1.0.0"
EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"
zet_config_validate || vcode2=$?
assert_exit_code "${vcode2:-0}" 1 "key outside section fails validation"

echo ""
echo "--- Validation: unclosed quote ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
[project]
name = "unclosed
EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"
zet_config_validate || vcode3=$?
assert_exit_code "${vcode3:-0}" 1 "unclosed quote fails validation"

echo ""
echo "--- Validation: missing file is ok ---"
ZET_CONFIG_FILE="$TEST_TMP/nope.toml"
zet_config_validate
assert_exit_code $? 0 "missing file passes validation (nothing to validate)"

echo ""
echo "--- Section listing with inline comments ---"
cat > "$TEST_TMP/zet.toml" <<'EOF'
[model-roles]
audit = "haiku"  # cheap model
execute = "sonnet" # default
think = "opus"     # expensive
EOF
source "$SCRIPT_DIR/../core/config.sh"
zet_config_init "$TEST_TMP"
section_out=$(zet_config_section "model-roles")
assert_output_not_contains "$section_out" "#" "section listing strips inline comments"
assert_output_contains "$section_out" 'audit = "haiku"' "section preserves key=value"

zet_test_teardown

zet_test_results
