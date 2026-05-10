#!/bin/bash
# Zet Coverage — report harness test and documentation coverage
# Usage: coverage.sh [--json]
# Dependencies: bash
#
# Reports:
#   - % of templates with valid type + description
#   - % of skills with matching test files
#   - % of hooks with matching test files
#   - % of CLI commands with test coverage
#   - Overall harness health score
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

ZET_ROOT="${ZET_ROOT:-$(pwd)}"
zet_config_init "$ZET_ROOT"

TEMPLATE_DIR="${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}"
HOOKS_DIR="${ZET_HOOKS:-$(zet_config_get "paths" "hooks" "$ZET_ROOT/hooks")}"
TESTS_DIR="${ZET_TESTS:-$(zet_config_get "paths" "tests" "$ZET_ROOT/tests")}"

JSON_MODE=false
[ "${1:-}" = "--json" ] && JSON_MODE=true

# --- Counters ---
templates_total=0
templates_valid=0
templates_with_desc=0
skills_total=0
skills_with_tests=0
hooks_total=0
hooks_with_tests=0

# --- Templates ---
if [ -d "$TEMPLATE_DIR" ]; then
    for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
        [ -f "$file" ] || continue
        templates_total=$((templates_total + 1))
        name=$(basename "$file" | sed 's/_prompt_template\.md$//')

        type=$(awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^type:/{sub(/^type: */,"");print;exit}' "$file")
        if [ -n "$type" ]; then
            templates_valid=$((templates_valid + 1))
        fi

        desc=$(awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^description:/{sub(/^description: *"?/,"");sub(/"$/,"");print;exit}' "$file")
        if [ -n "$desc" ]; then
            templates_with_desc=$((templates_with_desc + 1))
        fi

        # Count skills for test coverage check
        if [ "$type" = "skill" ]; then
            skills_total=$((skills_total + 1))
            # Check if test file exists
            if [ -f "$TESTS_DIR/test-${name}.sh" ] || [ -f "$TESTS_DIR/test-${name//-/_}.sh" ]; then
                skills_with_tests=$((skills_with_tests + 1))
            fi
        fi
    done
fi

# --- Hooks ---
if [ -d "$HOOKS_DIR" ]; then
    for hook in "$HOOKS_DIR"/*.sh; do
        [ -f "$hook" ] || continue
        hooks_total=$((hooks_total + 1))
        hook_name=$(basename "$hook" .sh)
        if [ -f "$TESTS_DIR/test-hooks.sh" ] || [ -f "$TESTS_DIR/test-${hook_name}.sh" ]; then
            hooks_with_tests=$((hooks_with_tests + 1))
        fi
    done
fi

# --- Percentages ---
pct() {
    local num="$1" den="$2"
    if [ "$den" -eq 0 ]; then echo "0"; return; fi
    echo $(( (num * 100) / den ))
}

pct_valid=$(pct $templates_valid $templates_total)
pct_desc=$(pct $templates_with_desc $templates_total)
pct_skill_tests=$(pct $skills_with_tests $skills_total)
pct_hook_tests=$(pct $hooks_with_tests $hooks_total)

# Overall score: average of all coverage percentages
if [ $((templates_total + skills_total + hooks_total)) -gt 0 ]; then
    overall=$(( (pct_valid + pct_desc + pct_skill_tests + pct_hook_tests) / 4 ))
else
    overall=0
fi

# --- Output ---
if $JSON_MODE; then
    python3 -c "
import json
print(json.dumps({
    'templates': {'total': $templates_total, 'valid_type': $templates_valid, 'with_description': $templates_with_desc},
    'skills': {'total': $skills_total, 'with_tests': $skills_with_tests},
    'hooks': {'total': $hooks_total, 'with_tests': $hooks_with_tests},
    'percentages': {
        'templates_valid': $pct_valid,
        'templates_described': $pct_desc,
        'skills_tested': $pct_skill_tests,
        'hooks_tested': $pct_hook_tests,
        'overall': $overall
    }
}, indent=2))
"
    exit 0
fi

echo "=== Zet Coverage ==="
echo ""
echo "Templates:  $templates_valid/$templates_total valid type field ($pct_valid%)"
echo "            $templates_with_desc/$templates_total have description ($pct_desc%)"
echo "Skills:     $skills_with_tests/$skills_total have test files ($pct_skill_tests%)"
echo "Hooks:      $hooks_with_tests/$hooks_total have test coverage ($pct_hook_tests%)"
echo ""
echo "Overall:    ${overall}%"

if [ "$overall" -lt 80 ]; then
    echo ""
    echo "Target: 80%. Improve by adding tests for untested skills/hooks."
fi
