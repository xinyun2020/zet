#!/bin/bash
# Zet Generator — build skills/agents/rules from prompt templates
# Usage: generator.sh [--dry] [--quiet]
# Dependencies: bash, grep, sed, awk
#
# Reads zet.toml (or ZET_* env vars) for paths.
# Scans template dir for *_prompt_template.md files, routes by type: field.
#
# Environment variables (override zet.toml):
#   ZET_ROOT         — project root (default: current directory)
#   ZET_TEMPLATES    — template source dir (default: $ZET_ROOT/templates)
#   ZET_SKILLS       — skill output dir (default: ~/.claude/skills)
#   ZET_AGENTS       — agent output dir (default: ~/.claude/agents)
#   ZET_RULES        — rule output dir (default: ~/.claude/rules)
#   ZET_MODEL_ROLES  — model-roles config file path
set -e

# --- Config resolution ---
ZET_ROOT="${ZET_ROOT:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
zet_config_init "$ZET_ROOT"

# Resolve paths from config. Relative paths become absolute (relative to ZET_ROOT)
# because generated files (skills, agents, rules) live OUTSIDE the project tree
# (e.g. ~/.claude/skills/) — relative paths in "follow" instructions would break.
resolve_path() {
    local path="$1"
    path="${path%/}"  # strip trailing slash
    [[ "$path" == /* ]] && echo "$path" && return  # already absolute
    echo "$ZET_ROOT/$path"
}

TEMPLATE_DIR="$(resolve_path "${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}")"
SKILLS_DIR="$(resolve_path "${ZET_SKILLS:-$(zet_config_get "paths" "skills" "$HOME/.claude/skills")}")"
AGENTS_DIR="$(resolve_path "${ZET_AGENTS:-$(zet_config_get "paths" "agents" "$HOME/.claude/agents")}")"
RULES_DIR="$(resolve_path "${ZET_RULES:-$(zet_config_get "paths" "rules" "$HOME/.claude/rules")}")"
# Model roles: read from [model-roles] section in zet.toml (preferred),
# fall back to standalone file for backwards compatibility
MODEL_ROLES_FILE="$(resolve_path "${ZET_MODEL_ROLES:-$(zet_config_get "project" "model-roles-file" "$ZET_ROOT/model-roles.conf")}")"

DRY_RUN=false
QUIET=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry)   DRY_RUN=true; shift ;;
        --quiet) QUIET=true; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --- Validation ---
if [ ! -d "$TEMPLATE_DIR" ]; then
    echo "ERROR: template directory not found: $TEMPLATE_DIR" >&2
    echo "  Set ZET_TEMPLATES or configure [paths].templates in zet.toml" >&2
    exit 1
fi

$QUIET || echo "=== Zet Generate ==="
$QUIET || echo "Templates: $TEMPLATE_DIR"
$QUIET || echo "Output: skills=$SKILLS_DIR | agents=$AGENTS_DIR | rules=$RULES_DIR"
! $QUIET && $DRY_RUN && echo "DRY RUN — no files will be written"

# --- Helpers ---
ensure_dir() {
    local dir="$1"
    if [ -L "$dir" ] && [ -d "$dir" ]; then
        # Symlink to valid directory — use it as-is (e.g. ~/.claude/skills -> obsidian source)
        return 0
    elif [ -L "$dir" ]; then
        # Broken symlink — remove and create real dir
        $DRY_RUN || rm "$dir"
    fi
    $DRY_RUN || mkdir -p "$dir"
}

resolve_model_role() {
    local role="$1"
    # Prefer zet.toml [model-roles] section (no file needed)
    local val
    val=$(zet_config_get "model-roles" "$role" "")
    if [ -n "$val" ]; then
        echo "$val"
        return 0
    fi
    # Fall back to standalone model-roles file
    if [ -f "$MODEL_ROLES_FILE" ]; then
        grep -v "^#" "$MODEL_ROLES_FILE" | grep "^${role}=" | cut -d= -f2
        return 0
    fi
    return 1
}

get_template_type() {
    local file="$1"
    awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^type:/{sub(/^type: */,"");print;exit}' "$file"
}

