#!/bin/bash
# Test: zet script-refs — script-usage matrix + dangling template-script validation
# Covers reference extraction, resolution, matrix CLI output, and the validate gate
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../core/test-runner.sh"
source "$SCRIPT_DIR/../core/script-refs.sh"

BIN="$SCRIPT_DIR/../bin/zet"

setup() {
    zet_test_setup
    export ZET_ROOT="$TEST_HOME/project"
    export ZET_TEMPLATES="$ZET_ROOT/templates"
    mkdir -p "$ZET_TEMPLATES"

    cat > "$ZET_ROOT/zet.toml" <<'EOF'
[paths]
templates = "templates/"
EOF
}

teardown() {
    zet_test_teardown
}

write_template() {
    local name="$1" body="$2"
    cat > "$ZET_TEMPLATES/$name" <<EOF
---
type: skill
description: test template
---
$body
EOF
}

# --- Tests ---

echo "=== Test: zet script-refs ==="
echo ""

# Extraction must be unique + sorted; URLs are links, not local files
echo "--- Extraction ---"
setup
write_template "hello_prompt_template.md" 'Run `scripts/validate_input.py` and scripts/transform.py, then scripts/validate_input.py again.
Docs at https://example.com/remote/setup.sh are links, not local files.'
refs=$(extract_script_refs "$ZET_TEMPLATES/hello_prompt_template.md")
assert_equals "$refs" "scripts/transform.py
scripts/validate_input.py" "extraction: unique sorted refs"
teardown

# A repo-rooted reference resolves against ZET_ROOT
echo "--- Resolution: ZET_ROOT-relative ---"
setup
mkdir -p "$ZET_ROOT/scripts"
touch "$ZET_ROOT/scripts/tool.sh"
resolved=$(resolve_script_ref "scripts/tool.sh" "$ZET_TEMPLATES")
assert_contains_str "$resolved" "$ZET_ROOT/scripts/tool.sh" "resolution: ZET_ROOT-relative ref resolves"
teardown

# A skill-local reference resolves against the template directory
echo "--- Resolution: template-dir-relative ---"
setup
mkdir -p "$ZET_ROOT/templates/scripts"
touch "$ZET_ROOT/templates/scripts/local.py"
resolved=$(resolve_script_ref "scripts/local.py" "$ZET_TEMPLATES")
assert_contains_str "$resolved" "$ZET_ROOT/templates/scripts/local.py" "resolution: template-relative ref resolves"
teardown

# A ~ reference expands against HOME (isolated to TEST_HOME so the check is hermetic)
echo "--- Resolution: ~ expansion ---"
setup
export HOME="$TEST_HOME"
touch "$TEST_HOME/home-tool.sh"
resolved=$(resolve_script_ref "~/home-tool.sh" "$ZET_TEMPLATES")
assert_contains_str "$resolved" "$TEST_HOME/home-tool.sh" "resolution: ~ ref expands to HOME"
teardown

# A basename reference resolves in a configured shared script root
echo "--- Resolution: shared script root ---"
setup
mkdir -p "$ZET_ROOT/shared-scripts"
touch "$ZET_ROOT/shared-scripts/check-thing.sh"
cat >> "$ZET_ROOT/zet.toml" <<'EOF'
scripts = "shared-scripts"
EOF
resolved=$(resolve_script_ref "lib/deep/check-thing.sh" "$ZET_TEMPLATES")
assert_contains_str "$resolved" "$ZET_ROOT/shared-scripts/check-thing.sh" "resolution: basename matches in shared root"
teardown

# A reference that resolves nowhere is dangling
echo "--- Resolution: dangling ---"
setup
if resolve_script_ref "scripts/missing.sh" "$ZET_TEMPLATES" >/dev/null 2>&1; then
    zet_fail "resolution: dangling ref must not resolve"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
else
    zet_pass "resolution: dangling ref must not resolve"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
fi
teardown

