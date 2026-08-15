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
#   ZET_SKILLS_LOCAL — local-tier (opencode/Ollama) skill output dir
#   ZET_SKILLS_CODEX — codex-backend skill output dir (unset = feature off, no default)
#
# BACKEND TAGGING (generalizes the tier/local-set pattern):
#   A template can set `backend: claude|opencode|codex` (default: claude — every existing template
#   that never sets it keeps generating ONLY into the full Claude skill set, unchanged).
#   `backend: opencode` is the SAME mechanism `tier: local` already used (a local-model session):
#   role: resolves through the *_local model-roles column, output mirrors into [paths].skills-local.
#   `backend: codex` mirrors into [paths].skills-codex IF that path is configured — Codex's own
#   skill format (name/description frontmatter, $CODEX_HOME/skills/<name>/SKILL.md) has no per-skill
#   model: override (Codex's model is a single global config, not chosen per skill), so no model: line
#   is ever emitted for it. If skills-codex isn't configured, the backend tag is a documentation-only
#   no-op — most Codex usage in this system is `codex exec`/`codex review` one-shot invocations with
#   the prompt content already inlined by the caller, not a loaded skill set, so there is nothing to
#   mirror into by default.
set -e

# --- Concurrency lock ---
# Multiple sessions can invoke `zet generate` at nearly the same moment (e.g. several Claude Code sessions
# sharing this vault). Without serialization, two runs interleave on the same wipe-then-write output dirs —
# one run's wipe can land between another run's write, leaving a near-empty result (observed: skills-local
# dropped from 65 entries to 1 stray "another" dir mid-write). Serialize with an mkdir-based lock (atomic on
# every POSIX filesystem, no external binary needed — `flock` isn't installed by default on macOS): a second
# run WAITS for the first to release rather than racing it.
#
# STRICTLY OWNERSHIP-SCOPED (no steal/steal-race): the release trap is set ONLY after THIS process's own
# mkdir succeeds, so only the actual lock holder can ever remove it — no other waiter can double-unlock or
# steal it. There is deliberately NO "steal a stale lock after N seconds" fallback: an earlier version tried
# that and it was UNSOUND (two waiters could both believe they'd reclaimed the lock and proceed concurrently,
# recreating the exact race this lock exists to prevent). generate normally finishes in seconds, so a hung
# holder is abnormal; if the wait exceeds the timeout, fail LOUDLY with manual-recovery instructions rather
# than silently risk corrupting output by racing another process.
_LOCKDIR="${TMPDIR:-/tmp}/zet-generate.lock"
_LOCK_WAITED=0
_LOCK_TIMEOUT_S=120
while ! mkdir "$_LOCKDIR" 2>/dev/null; do
    _LOCK_WAITED=$((_LOCK_WAITED + 1))
    if [ "$_LOCK_WAITED" -ge "$_LOCK_TIMEOUT_S" ]; then
        echo "ERROR: zet generate lock held >${_LOCK_TIMEOUT_S}s by another run." >&2
        echo "  If that run crashed without cleanup (e.g. kill -9), remove the stale lock manually: rmdir $_LOCKDIR" >&2
        exit 1
    fi
    sleep 1
done
# Reached ONLY by the process whose mkdir just succeeded — safe to bind the release trap here.
trap 'rmdir "$_LOCKDIR" 2>/dev/null || true' EXIT

# --- Config resolution ---
ZET_ROOT="${ZET_ROOT:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/frontmatter.sh"
zet_config_init "$ZET_ROOT"