get_frontmatter_value() {
    local file="$1" key="$2"
    awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^'"$key"':/{sub(/^'"$key"': *"?/,"");sub(/"$/,"");print;exit}' "$file"
}

generate_file() {
    local source="$1" target="$2" type="$3"
    local source_name derived_name
    source_name=$(basename "$source")
    derived_name=$(echo "$source_name" | sed 's/_prompt_template\.md$//')

    $DRY_RUN && { $QUIET || echo "  [dry] $target"; return; }

    [ -L "$target" ] && rm "$target"

    {
        local in_frontmatter=false
        local frontmatter_done=false
        local marker_written=false
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "---" ]; then
                if $in_frontmatter; then
                    echo "$line"
                    in_frontmatter=false
                    frontmatter_done=true
                    continue
                else
                    echo "$line"
                    [ "$type" = "agent" ] && echo "name: $derived_name"
                    in_frontmatter=true
                    continue
                fi
            fi

            if $in_frontmatter; then
                case "$line" in
                    type:\ *)  continue ;;
                    name:\ *)  continue ;;
                    role:\ *)
                        role_val="${line#role: }"
                        resolved=$(resolve_model_role "$role_val" || true)
                        if [ -n "$resolved" ]; then
                            echo "model: $resolved"
                        else
                            echo "  WARNING: unknown role '$role_val' in $source_name" >&2
                        fi
                        ;;
                    *) echo "$line" ;;
                esac
            else
                if $frontmatter_done && ! $marker_written; then
                    echo "<!-- Generated by Zet from $source_name — do not edit directly -->"
                    echo "<!-- Regenerate: zet generate -->"
                    marker_written=true
                fi
                echo "$line"
            fi
        done < "$source"

        if $frontmatter_done && ! $marker_written; then
            echo "<!-- Generated by Zet from $source_name — do not edit directly -->"
            echo "<!-- Regenerate: zet generate -->"
        fi
    } > "$target"
}

# --- Ensure output dirs ---
ensure_dir "$SKILLS_DIR"
ensure_dir "$AGENTS_DIR"
ensure_dir "$RULES_DIR"

# --- Generate ---
skill_count=0
agent_count=0
rule_count=0
seen_names=""

