#!/bin/bash
# Test: zet optimize
# Verifies harness optimization checks: permission surface audit,
# redundancy detection, and token cost estimation
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../core/test-runner.sh"

OPTIMIZE="$SCRIPT_DIR/../core/optimize.sh"

# --- Test helpers ---
setup() {
    zet_test_setup
    export ZET_ROOT="$TEST_HOME/project"
    export ZET_TEMPLATES="$ZET_ROOT/templates"
    export ZET_SKILLS="$TEST_HOME/output/skills"
    export HOME="$TEST_HOME"

    mkdir -p "$ZET_TEMPLATES" "$ZET_SKILLS"
}

teardown() {
    zet_test_teardown
}

run_optimize() {
    bash "$OPTIMIZE" --quiet 2>&1 || true
}

run_optimize_json() {
    bash "$OPTIMIZE" --json 2>&1
}

run_optimize_fix_dryrun() {
    bash "$OPTIMIZE" --fix-descriptions --dry-run 2>&1 < /dev/null || true
}

run_optimize_fix() {
    bash "$OPTIMIZE" --fix-descriptions --quiet 2>&1 < /dev/null || true
}

run_optimize_fix_json_dryrun() {
    bash "$OPTIMIZE" --json --fix-descriptions --dry-run 2>&1 < /dev/null || true
}

run_optimize_fix_noargs() {
    bash "$OPTIMIZE" --fix-descriptions 2>&1 < /dev/null || true
}

# --- Tests ---

echo "=== Test: zet optimize ==="
echo ""

# Test 1: Clean project — reports surfaces without issues
echo "--- Permission surface: basic detection ---"
setup
cat > "$ZET_TEMPLATES/reader_prompt_template.md" <<'EOF'
---
type: skill
description: A read-only skill
---
# Reader

Use the Read tool to check the file contents.
Then use Grep to find patterns.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"reader_prompt_template"' "identifies skill by name"
assert_contains_str "$output" "Read" "detects Read tool usage"
assert_contains_str "$output" "Grep" "detects Grep tool usage"
teardown

# Test 2: High-privilege skill flagged
echo ""
echo "--- Permission surface: high-privilege detection ---"
setup
cat > "$ZET_TEMPLATES/admin_prompt_template.md" <<'EOF'
---
type: skill
description: Full access admin skill
---
# Admin

Use Bash to run system commands.
Use the Write tool to create files.
Launch an Agent tool for parallel work.
Call mcp__slack__send_message to notify the team.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" "Bash" "detects Bash tool"
assert_contains_str "$output" "Write" "detects Write tool"
assert_contains_str "$output" "Agent" "detects Agent tool"
assert_contains_str "$output" "mcp__" "detects MCP tool calls"
assert_contains_str "$output" '"risk": "high"' "flags high-risk permission surface"
teardown

# Test 3: Read-only skill is low risk
echo ""
echo "--- Permission surface: low-risk classification ---"
setup
cat > "$ZET_TEMPLATES/safe_prompt_template.md" <<'EOF'
---
type: skill
description: Safe read-only skill
---
# Safe

Use Read to check files. Use Glob to find patterns.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"risk": "low"' "read-only skill is low risk"
teardown

# Test 4: Redundancy detection — overlapping instructions
echo ""
echo "--- Redundancy: overlapping instructions detected ---"
setup
cat > "$ZET_TEMPLATES/skill_a_prompt_template.md" <<'EOF'
---
type: skill
description: Skill A
---
# Skill A

Always use conventional commit format. Run tests before committing.
Check lint and type errors. Never push without review.
EOF
cat > "$ZET_TEMPLATES/skill_b_prompt_template.md" <<'EOF'
---
type: skill
description: Skill B
---
# Skill B

Always use conventional commit format. Run tests before committing.
Check lint and type errors. Deploy to staging first.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"redundancy"' "reports redundancy section"
assert_contains_str "$output" "skill_a" "identifies first skill in overlap"
assert_contains_str "$output" "skill_b" "identifies second skill in overlap"
teardown

# Test 5: Token cost estimation
echo ""
echo "--- Token cost: estimates by template size ---"
setup
cat > "$ZET_TEMPLATES/tiny_prompt_template.md" <<'EOF'
---
type: skill
description: Tiny
---
# Tiny
Do one thing.
EOF
cat > "$ZET_TEMPLATES/large_prompt_template.md" <<EOF
---
type: skill
description: Large skill with lots of instructions
---
# Large