TEMPLATE_DIR="$(resolve_path "${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}")"
SKILLS_DIR="$(resolve_path "${ZET_SKILLS:-$(zet_config_get "paths" "skills" "$HOME/.claude/skills")}")"
AGENTS_DIR="$(resolve_path "${ZET_AGENTS:-$(zet_config_get "paths" "agents" "$HOME/.claude/agents")}")"
RULES_DIR="$(resolve_path "${ZET_RULES:-$(zet_config_get "paths" "rules" "$HOME/.claude/rules")}")"
# LOCAL-TIER skill output — a dual-tier copy for a local-model session (any OpenClaude/Ollama-backed client).
# Every skill lands here by default, with its role: resolved through the LOCAL model column, UNLESS its
# template opts out with `tier: full-only`. A local-model client points --plugin-dir at this dir so it can run
# the same skills as the full-Claude session. Default location beside the full set; override via
# ZET_SKILLS_LOCAL / [paths].skills-local.
SKILLS_LOCAL_DIR="$(resolve_path "${ZET_SKILLS_LOCAL:-$(zet_config_get "paths" "skills-local" "$HOME/.claude/skills-local")}")"
# CODEX-BACKEND skill output — mirrors `backend: codex` skills into a dedicated dir, ONLY if configured.
# Unlike skills-local (which always has a default), this has NO default: emitting into ~/.codex/skills by
# default would silently start writing into another CLI's real skill directory for every zet project, even
# ones that never asked for Codex output. Empty/unset ⇒ feature is off ⇒ backend: codex is a no-op.
_skills_codex_raw="${ZET_SKILLS_CODEX:-$(zet_config_get "paths" "skills-codex" "")}"
SKILLS_CODEX_DIR=""
[ -n "$_skills_codex_raw" ] && SKILLS_CODEX_DIR="$(resolve_path "$_skills_codex_raw")"
# Agent Skills Open Standard output (interop with Codex, Cursor, Gemini CLI, etc.)
_agents_std_raw="${ZET_AGENTS_STD:-$(zet_config_get "paths" "agents-std" "")}"
AGENTS_STD_DIR=""
[ -n "$_agents_std_raw" ] && AGENTS_STD_DIR="$(resolve_path "$_agents_std_raw")"
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
[ -n "$AGENTS_STD_DIR" ] && ! $QUIET && echo "Interop: $AGENTS_STD_DIR (Agent Skills Open Standard)"
[ -n "$SKILLS_CODEX_DIR" ] && ! $QUIET && echo "Backend: $SKILLS_CODEX_DIR (codex)"
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

resolve_model_role_local() {
    # Resolve a role through the LOCAL column: try {role}_local first, fall back to the base role ONLY IF that
    # base value is itself local. FAIL CLOSED — the invariant is "local tier never emits a cloud model." A base
    # role like cheap_cloud=deepseek/... or execute=sonnet must NOT leak into a local skill on fallback; if no
    # local mapping resolves, emit nothing (the skill's model: line is omitted, so the local session default
    # applies — never a cloud model). A value is "local" if it's a bare Ollama tag or ollama_chat/-prefixed
    # (never a provider-slashed cloud id like deepseek/... or a claude-* name).
    local role="$1" val
    val=$(resolve_model_role "${role}_local" || true)
    if [ -z "$val" ]; then
        local base
        base=$(resolve_model_role "$role" || true)
        case "$base" in
            ollama_chat/*)          val="$base" ;;                      # LiteLLM-form local — keep
            claude-*|*/*)           val="" ;;                           # claude-… or provider/model cloud — DROP
            opus|sonnet|haiku)      val="" ;;                           # bare Claude family alias is CLOUD — DROP
            "" )                    val="" ;;
            *)                      val="$base" ;;                      # bare non-Claude tag (qwen…) = local — keep
        esac
    fi
    echo "$val"
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
# SAFETY ABORT: the local-set wipe below deletes SKILL.md files under SKILLS_LOCAL_DIR. If a misconfig
# (ZET_SKILLS_LOCAL / [paths].skills-local) or symlink drift ever resolved it to the SAME dir as the full
# set, that wipe would destroy the full set before regeneration. Refuse to run rather than risk it. Compare
# PHYSICAL paths when a dir exists (pwd -P resolves symlinks + normalization); for not-yet-created dirs,
# compare the physical PARENT + basename so the guard also covers the equal-but-uncreated case (Codex: a
# --dry run with equal uncreated dirs otherwise slipped past). Runs REGARDLESS of --dry (it's pure comparison).
_canon_path() {
    # Echo a comparable absolute path: physical dir if it exists, else physical(parent)/basename.
    local p="$1"
    if [ -d "$p" ]; then ( cd "$p" 2>/dev/null && pwd -P ); return; fi
    local parent base
    parent=$(dirname "$p"); base=$(basename "$p")
    if [ -d "$parent" ]; then echo "$(cd "$parent" 2>/dev/null && pwd -P)/$base"; else echo "$p"; fi
}
# Guard BOTH the local plugin root AND the actual wipe target (its skills/ subdir) against the full skills
# dir. The wipe deletes SKILL.md under $SKILLS_LOCAL_DIR/skills, so if skills-local were set to the PARENT
# of the full dir (e.g. skills-local=~/.claude, skills=~/.claude/skills), the subdir would BE the full dir
# and the wipe would destroy it — comparing only the roots misses that. Compare the resolved wipe target too.
SKILLS_LOCAL_SKILLS_DIR="$SKILLS_LOCAL_DIR/skills"
_phys_full=$(_canon_path "$SKILLS_DIR")
_phys_local=$(_canon_path "$SKILLS_LOCAL_DIR")
_phys_local_skills=$(_canon_path "$SKILLS_LOCAL_SKILLS_DIR")
if [ -n "$_phys_full" ] && { [ "$_phys_full" = "$_phys_local" ] || [ "$_phys_full" = "$_phys_local_skills" ]; }; then
    echo "ERROR: skills-local (or its skills/ subdir) resolves to the full skills dir ($_phys_full)." >&2
    echo "  Refusing to run — the local-set wipe would delete the full skill set. Fix [paths].skills-local." >&2
    exit 1
