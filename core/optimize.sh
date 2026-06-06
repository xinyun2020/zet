#!/bin/bash
# Zet Optimize — harness performance and security analysis
#
# Purpose:
#   Analyzes skill templates for optimization opportunities:
#   1. Permission surface audit — what tools each skill can access (attack surface)
#   2. Redundancy detection — overlapping instructions across skills
#   3. Token cost estimation — per-skill context cost
#
#   Unlike doctor (which finds broken things), optimize finds inefficiencies
#   and security over-exposure in working configurations.
#
# Usage:
#   optimize.sh [--json] [--quiet] [--verbose]
#
# Options:
#   --json     Output as structured JSON
#   --quiet    Exit code only (0=optimized, 1=opportunities found)
#   --verbose  Show per-skill detail even when no issues
#
# Exit codes:
#   0 — no optimization opportunities (or informational only)
#   1 — actionable optimizations found
#
# Dependencies: bash, grep, awk, python3 (JSON output + redundancy analysis)
set -eo pipefail

ZET_ROOT="${ZET_ROOT:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/frontmatter.sh"
zet_config_init "$ZET_ROOT"

TEMPLATE_DIR="$(resolve_path "${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}")"

JSON_MODE=false
QUIET=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    JSON_MODE=true; shift ;;
        --quiet)   QUIET=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --- Tool detection patterns ---
# Maps tool names to regex patterns that indicate usage
# High-privilege tools (can modify state or execute arbitrary code)
HIGH_PRIV_TOOLS="Bash|Write|Edit|NotebookEdit|Agent"
# Medium-privilege tools (can read sensitive data or communicate externally)
MED_PRIV_TOOLS="WebFetch|WebSearch|mcp__"
# Low-privilege tools (read-only, local)
LOW_PRIV_TOOLS="Read|Grep|Glob|Skill|TaskCreate|TaskUpdate"

# All recognized tool patterns
ALL_TOOLS="Bash|Write|Edit|Read|Grep|Glob|Agent|WebFetch|WebSearch|NotebookEdit|Skill|TaskCreate|TaskUpdate|mcp__[a-zA-Z0-9_]+"

# --- Analysis ---

declare -a SKILL_NAMES=()
declare -a SKILL_TOOLS=()
declare -a SKILL_RISKS=()
declare -a SKILL_TOKENS=()
declare -a SKILL_BODIES=()
TOTAL_SKILLS=0

