#!/bin/bash
# Test: zet eval
# Verifies the three-layer eval runner: assertion parsing, scenario execution,
# pass/fail detection, JSON output, and edge cases
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../core/test-runner.sh"

EVAL="$SCRIPT_DIR/../core/eval.sh"

# --- Test helpers ---
setup() {
    zet_test_setup
    export ZET_ROOT="$TEST_HOME/project"
    export ZET_TEMPLATES="$ZET_ROOT/templates"
    export ZET_EVALS="$ZET_ROOT/evals"
    mkdir -p "$ZET_TEMPLATES" "$ZET_EVALS"
}

teardown() {
    zet_test_teardown
}

run_eval() {
    bash "$EVAL" --quiet "$@" 2>&1 || true
}

run_eval_json() {
    bash "$EVAL" --json "$@" 2>&1 || true
}

# --- Tests ---

echo "=== Test: zet eval ==="
echo ""

# Test 1: No evals directory — exit 2
echo "--- No evals directory ---"
setup
rmdir "$ZET_EVALS"
output=$(bash "$EVAL" --json 2>&1 || true)
assert_contains_str "$output" '"total": 0' "no evals reports zero total"
teardown

# Test 2: Empty evals directory — exit 2
echo ""
echo "--- Empty evals directory ---"
setup
output=$(bash "$EVAL" --json 2>&1 || true)
assert_contains_str "$output" '"total": 0' "empty evals reports zero"
teardown

# Test 3: Passing scenario (contains assertion)
echo ""
echo "--- Passing scenario (contains) ---"
setup
mkdir -p "$ZET_EVALS/hello"
cat > "$ZET_TEMPLATES/hello_prompt_template.md" <<'EOF'
---
type: skill
description: Test skill
---
# Hello
EOF
cat > "$ZET_EVALS/hello/scenario-basic.md" <<'EOF'
---
description: output contains greeting
layer: 1
assertions:
  - type: contains
    value: "hello world"
---
hello world from the skill
EOF
output=$(run_eval_json)
assert_contains_str "$output" '"passed": 1' "passing scenario counted"
assert_contains_str "$output" '"failed": 0' "no failures"
teardown

# Test 4: Failing scenario (contains assertion)
echo ""
echo "--- Failing scenario (contains) ---"
setup
mkdir -p "$ZET_EVALS/hello"
cat > "$ZET_TEMPLATES/hello_prompt_template.md" <<'EOF'
---
type: skill
description: Test skill
---
# Hello
EOF
cat > "$ZET_EVALS/hello/scenario-missing.md" <<'EOF'
---
description: output should contain missing text
layer: 1
assertions:
  - type: contains
    value: "this text is not present"
---
some completely different output
EOF
output=$(run_eval_json)
assert_contains_str "$output" '"failed": 1' "failure detected"
teardown

# Test 5: Regex assertion pass
echo ""
echo "--- Regex assertion pass ---"
setup
mkdir -p "$ZET_EVALS/commit"
cat > "$ZET_TEMPLATES/commit_prompt_template.md" <<'EOF'
---
type: skill
description: Commit message
---
# Commit
EOF
cat > "$ZET_EVALS/commit/scenario-format.md" <<'EOF'
---
description: matches conventional format
layer: 1
assertions:
  - type: regex
    value: "^feat\("
---
feat(auth): add token refresh
EOF
output=$(run_eval_json)
assert_contains_str "$output" '"passed": 1' "regex assertion passes"
teardown

# Test 6: not_contains assertion
echo ""
echo "--- not_contains assertion ---"
setup
mkdir -p "$ZET_EVALS/clean"
cat > "$ZET_TEMPLATES/clean_prompt_template.md" <<'EOF'
---
type: skill
description: Clean output
---
# Clean
EOF
cat > "$ZET_EVALS/clean/scenario-no-secrets.md" <<'EOF'
---
description: no secrets in output
layer: 1
assertions:
  - type: not_contains
    value: "sk-"
---
Clean output with no API keys
EOF
output=$(run_eval_json)
assert_contains_str "$output" '"passed": 1' "not_contains passes on clean output"
teardown

# Test 7: line_count_min and line_count_max
echo ""
echo "--- Line count assertions ---"
setup
mkdir -p "$ZET_EVALS/lines"
cat > "$ZET_TEMPLATES/lines_prompt_template.md" <<'EOF'
---
type: skill
description: Lines test
---
# Lines
EOF
cat > "$ZET_EVALS/lines/scenario-length.md" <<'EOF'
---
description: output has 3 lines
layer: 1
assertions:
  - type: line_count_min
    value: "2"
  - type: line_count_max
    value: "5"
---
line one
line two
line three
EOF
output=$(run_eval_json)
assert_contains_str "$output" '"passed": 1' "line count within bounds"
teardown

# Test 8: json_valid assertion
echo ""
echo "--- JSON valid assertion ---"
setup
mkdir -p "$ZET_EVALS/jsonout"
cat > "$ZET_TEMPLATES/jsonout_prompt_template.md" <<'EOF'
---
type: skill
description: JSON output
---
# JSON
EOF
cat > "$ZET_EVALS/jsonout/scenario-valid-json.md" <<'EOF'
---
description: output is valid JSON
layer: 1
assertions:
  - type: json_valid
---
{"status": "ok", "count": 42}
EOF
output=$(run_eval_json)
assert_contains_str "$output" '"passed": 1' "json_valid passes on valid JSON"
teardown

# Test 9: Target specific skill
echo ""
echo "--- Target specific skill ---"
setup
mkdir -p "$ZET_EVALS/alpha" "$ZET_EVALS/beta"
cat > "$ZET_TEMPLATES/alpha_prompt_template.md" <<'EOF'
---
type: skill
description: Alpha
---
# Alpha
EOF
cat > "$ZET_TEMPLATES/beta_prompt_template.md" <<'EOF'
---
type: skill
description: Beta
---
# Beta
EOF
cat > "$ZET_EVALS/alpha/scenario-a.md" <<'EOF'
---
description: alpha test
layer: 1
assertions:
  - type: contains
    value: "alpha"
---
alpha output
EOF
cat > "$ZET_EVALS/beta/scenario-b.md" <<'EOF'
---
description: beta test
layer: 1
assertions:
  - type: contains
    value: "beta"
---
beta output
EOF
output=$(run_eval_json alpha)
assert_contains_str "$output" '"passed": 1' "only alpha scenario ran"
assert_not_contains_str "$output" "beta" "beta was not included"
teardown

# Test 10: Multiple assertions — all must pass
echo ""
echo "--- Multiple assertions (all must pass) ---"
setup
mkdir -p "$ZET_EVALS/multi"
cat > "$ZET_TEMPLATES/multi_prompt_template.md" <<'EOF'
---
type: skill
description: Multi assertion
---
# Multi
EOF
cat > "$ZET_EVALS/multi/scenario-combo.md" <<'EOF'
---
description: multiple assertions
layer: 1
assertions:
  - type: contains
    value: "hello"
  - type: not_contains
    value: "goodbye"
  - type: regex
    value: "^hello"
  - type: line_count_min
    value: "1"
---
hello world
EOF
output=$(run_eval_json)
assert_contains_str "$output" '"passed": 1' "all assertions pass together"
assert_contains_str "$output" '"failed": 0' "no failures with multiple assertions"
teardown

zet_test_results