fi
ensure_dir "$SKILLS_DIR"
ensure_dir "$SKILLS_LOCAL_DIR"
ensure_dir "$AGENTS_DIR"
ensure_dir "$RULES_DIR"
[ -n "$AGENTS_STD_DIR" ] && ensure_dir "$AGENTS_STD_DIR"
# Codex-backend output is a plain additive copy dir (no wipe-then-write step like skills-local's plugin
# set), so it doesn't need the same-dir safety abort above — worst case of a misconfigured skills-codex
# pointing at the full skills dir is an extra SKILL.md write, not a destructive wipe.
if [ -n "$SKILLS_CODEX_DIR" ]; then
    ensure_dir "$SKILLS_CODEX_DIR"
    # Wipe-then-regenerate, same reasoning as the local-tier set below: a skill retagged codex→claude (or
    # backend: codex removed) still matches type: skill, so cleanup_stale's "no matching template" check
    # would never catch it — only a full wipe before rebuilding guarantees no stale codex-only copy survives.
    if ! $DRY_RUN; then
        find "$SKILLS_CODEX_DIR" -mindepth 1 -maxdepth 2 -name SKILL.md -delete 2>/dev/null || true
        find "$SKILLS_CODEX_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
    fi
fi
# The local set is emitted as a PLUGIN so a local-model client (ccl/openclaude) can load it via --plugin-dir
# (openclaude discovers skills from <pluginroot>/skills/<name>/SKILL.md + a .claude-plugin/plugin.json
# manifest — a bare skills dir is NOT loadable). Local skills live under $SKILLS_LOCAL_SKILLS_DIR (defined +
# guarded against the full dir above); a manifest is written to $SKILLS_LOCAL_DIR/.claude-plugin/plugin.json.
# REGENERATED fresh each run so a skill retagged full→local (or its template deleted) can never leave a stale
# copy that ccl would still surface. Safe: only SKILL.md under the dedicated local plugin's skills/ subdir
# (guarded above against $SKILLS_LOCAL_DIR ever being the full dir).
if ! $DRY_RUN; then
    ensure_dir "$SKILLS_LOCAL_SKILLS_DIR"
    find "$SKILLS_LOCAL_SKILLS_DIR" -mindepth 1 -maxdepth 2 -name SKILL.md -delete 2>/dev/null || true
    find "$SKILLS_LOCAL_SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
    # emit the plugin manifest (idempotent — same content every run)
    ensure_dir "$SKILLS_LOCAL_DIR/.claude-plugin"
    cat > "$SKILLS_LOCAL_DIR/.claude-plugin/plugin.json" <<'PLUGINJSON'
{
  "name": "ccl-local",
  "version": "0.1.0",
  "description": "Local-tier skills (tier: local) for the ccl local-model session — generated by zet, do not edit."
}
PLUGINJSON
fi