$(python3 -c "print('x ' * 500)")
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"token_costs"' "reports token costs"
assert_contains_str "$output" "tiny_prompt_template" "includes tiny skill"
assert_contains_str "$output" "large_prompt_template" "includes large skill"
teardown

# Test 5b: Invocation reliability — strong description likely to fire
echo ""
echo "--- Invocation reliability: strong description ---"
setup
cat > "$ZET_TEMPLATES/strong_prompt_template.md" <<'EOF'
---
type: skill
description: Generate a sprint report with status updates and blockers. Use when the user says "sprint report" or asks for team progress across JIRA tickets.
---
# Strong
Use Read to gather ticket data.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"invocation_reliability"' "reports invocation reliability section"
assert_contains_str "$output" '"reliability": "likely"' "strong description scored likely"
teardown

# Test 5c: Invocation reliability — vague description unlikely to fire
echo ""
echo "--- Invocation reliability: vague description ---"
setup
cat > "$ZET_TEMPLATES/vague_prompt_template.md" <<'EOF'
---
type: skill
description: A helper skill
---
# Vague
Use Read to look at files.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"reliability": "unlikely"' "vague description scored unlikely"
teardown

# Test 5d: Invocation reliability — overlapping descriptions flagged ambiguous
echo ""
echo "--- Invocation reliability: ambiguous overlap ---"
setup
cat > "$ZET_TEMPLATES/dup_one_prompt_template.md" <<'EOF'
---
type: skill
description: Use when the user wants to review a pull request and check code quality for bugs and style issues.
---
# Dup One
Use Read.
EOF
cat > "$ZET_TEMPLATES/dup_two_prompt_template.md" <<'EOF'
---
type: skill
description: Use when the user wants to review a pull request and check code quality for bugs and style issues.
---
# Dup Two
Use Read.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"ambiguous_with"' "reports ambiguous overlap field"
assert_contains_str "$output" "dup_two_prompt_template" "names the overlapping sibling"
teardown

# Test 5e: Token split — always-loaded vs on-demand reported in JSON
echo ""
echo "--- Token split: always-loaded vs on-demand ---"
setup
cat > "$ZET_TEMPLATES/split_one_prompt_template.md" <<'EOF'
---
type: skill
description: Use when the user wants to split tokens — a skill with a real trigger and enough description length to be specific.
---
# Split One
Use Read to gather data. This body is the on-demand portion that only loads when the skill fires, so it should count toward on-demand not always-loaded.
EOF
output=$(run_optimize_json)
assert_contains_str "$output" '"token_budget"' "reports token_budget section"
assert_contains_str "$output" '"always_loaded_tokens"' "reports always-loaded token total"
assert_contains_str "$output" '"on_demand_tokens"' "reports on-demand token total"
assert_contains_str "$output" '"always_loaded_pct_of_200k"' "reports always-loaded as pct of 200k window"
teardown

# Test 5f: Budget gate — --budget exits non-zero when always-loaded exceeds the cap
echo ""
echo "--- Budget gate: --budget exit code ---"
setup
cat > "$ZET_TEMPLATES/budget_one_prompt_template.md" <<'EOF'
---
type: skill
description: Use when the user wants to test the budget gate — a trigger-bearing description of sufficient length.
---
# Budget One
Use Read.
EOF
# A budget of 0 always-loaded tokens must be exceeded (frontmatter alone is non-zero) → exit non-zero.
# `|| true` so set -e doesn't abort the test on the intentional non-zero exit.
budget_exit=0; bash "$OPTIMIZE" --quiet --budget 0 >/dev/null 2>&1 || budget_exit=$?
assert_contains_str "$budget_exit" "1" "budget exceeded exits non-zero"
# A generous budget must pass the gate → exit zero (no other issues in this clean skill).
budget_ok_exit=0; bash "$OPTIMIZE" --quiet --budget 200000 >/dev/null 2>&1 || budget_ok_exit=$?
assert_contains_str "$budget_ok_exit" "0" "within budget exits zero"
teardown