# Matrix output lists refs with statuses and reports scripts shared across templates
echo "--- CLI: matrix ---"
setup
mkdir -p "$ZET_ROOT/scripts"
touch "$ZET_ROOT/scripts/tool.sh"
write_template "a_prompt_template.md" 'Use `scripts/tool.sh`.'
write_template "b_prompt_template.md" 'Use scripts/tool.sh and scripts/missing.py.'
output=$(bash "$SCRIPT_DIR/../core/script-refs.sh" 2>&1)
rc=$?
assert_exit_code "$rc" 0 "CLI: matrix exits 0"
assert_output_contains "$output" "scripts/tool.sh  ok" "CLI: matrix marks existing ref ok"
assert_output_contains "$output" "scripts/missing.py  DANGLING" "CLI: matrix marks missing ref DANGLING"
assert_output_contains "$output" "tool.sh — 2 templates" "CLI: matrix reports shared script"
teardown

# --check fails the run when a reference is dangling
echo "--- CLI: --check dangling ---"
setup
write_template "a_prompt_template.md" 'Use scripts/missing.sh.'
if bash "$SCRIPT_DIR/../core/script-refs.sh" --check >/dev/null 2>&1; then
    zet_fail "CLI: --check exits 1 on dangling"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
else
    zet_pass "CLI: --check exits 1 on dangling"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
fi
teardown

# --check passes when every reference resolves
echo "--- CLI: --check clean ---"
setup
mkdir -p "$ZET_ROOT/scripts"
touch "$ZET_ROOT/scripts/ok.sh"
write_template "a_prompt_template.md" 'Use `scripts/ok.sh`.'
if bash "$SCRIPT_DIR/../core/script-refs.sh" --check >/dev/null 2>&1; then
    zet_pass "CLI: --check exits 0 when clean"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
else
    zet_fail "CLI: --check exits 0 when clean"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
fi
teardown

# JSON output must be valid and carry the shared + dangling sections
echo "--- CLI: JSON ---"
setup
mkdir -p "$ZET_ROOT/scripts"
touch "$ZET_ROOT/scripts/tool.sh"
write_template "a_prompt_template.md" 'Use `scripts/tool.sh` and scripts/missing.py.'
json=$(bash "$SCRIPT_DIR/../core/script-refs.sh" --json)
assert_json_valid "$json" "CLI: JSON is valid"
assert_output_contains "$json" '"dangling"' "CLI: JSON carries dangling section"
assert_output_contains "$json" '"shared"' "CLI: JSON carries shared section"
teardown

# zet validate gates on dangling script references
echo "--- Validate integration ---"
setup
write_template "a_prompt_template.md" 'Use scripts/missing.sh.'
validate_out=$(export ZET_ROOT; bash "$BIN" validate 2>&1 || true)
assert_output_contains "$validate_out" "dangling script reference: 'scripts/missing.sh'" "validate: reports dangling script ref"
if bash "$BIN" validate >/dev/null 2>&1; then
    zet_fail "validate: exits 1 on dangling script ref"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
else
    zet_pass "validate: exits 1 on dangling script ref"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
fi
teardown

setup
mkdir -p "$ZET_ROOT/scripts"
touch "$ZET_ROOT/scripts/ok.sh"
write_template "a_prompt_template.md" 'Use `scripts/ok.sh`.'
if bash "$BIN" validate >/dev/null 2>&1; then
    zet_pass "validate: clean refs pass"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
else
    zet_fail "validate: clean refs pass"
    ZET_TESTS_RUN=$((ZET_TESTS_RUN + 1))
fi
teardown

# zet scripts routes to the matrix
echo "--- bin/zet dispatch ---"
setup
write_template "a_prompt_template.md" 'Use nothing.'
dispatch_out=$(bash "$BIN" scripts 2>&1 || true)
assert_output_contains "$dispatch_out" "Zet Script Usage Matrix" "dispatch: zet scripts runs the matrix"
teardown

zet_test_results