if [ -d "$TEMPLATE_DIR" ]; then
    for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
        [ -f "$file" ] || continue
        type=$(get_template_type "$file")
        [ "$type" = "skill" ] || [ "$type" = "agent" ] || continue

        TOTAL_SKILLS=$((TOTAL_SKILLS + 1))
        name=$(basename "$file" .md)
        SKILL_NAMES+=("$name")

        # Get body (after frontmatter)
        body=$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2{print}' "$file")
        SKILL_BODIES+=("$body")

        # --- 1. Permission surface audit ---
        # Find all tool references in body
        tools_found=$(echo "$body" | grep -oE "$ALL_TOOLS" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || true)
        tools_found=${tools_found:-"none"}
        SKILL_TOOLS+=("$tools_found")

        # Classify risk level
        risk="low"
        if echo "$tools_found" | grep -qE "$HIGH_PRIV_TOOLS"; then
            risk="high"
        elif echo "$tools_found" | grep -qE "$MED_PRIV_TOOLS"; then
            risk="medium"
        fi
        SKILL_RISKS+=("$risk")

        # --- 3. Token cost estimation ---
        # Rough estimate: ~4 chars per token (conservative for English + code)
        char_count=${#body}
        token_estimate=$(( (char_count + 3) / 4 ))
        SKILL_TOKENS+=("$token_estimate")
    done
fi

# --- 2. Redundancy detection ---
# Find overlapping lines across skill bodies (3+ shared non-trivial lines = redundant)
REDUNDANCY_PAIRS=""
if [ "$TOTAL_SKILLS" -gt 1 ]; then
    REDUNDANCY_PAIRS=$(python3 - "${SKILL_NAMES[@]}" <<'PYEOF'
import sys, os, json

template_dir = os.environ.get("ZET_TEMPLATES", "templates")
names = sys.argv[1:]

# Read bodies (after frontmatter)
bodies = {}
for name in names:
    path = os.path.join(template_dir, name + ".md")
    if not os.path.isfile(path):
        continue
    with open(path) as f:
        content = f.read()
    # Extract body after second ---
    parts = content.split("---", 2)
    if len(parts) >= 3:
        bodies[name] = parts[2].strip()

# Compare pairs: find shared non-trivial lines (>20 chars)
pairs = []
name_list = list(bodies.keys())
for i in range(len(name_list)):
    lines_i = set(l.strip() for l in bodies[name_list[i]].split('\n') if len(l.strip()) > 20)
    for j in range(i+1, len(name_list)):
        lines_j = set(l.strip() for l in bodies[name_list[j]].split('\n') if len(l.strip()) > 20)
        shared = lines_i & lines_j
        if len(shared) >= 3:
            pairs.append({
                "skill_a": name_list[i],
                "skill_b": name_list[j],
                "shared_lines": len(shared),
                "sample": list(shared)[:3]
            })

print(json.dumps(pairs))
PYEOF
    )
fi
REDUNDANCY_PAIRS=${REDUNDANCY_PAIRS:-"[]"}

# --- Output ---
HAS_HIGH_RISK=false
HAS_REDUNDANCY=false
for risk in "${SKILL_RISKS[@]}"; do
    [ "$risk" = "high" ] && HAS_HIGH_RISK=true
done
[ "$REDUNDANCY_PAIRS" != "[]" ] && HAS_REDUNDANCY=true

if $JSON_MODE; then
    # Build pipe-separated data for python
    skills_data=""
    for i in "${!SKILL_NAMES[@]}"; do
        skills_data="${skills_data}${SKILL_NAMES[$i]}|${SKILL_TOOLS[$i]}|${SKILL_RISKS[$i]}|${SKILL_TOKENS[$i]}"$'\n'
    done

    printf '%s' "$skills_data" | python3 -c "
import sys, json

lines = [l for l in sys.stdin.read().strip().split('\n') if l]
redundancy = json.loads('''$REDUNDANCY_PAIRS''')

permissions = []
token_costs = []
for line in lines:
    parts = line.split('|', 3)
    if len(parts) < 4:
        continue
    name, tools_str, risk, tokens = parts
    tool_list = [t.strip() for t in tools_str.split(',') if t.strip() and t.strip() != 'none']
    permissions.append({'skill': name, 'tools': tool_list, 'risk': risk})
    token_costs.append({'skill': name, 'estimated_tokens': int(tokens)})

print(json.dumps({
    'total_skills': len(lines),
    'permissions': permissions,
    'token_costs': token_costs,
    'redundancy': redundancy
}, indent=2))
"
    exit 0
fi

# Human-readable output
$QUIET || echo "=== Zet Optimize ==="
$QUIET || echo ""
$QUIET || echo "Skills analyzed: $TOTAL_SKILLS"
$QUIET || echo ""

if [ "$TOTAL_SKILLS" -eq 0 ]; then
    $QUIET || echo "No skills found."
    exit 0
fi

# Permission surfaces
$QUIET || echo "--- Permission Surface ---"
for i in "${!SKILL_NAMES[@]}"; do
    risk="${SKILL_RISKS[$i]}"
    if [ "$risk" = "high" ] || $VERBOSE; then
        $QUIET || echo "  ${SKILL_NAMES[$i]}: [${risk}] ${SKILL_TOOLS[$i]}"
    fi
done
$QUIET || echo ""

# Token costs (sorted by size, show top 10)
$QUIET || echo "--- Token Cost (top by size) ---"
for i in "${!SKILL_NAMES[@]}"; do
    $QUIET || echo "  ${SKILL_NAMES[$i]}: ~${SKILL_TOKENS[$i]} tokens"
done
$QUIET || echo ""

# Redundancy
if $HAS_REDUNDANCY; then
    $QUIET || echo "--- Redundancy ---"
    $QUIET || echo "  Overlapping instruction blocks detected."
    $QUIET || echo "  Run with --json for details."
    $QUIET || echo ""
fi

if $HAS_HIGH_RISK || $HAS_REDUNDANCY; then
    $QUIET || echo "=== Optimization opportunities found ==="
    exit 1
else
    $QUIET || echo "Optimized — no actionable issues."
    exit 0
fi
