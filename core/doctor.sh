#!/bin/bash
# Zet Doctor — validate config health and detect common problems
# Usage: doctor.sh [--json] [--fix]
# Dependencies: bash, grep, find
#
# Checks:
#   1. Broken symlinks in output dirs (skills, agents, rules)
#   2. Stale paths in instruction files (CLAUDE.md etc)
#   3. Broken wiki links in templates ([[name_prompt_template]])
#   4. Rule files missing paths: or global: frontmatter
#   5. Template description completeness
#   6. Model-roles staleness (roles referenced but not defined)
#   7. Secret detection (API keys, tokens in templates)
#
# Configuration via environment or zet.toml:
#   ZET_ROOT, ZET_TEMPLATES, ZET_SKILLS, ZET_AGENTS, ZET_RULES
set -eo pipefail

ZET_ROOT="${ZET_ROOT:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
zet_config_init "$ZET_ROOT"

TEMPLATE_DIR="${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}"
SKILLS_DIR="${ZET_SKILLS:-$(zet_config_get "paths" "skills" "$HOME/.claude/skills")}"
AGENTS_DIR="${ZET_AGENTS:-$(zet_config_get "paths" "agents" "$HOME/.claude/agents")}"
RULES_DIR="${ZET_RULES:-$(zet_config_get "paths" "rules" "$HOME/.claude/rules")}"
MODEL_ROLES="${ZET_MODEL_ROLES:-$(zet_config_get "project" "model-roles-file" "$ZET_ROOT/model-roles.conf")}"
INSTRUCTION_FILES="${ZET_INSTRUCTION_FILES:-$(zet_config_get "doctor" "instruction-files" "")}"

JSON_MODE=false
# shellcheck disable=SC2034  # reserved for future --fix implementation
FIX_MODE=false
QUIET=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)  JSON_MODE=true; shift ;;
        --fix)   FIX_MODE=true; shift ;;
        --quiet) QUIET=true; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --- Helpers ---
get_frontmatter_value() {
    local file="$1" key="$2"
    awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^'"$key"':/{sub(/^'"$key"': *"?/,"");sub(/"$/,"");print;exit}' "$file"
}

get_template_type() {
    local file="$1"
    awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^type:/{sub(/^type: */,"");print;exit}' "$file"
}

# Secret patterns — broad enough to catch real leaks, narrow enough to skip examples
SECRET_PATTERNS=(
    'sk-[a-zA-Z0-9]{20,}'          # OpenAI/Anthropic API keys
    'ghp_[a-zA-Z0-9]{36}'          # GitHub personal access tokens
    'ghu_[a-zA-Z0-9]{36}'          # GitHub user tokens
    'xoxb-[0-9]+-[a-zA-Z0-9]+'    # Slack bot tokens
    'xoxp-[0-9]+-[a-zA-Z0-9]+'    # Slack user tokens
    'AKIA[0-9A-Z]{16}'             # AWS access key IDs
    'eyJ[a-zA-Z0-9_-]{30,}\.'     # JWT tokens
)

# --- Collectors ---
declare -a BROKEN_SYMLINKS=()
declare -a STALE_PATHS=()
declare -a BROKEN_WIKI_LINKS=()
declare -a MISSING_RULE_PATHS=()
declare -a MISSING_DESCRIPTIONS=()
declare -a STALE_ROLES=()
declare -a SECRET_HITS=()

# --- 1. Broken symlinks in output dirs ---
for dir in "$SKILLS_DIR" "$AGENTS_DIR" "$RULES_DIR"; do
    [ -d "$dir" ] || continue
    while IFS= read -r link; do
        [ -n "$link" ] && BROKEN_SYMLINKS+=("$link")
    done < <(find "$dir" -type l ! -exec test -e {} \; -print 2>/dev/null)
done

# --- 2. Stale paths in instruction files ---
# Check files listed in [doctor].instruction-files config, or common defaults
if [ -n "$INSTRUCTION_FILES" ]; then
    IFS=',' read -ra inst_files <<< "$INSTRUCTION_FILES"