for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
    [ -f "$file" ] || continue

    filename=$(basename "$file")
    name=$(echo "$filename" | sed 's/_prompt_template\.md$//')
    type=$(get_template_type "$file")

    [ -z "$type" ] && continue

    # Duplicate check
    if echo "$seen_names" | grep -qw "$name"; then
        echo "  ERROR: duplicate name '$name' — skipping" >&2
        continue
    fi
    seen_names="$seen_names $name"

    case "$type" in
        skill)
            desc=$(get_frontmatter_value "$file" "description")
            if [ -z "$desc" ]; then
                echo "  WARNING: $filename missing description — skipping" >&2
                continue
            fi

            model=$(get_frontmatter_value "$file" "model")
            role=$(get_frontmatter_value "$file" "role")
            args=$(get_frontmatter_value "$file" "args")
            ctx=$(get_frontmatter_value "$file" "context")

            if [ -n "$role" ]; then
                resolved=$(resolve_model_role "$role" || true)
                [ -n "$resolved" ] && model="$resolved"
            fi

            # Extract prompt field and strip auto-derivable self-reference prefix.
            # Templates may include "follow templates/{name}_prompt_template.md" in
            # the prompt: field, but the generator already emits this path. Strip the
            # redundant prefix, keeping only extra args/context after it.
            raw_prompt=$(get_frontmatter_value "$file" "prompt")
            prompt_extra=""
            if [ -n "$raw_prompt" ]; then
                # Match both relative and absolute self-references
                self_ref="follow $TEMPLATE_DIR/${filename}"
                rel_ref="follow ${TEMPLATE_DIR##*/}/${filename}"
                for ref in "$self_ref" "$rel_ref"; do
                    case "$raw_prompt" in
                        "${ref}\\n"*)  prompt_extra="${raw_prompt#${ref}\\n}"; break ;;
                        "${ref} "*)    prompt_extra="${raw_prompt#${ref} }"; break ;;
                        "${ref}")      prompt_extra=""; break ;;
                    esac
                done
                # If no self-reference matched, keep the entire prompt value
                if [ -z "$prompt_extra" ] && [ "$raw_prompt" != "$self_ref" ] && [ "$raw_prompt" != "$rel_ref" ]; then
                    prompt_extra="$raw_prompt"
                fi
            fi

            skill_dir="$SKILLS_DIR/$name"
            $DRY_RUN || mkdir -p "$skill_dir"

            if ! $DRY_RUN; then
                {
                    echo "---"
                    echo "name: $name"
                    echo "description: $desc"
                    echo "user-invocable: true"
                    [ -n "$args" ] && echo "argument-hint: \"$args\""
                    [ -n "$model" ] && echo "model: $model"
                    [ -n "$ctx" ] && echo "context: $ctx"
                    echo "---"
                    echo "<!-- Generated by Zet from $filename — do not edit directly -->"
                    echo "<!-- Regenerate: zet generate -->"
                    echo ""
                    printf 'follow %s\n' "$TEMPLATE_DIR/$filename"
                    if [ -n "$prompt_extra" ]; then
                        printf '%s' "$prompt_extra" | sed 's/\\n/\n/g'
                        echo ""
                    fi
                    echo ""
                    echo "Read the template file first, then execute its instructions completely."
                } > "$skill_dir/SKILL.md"
            fi

            $QUIET || echo "  skill: $name"
            skill_count=$((skill_count + 1))
            ;;

        agent)
            generate_file "$file" "$AGENTS_DIR/$name.md" "agent"
            $QUIET || echo "  agent: $name"
            agent_count=$((agent_count + 1))
            ;;

        rule)
            generate_file "$file" "$RULES_DIR/$name.md" "rule"
            $QUIET || echo "  rule: $name"
            rule_count=$((rule_count + 1))
            ;;

        *)
            echo "  WARNING: unknown type '$type' in $filename — skipping" >&2
            ;;
    esac
done

# --- Cleanup stale generated files ---
is_generated_file() {
    # Only clean up files Zet itself created — never touch legacy or hand-written files
    local file="$1"
    grep -q "Generated by Zet" "$file" 2>/dev/null
}

cleanup_stale() {
    local dir="$1" ext="$2" type="$3"
    for file in "$dir"/$ext; do
        [ -e "$file" ] || continue

        local item_name
        if [ -d "$file" ]; then
            item_name=$(basename "$file")
            local skill_md="$file/SKILL.md"
            is_generated_file "$skill_md" || continue
            local template="$TEMPLATE_DIR/${item_name}_prompt_template.md"
            if [ ! -f "$template" ] || [ "$(get_template_type "$template")" != "$type" ]; then
                $DRY_RUN || rm -rf "$file"
                $QUIET || echo "  removed stale $type: $item_name"
            fi
        else
            is_generated_file "$file" || continue
            item_name=$(basename "$file" .md)
            local template="$TEMPLATE_DIR/${item_name}_prompt_template.md"
            if [ ! -f "$template" ] || [ "$(get_template_type "$template")" != "$type" ]; then
                $DRY_RUN || rm "$file"
                $QUIET || echo "  removed stale $type: $item_name"
            fi
        fi
    done
}

$QUIET || echo ""
cleanup_stale "$SKILLS_DIR" "*/" "skill"
cleanup_stale "$AGENTS_DIR" "*.md" "agent"
cleanup_stale "$RULES_DIR" "*.md" "rule"

# --- Summary ---
$QUIET || echo ""
$QUIET || echo "Generated: $skill_count skills, $agent_count agents, $rule_count rules"
