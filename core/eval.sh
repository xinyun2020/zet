#!/bin/bash
# Zet Eval — three-layer skill quality measurement
#
# Purpose:
#   Evaluates skill templates against golden scenarios to verify they
#   produce correct output. Three layers (cheapest first):
#     Layer 1: Deterministic assertions (regex, exit codes, structure)
#     Layer 2: LLM judge (semantic correctness, binary pass/fail)
#     Layer 3: Human calibration (manual review queue)
#
# Usage:
#   eval.sh [skill-name] [--layer 1|2|3] [--json] [--quiet]
#
# Options:
#   skill-name   Run evals for one skill only (default: all)
#   --layer N    Run only up to layer N (default: 1)
#   --json       Output results as structured JSON
#   --quiet      Suppress human-readable output (exit code only)
#   --verbose    Show assertion details even on pass
#
# Exit codes:
#   0 — all scenarios pass
#   1 — one or more scenarios fail
#   2 — no eval scenarios found
#
# Dependencies: bash, grep, awk, python3 (JSON output)
#
# Eval scenario convention:
#   evals/{skill-name}/
#     scenario-{name}.md      — golden scenario file (YAML frontmatter + input)
#
# Scenario file format:
#   ---
#   description: what this scenario tests
#   layer: 1                        # which layer (default: 1)
#   assertions:
#     - type: contains
#       value: "expected string"
#     - type: not_contains
#       value: "should not appear"
#     - type: regex
#       value: "^feat\\(.*\\):"
#     - type: exit_code
#       value: "0"
#     - type: file_exists
#       value: "output/result.json"
#     - type: json_valid
#     - type: line_count_min
#       value: "5"
#     - type: line_count_max
#       value: "50"
#   ---
#   (input/context below frontmatter — passed to the skill as simulated input)
#
set -eo pipefail

ZET_ROOT="${ZET_ROOT:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/frontmatter.sh"
zet_config_init "$ZET_ROOT"

EVAL_DIR="$(resolve_path "${ZET_EVALS:-$(zet_config_get "paths" "evals" "$ZET_ROOT/evals")}")"
TEMPLATE_DIR="$(resolve_path "${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}")"

# --- Argument parsing ---
TARGET_SKILL=""
MAX_LAYER=1
JSON_MODE=false
QUIET=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --layer)  MAX_LAYER="$2"; shift 2 ;;
        --json)   JSON_MODE=true; shift ;;
        --quiet)  QUIET=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --*)      echo "Unknown option: $1" >&2; exit 1 ;;
        *)        TARGET_SKILL="$1"; shift ;;
    esac
done

# --- Validation ---
if [ ! -d "$EVAL_DIR" ]; then
    if $JSON_MODE; then
        echo '{"error": "no evals directory", "total": 0, "passed": 0, "failed": 0}'
    else
        $QUIET || echo "No evals/ directory found in $ZET_ROOT"
    fi
    exit 2
fi

# --- Assertion runners ---

# Run a single assertion against output text
# Returns 0 on pass, 1 on fail. Prints detail to stdout.
run_assertion() {
    local type="$1" value="$2" output="$3" context_dir="$4"

    case "$type" in
        contains)
            if echo "$output" | grep -qF "$value"; then
                return 0
            else
                echo "expected to contain: '$value'"
                return 1
            fi
            ;;
        not_contains)
            if ! echo "$output" | grep -qF "$value"; then
                return 0
            else
                echo "expected NOT to contain: '$value'"
                return 1
            fi
            ;;
        regex)
            if echo "$output" | grep -qE "$value"; then
                return 0
            else
                echo "expected to match regex: '$value'"
                return 1
            fi
            ;;
        not_regex)
            if ! echo "$output" | grep -qE "$value"; then
                return 0
            else
                echo "expected NOT to match regex: '$value'"
                return 1
            fi
            ;;
        exit_code)
            # Special: checked by caller before calling run_assertion
            return 0
            ;;
        file_exists)
            local check_path="$context_dir/$value"
            if [ -e "$check_path" ]; then
                return 0
            else
                echo "expected file to exist: '$value'"
                return 1
            fi
            ;;
        json_valid)
            if echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
                return 0
            else
                echo "expected valid JSON output"
                return 1
            fi
            ;;
        line_count_min)
            local count
            count=$(echo "$output" | wc -l | tr -d ' ')
            if [ "$count" -ge "$value" ]; then
                return 0
            else
                echo "expected at least $value lines, got $count"
                return 1
            fi
            ;;
        line_count_max)
            local count
            count=$(echo "$output" | wc -l | tr -d ' ')
            if [ "$count" -le "$value" ]; then
                return 0
            else
                echo "expected at most $value lines, got $count"
                return 1
            fi
            ;;
        *)
            echo "unknown assertion type: '$type'"
            return 1
            ;;
    esac
}

# Parse assertions from scenario YAML frontmatter
# Outputs: type|value pairs, one per line
parse_assertions() {
    local file="$1"
    # Extract assertions block from frontmatter
    awk '
    BEGIN { in_fm=0; in_assertions=0 }
    /^---$/ { in_fm++; next }
    in_fm == 1 && /^assertions:/ { in_assertions=1; next }
    in_fm == 1 && in_assertions && /^  - type:/ {
        gsub(/^  - type: *"?/, ""); gsub(/"? *$/, "")
        type=$0
        next
    }
    in_fm == 1 && in_assertions && /^    value:/ {
        gsub(/^    value: *"?/, ""); gsub(/"? *$/, "")
        print type "|" $0
        next
    }
    in_fm == 1 && in_assertions && /^  - type:/ == 0 && /^    / == 0 && /^$/ == 0 {
        # End of assertions block (hit a non-indented line)
        if (!/^  -/) in_assertions=0
    }
    ' "$file"
}