else
    inst_files=()
    # Check common instruction file locations
    for candidate in "$ZET_ROOT/CLAUDE.md" "$HOME/.claude/CLAUDE.md"; do
        [ -f "$candidate" ] && inst_files+=("$candidate")
    done
fi

for inst_file in "${inst_files[@]}"; do
    [ -f "$inst_file" ] || continue
    # shellcheck disable=SC2088
    while IFS= read -r ref; do
        expanded=$(eval echo "$ref" 2>/dev/null) || continue
        # Skip glob patterns and non-path references
        echo "$expanded" | grep -q '[*{}]' && continue
        if echo "$expanded" | grep -qE '\.(md|sh|json|yaml|yml|toml)$|/$'; then
            if [ ! -e "$expanded" ]; then
                STALE_PATHS+=("$(basename "$inst_file"):$ref")
            fi
        fi
    done < <(grep -oE '~/[A-Za-z0-9_./-]+|(\$HOME)/[A-Za-z0-9_./-]+' "$inst_file" 2>/dev/null | sort -u)
done

# --- 3. Broken wiki links in templates ---
if [ -d "$TEMPLATE_DIR" ]; then
    for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
        [ -f "$file" ] || continue
        filename=$(basename "$file")
        # Extract [[name_prompt_template]] wiki links, skip those inside backtick code spans
        while IFS= read -r ref; do
            match=$(find "$TEMPLATE_DIR" -name "${ref}.md" 2>/dev/null | head -1)
            if [ -z "$match" ]; then
                BROKEN_WIKI_LINKS+=("$filename:[[$ref]]")
            fi
        done < <(grep -v '`\[\[.*_prompt_template' "$file" 2>/dev/null | grep -oE '\[\[[^]]*_prompt_template[^]]*\]\]' | sed 's/\[\[//;s/\]\]//;s/#.*//' | sort -u)
    done
fi

