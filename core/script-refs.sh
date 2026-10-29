#!/bin/bash
# Zet Script Refs — script-usage matrix + dangling template-script validation
# Usage: script-refs.sh [--json] [--check]
# Dependencies: bash, grep, sed, python3 (JSON mode only)
#
# Design (2026-09-28, Agent Skills): a template that mentions a script must point
# at a script that actually exists, and the framework should surface WHICH scripts
# each template uses — the usage picture that decides which scripts are shared
# (promote to a shared root) vs skill-local (symlink into the generated skill folder).
#
# A script reference is any `.sh`/`.py` path token in the template body (URLs are
# stripped first so link targets are not mistaken for local files). A reference is
# DANGLING when none of these resolve to an existing file:
#   1. the path as written (`~` expanded, absolute kept)
#   2. relative to ZET_ROOT (repo-rooted references like `scripts/foo.sh`)
#   3. relative to the template directory (skill-local scripts)
#   4. basename match under a configured script root — `[paths] scripts` in
#      zet.toml, colon-separated for multiple roots (the shared-script area)
#
# Function library (source this file):
#   extract_script_refs <file>          — unique script refs, newline-separated
#   resolve_script_ref <ref> <tmpl_dir> — prints resolved path, exit 0; exit 1 if dangling
#
# CLI (execute this file):
#   script-refs.sh              human-readable script-usage matrix (exit 0)
#   script-refs.sh --check      same matrix, exit 1 if any dangling ref
#   script-refs.sh --json       machine-readable matrix
#
# Configuration via environment or zet.toml:
#   ZET_ROOT, ZET_TEMPLATES, and [paths] scripts (shared script roots)

set -eo pipefail

ZET_ROOT="${ZET_ROOT:-$(pwd)}"
# BASH_SOURCE (not $0) so the module still finds its siblings when sourced from tests
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/frontmatter.sh"
zet_config_init "$ZET_ROOT"

# --- Reference extraction ---

# Extract unique script references (.sh/.py path tokens) from a template.
# URLs are stripped first — the path fragment after https://... is not a local file.
# Args: file_path
# Returns: newline-separated unique refs, sorted
extract_script_refs() {
    local file="$1"
    sed -E 's#https?://[^[:space:])]+##g' "$file" \
        | grep -oE '[A-Za-z0-9_./~-]+\.(sh|py)' \
        | sort -u || true
}

# Resolve one script reference to an existing file.
# Args: ref, template_dir
# Returns: resolved absolute-ish path on stdout, exit 0; exit 1 if dangling
resolve_script_ref() {
    local ref="$1" template_dir="$2" candidate base root
    local -a roots=()

    # 1. Path as written (~ expanded, absolute kept)
    candidate="${ref/#\~/$HOME}"
    if [ -e "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    # 2. ZET_ROOT-relative
    candidate="$ZET_ROOT/$ref"
    if [ -e "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    # 3. Template-dir-relative (skill-local script)
    candidate="$template_dir/$ref"
    if [ -e "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    # 4. Shared script roots ([paths] scripts, colon-separated) — basename match.
    # Re-init so a ZET_ROOT set after sourcing is honored.
    zet_config_init "$ZET_ROOT"
    base="${ref##*/}"
    local configured
    configured=$(zet_config_get "paths" "scripts" "")
    if [ -n "$configured" ]; then
        local IFS=':'
        for root in $configured; do
            [ -n "$root" ] || continue
            # a relative root is relative to ZET_ROOT, like other [paths] entries
            [[ "$root" == /* ]] || root="$ZET_ROOT/$root"
            candidate="$root/$base"
            if [ -e "$candidate" ]; then
                echo "$candidate"
                return 0
            fi
        done
    fi

    return 1
}

# --- CLI ---
main() {

JSON_MODE=false
CHECK_MODE=false
for arg in "$@"; do
    case "$arg" in
        --json)  JSON_MODE=true ;;
        --check) CHECK_MODE=true ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

TEMPLATE_DIR="$(resolve_path "${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}")"

if [ ! -d "$TEMPLATE_DIR" ]; then
    echo "ERROR: template directory not found: $TEMPLATE_DIR" >&2
    exit 1
fi

# TSV rows: template<TAB>ref<TAB>ok|dangling<TAB>resolved
TSV="$(mktemp)"
trap 'rm -f "$TSV"' EXIT

for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if resolved=$(resolve_script_ref "$ref" "$TEMPLATE_DIR"); then
            printf '%s\t%s\tok\t%s\n' "$name" "$ref" "$resolved" >> "$TSV"
        else
            printf '%s\t%s\tdangling\t\n' "$name" "$ref" >> "$TSV"
        fi
    done < <(extract_script_refs "$file")
done

if $JSON_MODE; then
    python3 - "$TSV" <<'PY'
import json, sys

templates = {}   # name -> {template, refs}
shared = {}      # resolved path -> set of template names
dangling = []

with open(sys.argv[1]) as f:
    for line in f:
        name, ref, status, resolved = line.rstrip("\n").split("\t", 3)
        entry = templates.setdefault(name, {"template": name, "refs": []})
        entry["refs"].append(
            {"ref": ref, "status": status, "resolved": resolved or None}
        )
        if status == "ok":
            shared.setdefault(resolved, set()).add(name)
        else:
            dangling.append({"template": name, "ref": ref})

shared_list = [
    {"script": s, "templates": sorted(t)}
    for s, t in sorted(shared.items())
    if len(t) > 1
]
print(json.dumps({
    "templates": list(templates.values()),
    "shared": shared_list,
    "dangling": dangling,
}, indent=2))
PY
else
    echo "=== Zet Script Usage Matrix ==="
    echo "Checking: $TEMPLATE_DIR"
    echo ""

    dangling_count=0
    declare -A shared_map=()
    prev_name=""
    while IFS=$'\t' read -r name ref status resolved; do
        if [ "$name" != "$prev_name" ]; then
            echo "$name"
            prev_name="$name"
        fi
        if [ "$status" = "dangling" ]; then
            echo "  $ref  DANGLING (no file at repo root, template dir, or script roots)"
            dangling_count=$((dangling_count + 1))
        else
            echo "  $ref  ok → $resolved"
            shared_map["${ref##*/}"]+="$name "
        fi
    done < "$TSV"

    shared_count=0
    for base in "${!shared_map[@]}"; do
        names="${shared_map[$base]}"
        set -- $names
        if [ "$#" -ge 2 ]; then
            if [ "$shared_count" -eq 0 ]; then
                echo ""
                echo "Shared scripts (used by 2+ templates):"
            fi
            echo "  $base — $# templates"
            shared_count=$((shared_count + 1))
        fi
    done

    echo ""
    if [ "$dangling_count" -eq 0 ]; then
        echo "  No dangling script references."
    else
        echo "  $dangling_count dangling script reference(s)."
    fi
    if $CHECK_MODE && [ "$dangling_count" -gt 0 ]; then
        exit 1
    fi
    exit 0
fi
}

# Run the CLI only when executed, not when sourced as a function library
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