# Get scenario input (body after frontmatter)
get_scenario_input() {
    local file="$1"
    awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2{print}' "$file"
}

# --- Main eval loop ---
declare -a RESULTS=()
TOTAL=0
PASSED=0
FAILED=0

# Find eval directories to run
if [ -n "$TARGET_SKILL" ]; then
    eval_dirs=("$EVAL_DIR/$TARGET_SKILL")
    if [ ! -d "${eval_dirs[0]}" ]; then
        $QUIET || echo "No evals found for skill: $TARGET_SKILL"
        exit 2
    fi
else
    eval_dirs=()
    for d in "$EVAL_DIR"/*/; do
        [ -d "$d" ] && eval_dirs+=("$d")
    done
fi

if [ ${#eval_dirs[@]} -eq 0 ]; then
    if $JSON_MODE; then
        echo '{"error": "no eval scenarios", "total": 0, "passed": 0, "failed": 0}'
    else
        $QUIET || echo "No eval scenarios found in $EVAL_DIR"
    fi
    exit 2
fi

for skill_dir in "${eval_dirs[@]}"; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")

    # Check template exists
    template="$TEMPLATE_DIR/${skill_name}_prompt_template.md"
    if [ ! -f "$template" ]; then
        RESULTS+=("$skill_name:SKIP:template not found")
        continue
    fi

    # Run each scenario
    for scenario in "$skill_dir"/scenario-*.md; do
        [ -f "$scenario" ] || continue
        scenario_name=$(basename "$scenario" .md | sed 's/^scenario-//')
        TOTAL=$((TOTAL + 1))

        # Get scenario metadata
        scenario_desc=$(get_frontmatter_value "$scenario" "description")
        scenario_layer=$(get_frontmatter_value "$scenario" "layer")
        scenario_layer=${scenario_layer:-1}

        # Skip if scenario layer exceeds requested max
        if [ "$scenario_layer" -gt "$MAX_LAYER" ]; then
            RESULTS+=("$skill_name/$scenario_name:SKIP:layer $scenario_layer > max $MAX_LAYER")
            TOTAL=$((TOTAL - 1))
            continue
        fi

        # Layer 1: deterministic assertions
        if [ "$scenario_layer" -le 1 ]; then
            # Get input and run assertions against it
            input=$(get_scenario_input "$scenario")
            scenario_passed=true
            fail_details=""

            # Parse and run each assertion
            while IFS='|' read -r atype avalue; do
                [ -z "$atype" ] && continue
                detail=$(run_assertion "$atype" "$avalue" "$input" "$skill_dir" 2>&1) || {
                    scenario_passed=false
                    fail_details="${fail_details}${atype}(${avalue}): ${detail}; "
                }
            done < <(parse_assertions "$scenario")

            if $scenario_passed; then
                PASSED=$((PASSED + 1))
                RESULTS+=("$skill_name/$scenario_name:PASS:$scenario_desc")
                $VERBOSE && ! $QUIET && echo "  PASS: $skill_name/$scenario_name — $scenario_desc"
            else
                FAILED=$((FAILED + 1))
                RESULTS+=("$skill_name/$scenario_name:FAIL:$fail_details")
                $QUIET || echo "  FAIL: $skill_name/$scenario_name — $fail_details"
            fi
        fi

        # Layer 2: LLM judge (stub — not implemented yet)
        # Layer 3: Human calibration (stub — not implemented yet)
    done
done

# --- Output ---
if $JSON_MODE; then
    python3 - "${RESULTS[@]}" <<'PYEOF'
import json, sys
results = []
for r in sys.argv[1:]:
    parts = r.split(":", 2)
    if len(parts) >= 3:
        results.append({"scenario": parts[0], "status": parts[1], "detail": parts[2]})
passed = sum(1 for r in results if r["status"] == "PASS")
failed = sum(1 for r in results if r["status"] == "FAIL")
skipped = sum(1 for r in results if r["status"] == "SKIP")
print(json.dumps({
    "total": passed + failed,
    "passed": passed,
    "failed": failed,
    "skipped": skipped,
    "results": results
}, indent=2))
PYEOF
    exit "$( [ "$FAILED" -eq 0 ] && echo 0 || echo 1 )"
fi

$QUIET || echo ""
$QUIET || echo "=== Zet Eval ==="
$QUIET || echo "  Layer: 1 (deterministic)"
$QUIET || echo "  Total: $TOTAL | Passed: $PASSED | Failed: $FAILED"

if [ "$FAILED" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
    $QUIET || echo "  All scenarios passed."
    exit 0
elif [ "$TOTAL" -eq 0 ]; then
    $QUIET || echo "  No scenarios to run."
    exit 2
else
    $QUIET || echo ""
    $QUIET || echo "  Failures:"
    for r in "${RESULTS[@]}"; do
        if echo "$r" | grep -q ":FAIL:"; then
            $QUIET || echo "    - $r"
        fi
    done
    exit 1
fi