# --- 4. Rule files missing paths: or global: frontmatter ---
if [ -d "$RULES_DIR" ]; then
    for rule in "$RULES_DIR"/*.md; do
        [ -f "$rule" ] || continue
        # Only check Zet-generated rules
        grep -qE "Generated by Zet|AUTO-GENERATED" "$rule" 2>/dev/null || continue
        rulename=$(basename "$rule")
        if ! grep -q '^paths:' "$rule" 2>/dev/null && ! grep -q '^global: true' "$rule" 2>/dev/null; then
            MISSING_RULE_PATHS+=("$rulename")
        fi
    done
fi

# --- 5. Template description completeness ---
if [ -d "$TEMPLATE_DIR" ]; then
    for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
        [ -f "$file" ] || continue
        type=$(get_template_type "$file")
        [ -z "$type" ] && continue
        desc=$(get_frontmatter_value "$file" "description")
        if [ -z "$desc" ]; then
            MISSING_DESCRIPTIONS+=("$(basename "$file")")
        fi
    done
fi

# --- 6. Model-roles staleness ---
if [ -d "$TEMPLATE_DIR" ]; then
    for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
        [ -f "$file" ] || continue
        role=$(get_frontmatter_value "$file" "role")
        [ -z "$role" ] && continue
        if [ ! -f "$MODEL_ROLES" ]; then
            STALE_ROLES+=("$(basename "$file"):$role (no model-roles file)")
        elif ! grep -q "^${role}=" "$MODEL_ROLES" 2>/dev/null; then
            STALE_ROLES+=("$(basename "$file"):$role (undefined)")
        fi
    done
fi

# --- 7. Secret detection in templates ---
if [ -d "$TEMPLATE_DIR" ]; then
    for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
        [ -f "$file" ] || continue
        filename=$(basename "$file")
        for pattern in "${SECRET_PATTERNS[@]}"; do
            if grep -qE "$pattern" "$file" 2>/dev/null; then
                SECRET_HITS+=("$filename:matches $pattern")
                break
            fi
        done
    done
fi

# --- Output ---
TOTAL=$(( ${#BROKEN_SYMLINKS[@]} + ${#STALE_PATHS[@]} + ${#BROKEN_WIKI_LINKS[@]} + ${#MISSING_RULE_PATHS[@]} + ${#MISSING_DESCRIPTIONS[@]} + ${#STALE_ROLES[@]} + ${#SECRET_HITS[@]} ))

if $JSON_MODE; then
    to_json() {
        local arr=("$@")
        if [ ${#arr[@]} -eq 0 ]; then echo "[]"; return; fi
        printf '%s\n' "${arr[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))"
    }
    python3 - \
        "$(to_json "${BROKEN_SYMLINKS[@]}")" \
        "$(to_json "${STALE_PATHS[@]}")" \
        "$(to_json "${BROKEN_WIKI_LINKS[@]}")" \
        "$(to_json "${MISSING_RULE_PATHS[@]}")" \
        "$(to_json "${MISSING_DESCRIPTIONS[@]}")" \
        "$(to_json "${STALE_ROLES[@]}")" \
        "$(to_json "${SECRET_HITS[@]}")" \
        <<'PYEOF'
import json, sys
print(json.dumps({
    "total": sum(len(json.loads(a)) for a in sys.argv[1:]),
    "broken_symlinks": json.loads(sys.argv[1]),
    "stale_paths": json.loads(sys.argv[2]),
    "broken_wiki_links": json.loads(sys.argv[3]),
    "missing_rule_paths": json.loads(sys.argv[4]),
    "missing_descriptions": json.loads(sys.argv[5]),
    "stale_roles": json.loads(sys.argv[6]),
    "secret_hits": json.loads(sys.argv[7]),
}, indent=2))
PYEOF
    exit 0
fi

$QUIET || echo "=== Zet Doctor ==="
$QUIET || echo ""

if [ ${#BROKEN_SYMLINKS[@]} -gt 0 ]; then
    $QUIET || echo "--- Broken Symlinks (${#BROKEN_SYMLINKS[@]}) ---"
    for item in "${BROKEN_SYMLINKS[@]}"; do $QUIET || echo "  - $item"; done
    $QUIET || echo ""
fi

if [ ${#STALE_PATHS[@]} -gt 0 ]; then
    $QUIET || echo "--- Stale Paths in Instruction Files (${#STALE_PATHS[@]}) ---"
    for item in "${STALE_PATHS[@]}"; do $QUIET || echo "  - $item"; done
    $QUIET || echo ""
fi

if [ ${#BROKEN_WIKI_LINKS[@]} -gt 0 ]; then
    $QUIET || echo "--- Broken Wiki Links (${#BROKEN_WIKI_LINKS[@]}) ---"
    for item in "${BROKEN_WIKI_LINKS[@]}"; do $QUIET || echo "  - $item"; done
    $QUIET || echo ""
fi

if [ ${#MISSING_RULE_PATHS[@]} -gt 0 ]; then
    $QUIET || echo "--- Rules Missing paths:/global: (${#MISSING_RULE_PATHS[@]}) ---"
    for item in "${MISSING_RULE_PATHS[@]}"; do $QUIET || echo "  - $item"; done
    $QUIET || echo ""
fi

if [ ${#MISSING_DESCRIPTIONS[@]} -gt 0 ]; then
    $QUIET || echo "--- Templates Missing Description (${#MISSING_DESCRIPTIONS[@]}) ---"
    for item in "${MISSING_DESCRIPTIONS[@]}"; do $QUIET || echo "  - $item"; done
    $QUIET || echo ""
fi

if [ ${#STALE_ROLES[@]} -gt 0 ]; then
    $QUIET || echo "--- Stale Model Roles (${#STALE_ROLES[@]}) ---"
    for item in "${STALE_ROLES[@]}"; do $QUIET || echo "  - $item"; done
    $QUIET || echo ""
fi

if [ ${#SECRET_HITS[@]} -gt 0 ]; then
    $QUIET || echo "--- Potential Secrets (${#SECRET_HITS[@]}) ---"
    for item in "${SECRET_HITS[@]}"; do $QUIET || echo "  - $item"; done
    $QUIET || echo ""
fi

if [ "$TOTAL" -eq 0 ]; then
    $QUIET || echo "Healthy — no issues detected."
else
    $QUIET || echo "=== $TOTAL issue(s) found ==="
fi

exit "$( [ "$TOTAL" -eq 0 ] && echo 0 || echo 1 )"