# Test 6: No templates — graceful empty output
echo ""
echo "--- Empty project: no templates ---"
setup
rm -f "$ZET_TEMPLATES"/*
output=$(run_optimize_json)
assert_contains_str "$output" '"total_skills": 0' "reports zero skills"
teardown

# Test 7: No hardcoded paths in output
echo ""
echo "--- No hardcoded paths ---"
setup
cat > "$ZET_TEMPLATES/any_prompt_template.md" <<'EOF'
---
type: skill
description: Any skill
---
# Anything
Use Read tool.
EOF
output=$(run_optimize_json)
assert_not_contains_str "$output" "/Users/" "no hardcoded user paths"
assert_not_contains_str "$output" "/home/" "no hardcoded home paths"
teardown

# Test 8: --fix-descriptions dry-run — shows proposed fix without writing
echo ""
echo "--- Fix descriptions: dry-run shows proposal ---"
setup
cat > "$ZET_TEMPLATES/vague_fix_prompt_template.md" <<'EOF'
---
type: skill
description: A helper skill
---
# Vague
Use Read to look at files.
EOF
output=$(run_optimize_fix_dryrun)
assert_contains_str "$output" "before:" "shows original description"
assert_contains_str "$output" "after:" "shows proposed description"
assert_contains_str "$output" "Use when" "proposed description contains trigger phrase"
assert_contains_str "$output" "dry-run" "indicates dry-run (no write)"
original=$(grep 'description:' "$ZET_TEMPLATES/vague_fix_prompt_template.md")
assert_contains_str "$original" "A helper skill" "file not modified in dry-run"
teardown

# Test 9: --fix-descriptions writes in-place and result is longer + has trigger phrase
echo ""
echo "--- Fix descriptions: rewrites file in-place ---"
setup
cat > "$ZET_TEMPLATES/weak_skill_prompt_template.md" <<'EOF'
---
type: skill
description: A thing
---
# Weak
Use Bash to do stuff.
EOF
run_optimize_fix
new_desc=$(grep 'description:' "$ZET_TEMPLATES/weak_skill_prompt_template.md")
assert_contains_str "$new_desc" "Use when" "rewritten description has trigger phrase"
assert_not_contains_str "$new_desc" '"A thing"' "original weak description replaced"
teardown

# Test 10: --fix-descriptions is idempotent — running twice doesn't double-append
echo ""
echo "--- Fix descriptions: idempotent ---"
setup
cat > "$ZET_TEMPLATES/idempotent_skill_prompt_template.md" <<'EOF'
---
type: skill
description: A thing
---
# Idempotent
Use Read.
EOF
run_optimize_fix
desc_after_first=$(grep 'description:' "$ZET_TEMPLATES/idempotent_skill_prompt_template.md")
run_optimize_fix
desc_after_second=$(grep 'description:' "$ZET_TEMPLATES/idempotent_skill_prompt_template.md")
assert_contains_str "$desc_after_first" "$desc_after_second" "description unchanged after second run"
teardown

# Test 11: --fix-descriptions JSON output includes fix_descriptions field
echo ""
echo "--- Fix descriptions: JSON includes fix_descriptions section ---"
setup
cat > "$ZET_TEMPLATES/json_fix_prompt_template.md" <<'EOF'
---
type: skill
description: A helper
---
# Json
Use Read.
EOF
output=$(run_optimize_fix_json_dryrun)
assert_contains_str "$output" '"fix_descriptions"' "JSON includes fix_descriptions section"
assert_contains_str "$output" '"dry_run": true' "JSON reports dry_run true"
teardown

# Test 12: --fix-descriptions skips already-strong descriptions
echo ""
echo "--- Fix descriptions: skips already-likely descriptions ---"
setup
cat > "$ZET_TEMPLATES/strong_noop_prompt_template.md" <<'EOF'
---
type: skill
description: Use when the user asks for a sprint report with JIRA ticket status updates.
---
# Strong
Use Read to gather data.
EOF
output=$(run_optimize_fix_noargs)
assert_contains_str "$output" "nothing to fix" "reports nothing to fix for strong description"
desc_unchanged=$(grep 'description:' "$ZET_TEMPLATES/strong_noop_prompt_template.md")
assert_contains_str "$desc_unchanged" "Use when the user asks for a sprint report" "strong description not modified"
teardown

zet_test_results