# --- Generate ---
skill_count=0
agent_count=0
rule_count=0
interop_count=0
seen_names=""

for file in "$TEMPLATE_DIR"/*_prompt_template.md; do
    [ -f "$file" ] || continue

    filename=$(basename "$file")
    name=$(echo "$filename" | sed 's/_prompt_template\.md$//')
    type=$(get_template_type "$file")

    [ -z "$type" ] && continue

    # Duplicate check — exact whole-token match against the space-joined list.
    # NOT `grep -w`: with -w a hyphen counts as a word boundary, so "understand"
    # falsely matches inside "understand-topic-para" (likewise team/team-retro,
    # write/write-book-content) and the shorter skill is silently skipped.
    case " $seen_names " in
        *" $name "*)
            echo "  ERROR: duplicate name '$name' — skipping" >&2
            continue
            ;;
    esac
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
            domain=$(get_frontmatter_value "$file" "domain")
            skill_tags=$(get_frontmatter_value "$file" "tags")
            # TIER: which sets this skill belongs to. Default "local" — EVERY skill is exposed to a
            # local-model session by default, using the SAME template with its role: resolved through the
            # local model column. A heavy skill (one that fans out many cloud subagents) still appears in the
            # local session rather than "Unknown skill" — if the local
            # model genuinely can't carry it out, that surfaces as the model's own best-effort/limitation
            # response, not a lookup failure. `tier: full-only` is the explicit opt-OUT for a skill that must
            # never even be attempted locally (e.g. needs credentials/hooks only the full session has).
            tier=$(get_frontmatter_value "$file" "tier")
            [ -z "$tier" ] && tier="local"

            # BACKEND: which harness this skill is written for. Default "claude" — every existing
            # template that never sets this field keeps behaving exactly as before (full-Claude-only
            # skill, no codex copy). "opencode" is documentation for the tier:local mechanism above (the
            # thing already covering local-model/Ollama sessions); "codex" additionally mirrors into
            # [paths].skills-codex when configured. Unknown values fall back to "claude" with a warning
            # rather than silently dropping the skill from the full set.
            backend=$(get_frontmatter_value "$file" "backend")
            [ -z "$backend" ] && backend="claude"
            case "$backend" in
                claude|opencode|codex) ;;
                *)
                    echo "  WARNING: $filename — unknown backend '$backend', treating as 'claude'" >&2
                    backend="claude"
                    ;;
            esac

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
                    [ -n "$domain" ] && echo "domain: $domain"
                    [ -n "$skill_tags" ] && echo "tags: $skill_tags"
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

            # Agent Skills Open Standard output (interop with Codex, Cursor, etc.)
            # Same SKILL.md format but written to /.agents/skills/ for cross-tool discovery
            if [ -n "$AGENTS_STD_DIR" ] && ! $DRY_RUN; then
                mkdir -p "$AGENTS_STD_DIR/$name"
                cp "$skill_dir/SKILL.md" "$AGENTS_STD_DIR/$name/SKILL.md"
                interop_count=$((interop_count + 1))
            fi

            # LOCAL-TIER set: only skills marked `tier: local` are ALSO emitted into SKILLS_LOCAL_DIR, with
            # their model: resolved through the LOCAL column (Ollama), so a local-model client running this
            # skill spawns local subagents instead of reaching for Anthropic. Same body, local model header.
            if [ "$tier" = "local" ] && ! $DRY_RUN; then
                # local_model must NEVER inherit the full/cloud $model — that's the leak. Start EMPTY and set
                # it only to a value proven local: from the role's local column (fail-closed) when role is set,
                # or from a directly-set model: only if that model is itself local (bare tag / ollama_chat/).
                # Empty ⇒ the model: line is omitted below ⇒ the local session's own default applies (never cloud).
                local_model=""
                if [ -n "$role" ]; then
                    local_model=$(resolve_model_role_local "$role" || true)
                elif [ -n "$model" ]; then
                    case "$model" in
                        ollama_chat/*)      local_model="$model" ;;
                        claude-*|*/*)       local_model="" ;;      # cloud id — DROP
                        opus|sonnet|haiku)  local_model="" ;;      # bare Claude family alias is CLOUD — DROP
                        *)                  local_model="$model" ;; # bare non-Claude tag = local
                    esac
                fi
                local_skill_dir="$SKILLS_LOCAL_SKILLS_DIR/$name"
                mkdir -p "$local_skill_dir"
                {
                    echo "---"
                    echo "name: $name"
                    echo "description: $desc"
                    echo "user-invocable: true"
                    [ -n "$args" ] && echo "argument-hint: \"$args\""
                    [ -n "$local_model" ] && echo "model: $local_model"
                    [ -n "$ctx" ] && echo "context: $ctx"
                    [ -n "$domain" ] && echo "domain: $domain"
                    [ -n "$skill_tags" ] && echo "tags: $skill_tags"
                    echo "---"
                    echo "<!-- Generated by Zet from $filename (LOCAL tier) — do not edit directly -->"
                    echo "<!-- Regenerate: zet generate -->"
                    echo ""
                    printf 'follow %s\n' "$TEMPLATE_DIR/$filename"
                    if [ -n "$prompt_extra" ]; then
                        printf '%s' "$prompt_extra" | sed 's/\\n/\n/g'
                        echo ""
                    fi
                    echo ""
                    echo "Read the template file first, then execute its instructions completely."
                } > "$local_skill_dir/SKILL.md"
                $QUIET || echo "  skill: $name (+local)"
            fi

            # CODEX-BACKEND set: only skills marked `backend: codex` mirror into SKILLS_CODEX_DIR, and
            # only when that path is actually configured (unset ⇒ feature off, see SKILLS_CODEX_DIR above).
            # No model: line — Codex has no per-skill model override, it's one global model in
            # ~/.codex/config.toml (verified via `codex exec --help`: model is a top-level -c override,
            # never a SKILL.md field), so emitting one here would just be dead frontmatter Codex ignores.
            if [ "$backend" = "codex" ] && [ -n "$SKILLS_CODEX_DIR" ] && ! $DRY_RUN; then
                codex_skill_dir="$SKILLS_CODEX_DIR/$name"
                mkdir -p "$codex_skill_dir"
                {
                    echo "---"
                    echo "name: $name"
                    echo "description: $desc"
                    echo "---"
                    echo "<!-- Generated by Zet from $filename (codex backend) — do not edit directly -->"
                    echo "<!-- Regenerate: zet generate -->"
                    echo ""
                    printf 'follow %s\n' "$TEMPLATE_DIR/$filename"
                    if [ -n "$prompt_extra" ]; then
                        printf '%s' "$prompt_extra" | sed 's/\\n/\n/g'
                        echo ""
                    fi
                    echo ""
                    echo "Read the template file first, then execute its instructions completely."
                } > "$codex_skill_dir/SKILL.md"
                $QUIET || echo "  skill: $name (+codex)"
            fi
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
[ -n "$AGENTS_STD_DIR" ] && cleanup_stale "$AGENTS_STD_DIR" "*/" "skill"
# skills-codex needs no cleanup_stale pass: it's already wiped-then-regenerated per run (above, same
# reasoning as skills-local) so a codex→claude retag can never leave a stale copy behind.

# --- Summary ---
$QUIET || echo ""
if [ -n "$AGENTS_STD_DIR" ]; then
    $QUIET || echo "Generated: $skill_count skills, $agent_count agents, $rule_count rules ($interop_count interop)"
else
    $QUIET || echo "Generated: $skill_count skills, $agent_count agents, $rule_count rules"
fi
