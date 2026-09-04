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
#   ZET_SKILLS_CODEX — Codex skill output dir (unset = feature off, no default)
#   ZET_PI_PROMPTS — Pi prompt-template output dir (default: ~/.pi/agent/prompts)
#   ZET_GENERATE_JOBS — max parallel skill render jobs (default: CPU count, minimum 1)
#   ZET_GENERATE_CACHE_DIR — run-level cache dir (default: ~/.cache/zet/generate)
#   ZET_GENERATE_FORCE — set to 1 to bypass the run-level cache
#
# BACKEND TAGGING (generalizes the tier/local-set pattern):
#   A template can set `backend: claude|opencode|codex|pi` (default: claude — every existing template
#   that never sets it keeps generating ONLY into the full Claude skill set, unchanged).
#   `backend: opencode` is the SAME mechanism `tier: local` already used (a local-model session):
#   role: resolves through the *_local model-roles column, output mirrors into [paths].skills-local.
#   [paths].skills-codex mirrors the generated skill set into Codex's native skill directory. The
#   path is the opt-in: once configured, every generated skill is projected to Codex unless the
#   template says `codex: false`. This keeps Zet as the SSOT for a multi-harness setup instead of
#   requiring per-template `backend: codex` tags. Codex's skill format
#   (name/description frontmatter, $CODEX_HOME/skills/<name>/SKILL.md) has no per-skill model:
#   override (Codex's model is a single global config, not chosen per skill), so no model: line is
#   ever emitted for it.
#   Every role-bearing skill additionally emits a prompt-template file into ZET_PI_PROMPTS. Unlike
#   SKILL.md context, this file is discovered by pi-prompt-template-model. The generated prompt
#   template deliberately carries NO model:/thinking: frontmatter (2026-09-05): the orchestrator
#   inherits the session model (the cheap always-on default), and per-agent escalation happens at
#   fan-out time inside the template body via ~/.claude/model-roles.conf (pi_review/pi_worker/
#   pi_review_quick) and settings.json subagents.agentOverrides. The normal Claude skill output
#   remains enabled.
#   `backend: pi` remains accepted as an explicit annotation, but is not required for this additive
#   output; a role is the signal that model/thinking routing can be generated safely.
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
# steal it. A pure TIME-based "steal after N seconds" fallback was tried once and was UNSOUND (two waiters
# could both decide to steal a legitimately slow-but-alive holder's lock and proceed concurrently,
# recreating the exact race this lock exists to prevent — a time threshold cannot distinguish "hung" from
# "just slow"). PID-liveness reaping below is a different, sound mechanism: a dead PID is unambiguous
# (never "just slow" — a process that no longer exists cannot still be writing), so any single waiter may
# rmdir a lock whose holder is confirmed dead. That rmdir doesn't grant ownership by itself — it only frees
# the mkdir slot, which every waiter (old and new) then still has to win atomically like any fresh
# acquisition, so no double-holder is possible even if several waiters reap at once.
# Observed 2026-08-27: a hook/tool timeout shorter than generate's real runtime SIGKILLs generator.sh
# mid-run, skipping the EXIT trap and orphaning the lock for every subsequent run until someone notices
# and removes it by hand — this reaps that case automatically instead.
_LOCKDIR="${TMPDIR:-/tmp}/zet-generate.lock"
_LOCK_PIDFILE="$_LOCKDIR/pid"
_LOCK_WAITED=0
_LOCK_TIMEOUT_S=120
while ! mkdir "$_LOCKDIR" 2>/dev/null; do
    _holder_pid="$(cat "$_LOCK_PIDFILE" 2>/dev/null)"
    if [ -n "$_holder_pid" ] && ! kill -0 "$_holder_pid" 2>/dev/null; then
        echo "zet generate: reaping stale lock (holder pid $_holder_pid is dead)" >&2
        rm -f "$_LOCK_PIDFILE" 2>/dev/null
        rmdir "$_LOCKDIR" 2>/dev/null || true
        continue
    fi
    _LOCK_WAITED=$((_LOCK_WAITED + 1))
    if [ "$_LOCK_WAITED" -ge "$_LOCK_TIMEOUT_S" ]; then
        echo "ERROR: zet generate lock held >${_LOCK_TIMEOUT_S}s by another run (pid ${_holder_pid:-unknown})." >&2
        echo "  If that run crashed without cleanup (e.g. kill -9), remove the stale lock manually: rmdir $_LOCKDIR" >&2
        exit 1
    fi
    sleep 1
done
# Reached ONLY by the process whose mkdir just succeeded — safe to bind the release trap here.
echo "$$" > "$_LOCK_PIDFILE"
trap 'rm -f "$_LOCK_PIDFILE" 2>/dev/null; rmdir "$_LOCKDIR" 2>/dev/null || true' EXIT

# --- Config resolution ---
ZET_ROOT="${ZET_ROOT:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/frontmatter.sh"
zet_config_init "$ZET_ROOT"

TEMPLATE_DIR="$(resolve_path "${ZET_TEMPLATES:-$(zet_config_get "paths" "templates" "$ZET_ROOT/templates")}")"
SKILLS_DIR="$(resolve_path "${ZET_SKILLS:-$(zet_config_get "paths" "skills" "$HOME/.claude/skills")}")"
AGENTS_DIR="$(resolve_path "${ZET_AGENTS:-$(zet_config_get "paths" "agents" "$HOME/.claude/agents")}")"
# PI agent output — mirrors generated agents into a dedicated dir with role: resolved through the
# pi_* model column (provider/id form), ONLY if configured. Unlike agents (which defaults to
# ~/.claude/agents), this has NO default: a shared symlink (~/.pi/agent/agents -> ~/.claude/agents)
# makes ONE frontmatter `model:` serve two runtimes with disjoint model vocabularies, and Claude
# Code aliases (haiku/sonnet/opus) do not resolve in Pi's registry (2026-09-03 hunt failure:
# "Unknown subagent model 'haiku'"). Empty/unset means feature is off; Claude Code keeps its alias
# form, Pi gets its own projected copies. Point [paths].agents-pi at the repo dir that the
# ~/.pi/agent/agents symlink targets, matching the pi-extensions pattern.
_agents_pi_raw="${ZET_AGENTS_PI:-$(zet_config_get "paths" "agents-pi" "")}"
AGENTS_PI_DIR=""
[ -n "$_agents_pi_raw" ] && AGENTS_PI_DIR="$(resolve_path "$_agents_pi_raw")"
RULES_DIR="$(resolve_path "${ZET_RULES:-$(zet_config_get "paths" "rules" "$HOME/.claude/rules")}")"
# LOCAL-TIER skill output — a dual-tier copy for a local-model session (any OpenClaude/Ollama-backed client).
# Every skill lands here by default, with its role: resolved through the LOCAL model column, UNLESS its
# template opts out with `tier: full-only`. A local-model client points --plugin-dir at this dir so it can run
# the same skills as the full-Claude session. Default location beside the full set; override via
# ZET_SKILLS_LOCAL / [paths].skills-local.
SKILLS_LOCAL_DIR="$(resolve_path "${ZET_SKILLS_LOCAL:-$(zet_config_get "paths" "skills-local" "$HOME/.claude/skills-local")}")"
# CODEX skill output — mirrors generated skills into a dedicated dir, ONLY if configured. Unlike
# skills-local (which always has a default), this has NO default: emitting into ~/.codex/skills by
# default would silently start writing into another CLI's real skill directory for every zet project,
# even ones that never asked for Codex output. Empty/unset ⇒ feature is off.
_skills_codex_raw="${ZET_SKILLS_CODEX:-$(zet_config_get "paths" "skills-codex" "")}"
SKILLS_CODEX_DIR=""
[ -n "$_skills_codex_raw" ] && SKILLS_CODEX_DIR="$(resolve_path "$_skills_codex_raw")"
# Agent Skills Open Standard output (interop with Codex, Cursor, Gemini CLI, etc.)
_agents_std_raw="${ZET_AGENTS_STD:-$(zet_config_get "paths" "agents-std" "")}"
AGENTS_STD_DIR=""
[ -n "$_agents_std_raw" ] && AGENTS_STD_DIR="$(resolve_path "$_agents_std_raw")"
PI_PROMPTS_DIR="$(resolve_path "${ZET_PI_PROMPTS:-$(zet_config_get "paths" "pi-prompts" "$HOME/.pi/agent/prompts")}")"
# Pi MODEL-VISIBLE skills dir (~/.pi/agent/skills/*/SKILL.md). Unlike prompts/ (user-side slash
# commands), this directory is injected into the session as available skills, so a skill mentioned
# mid-conversation is discoverable by the model. We emit a thin loader stub per role-bearing skill
# pointing at the generated prompt template — the template stays the single source of truth.
PI_SKILLS_DIR="$(resolve_path "${ZET_PI_SKILLS:-$(zet_config_get "paths" "pi-skills" "$HOME/.pi/agent/skills")}")"
# Model roles: read from [model-roles] section in zet.toml (preferred),
# fall back to standalone file for backwards compatibility
MODEL_ROLES_FILE="$(resolve_path "${ZET_MODEL_ROLES:-$(zet_config_get "project" "model-roles-file" "$ZET_ROOT/model-roles.conf")}")"
GENERATE_CACHE_ROOT="${ZET_GENERATE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zet/generate}"
GENERATE_CACHE_KEY="$(printf '%s' "$ZET_ROOT" | shasum | awk '{print $1}')"
GENERATE_CACHE_FILE="$GENERATE_CACHE_ROOT/$GENERATE_CACHE_KEY.sha"
GENERATE_MANIFEST_FILE="$GENERATE_CACHE_ROOT/$GENERATE_CACHE_KEY.manifest"
GENERATE_FORCE="${ZET_GENERATE_FORCE:-0}"
GENERATE_JOBS="${ZET_GENERATE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
case "$GENERATE_JOBS" in
    ''|*[!0-9]*) GENERATE_JOBS=4 ;;
esac
[ "$GENERATE_JOBS" -lt 1 ] && GENERATE_JOBS=1

DRY_RUN=false
QUIET=false
RULE_ROOTS=()
RULE_SOURCES=()
RENDER_PIDS=()
RENDER_LABELS=()
RENDER_WAIT_INDEX=0
RENDER_FAILED=0
LIVE_PI_PROMPT_NAMES=""
LIVE_PI_SKILL_STUB_NAMES=""
LIVE_LOCAL_SKILL_NAMES=""
LIVE_CODEX_SKILL_NAMES=""
LIVE_HANDWRITTEN_MIRROR_NAMES=""
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
! $QUIET && echo "Parallelism: $GENERATE_JOBS skill render job(s)"
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

write_if_changed() {
    local target="$1" dir base tmp
    dir=$(dirname "$target")
    base=$(basename "$target")
    mkdir -p "$dir"
    tmp="$dir/.$base.tmp.$$.$RANDOM"
    cat > "$tmp"
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$target"
    fi
}

copy_file_if_changed() {
    local source="$1" target="$2" dir base tmp
    [ -f "$target" ] && cmp -s "$source" "$target" && return 0
    dir=$(dirname "$target")
    base=$(basename "$target")
    mkdir -p "$dir"
    tmp="$dir/.$base.tmp.$$.$RANDOM"
    cp "$source" "$tmp"
    mv "$tmp" "$target"
}

name_list_has() {
    local list="$1" name="$2"
    case " $list " in
        *" $name "*) return 0 ;;
        *) return 1 ;;
    esac
}

hash_file_or_missing() {
    local file="$1"
    if [ -f "$file" ]; then
        shasum "$file"
    else
        printf 'MISSING  %s\n' "$file"
    fi
}

hash_file_value() {
    shasum "$1" | awk '{print $1}'
}

batch_hash_files() {
    local files=() file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        files+=("$file")
        if [ "${#files[@]}" -ge 200 ]; then
            shasum "${files[@]}"
            files=()
        fi
    done
    [ "${#files[@]}" -gt 0 ] && shasum "${files[@]}"
    return 0
}

compute_generation_fingerprint() {
    {
        printf 'zet-generate-core-v4\n'
        printf 'root=%s\n' "$ZET_ROOT"
        printf 'templates=%s\n' "$TEMPLATE_DIR"
        printf 'skills=%s\n' "$SKILLS_DIR"
        printf 'skills-local=%s\n' "$SKILLS_LOCAL_DIR"
        printf 'skills-codex=%s\n' "$SKILLS_CODEX_DIR"
        printf 'agents=%s\n' "$AGENTS_DIR"
        printf 'agents-pi=%s\n' "$AGENTS_PI_DIR"
        printf 'rules=%s\n' "$RULES_DIR"
        printf 'agents-std=%s\n' "$AGENTS_STD_DIR"
        printf 'pi-prompts=%s\n' "$PI_PROMPTS_DIR"
        printf 'pi-skills=%s\n' "$PI_SKILLS_DIR"

        hash_file_or_missing "$SCRIPT_DIR/generator.sh"
        hash_file_or_missing "$SCRIPT_DIR/frontmatter.sh"
        hash_file_or_missing "$SCRIPT_DIR/config.sh"
        hash_file_or_missing "$ZET_CONFIG_FILE"
        hash_file_or_missing "$MODEL_ROLES_FILE"

        find "$TEMPLATE_DIR" -maxdepth 1 -type f -name '*_prompt_template.md' -print 2>/dev/null | sort | batch_hash_files

        # Hand-written skills are source inputs for the interop/Codex mirrors. Generated skills are
        # outputs, so exclude them from the source fingerprint to avoid self-invalidating the cache.
        if [ -n "$AGENTS_STD_DIR$SKILLS_CODEX_DIR" ] && [ -d "$SKILLS_DIR" ]; then
            find "$SKILLS_DIR" -mindepth 2 -maxdepth 2 -type f -name SKILL.md -print 2>/dev/null | sort | while IFS= read -r skill_file; do
                grep -q "Generated by Zet" "$skill_file" 2>/dev/null && continue
                printf '%s\n' "$skill_file"
            done | batch_hash_files
        fi
    } | shasum | awk '{print $1}'
}

generation_cache_hit() {
    local fingerprint="$1" cached_fingerprint line expected path count=0
    local paths=() expected_lines="" expected_sorted actual_sorted
    [ "$GENERATE_FORCE" = "1" ] && return 1
    [ -f "$GENERATE_CACHE_FILE" ] && [ -f "$GENERATE_MANIFEST_FILE" ] || return 1
    cached_fingerprint=$(sed -n '1p' "$GENERATE_CACHE_FILE")
    [ "$cached_fingerprint" = "$fingerprint" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            *$'\t'*)
                expected="${line%%$'\t'*}"
                path="${line#*$'\t'}"
                ;;
            *) return 1 ;;
        esac
        [ -f "$path" ] || return 1
        paths+=("$path")
        expected_lines="${expected_lines}${expected}  ${path}"$'\n'
        count=$((count + 1))
    done < "$GENERATE_MANIFEST_FILE"

    [ "$count" -gt 0 ] || return 1
    expected_sorted=$(printf '%s' "$expected_lines" | sort)
    actual_sorted=$(shasum "${paths[@]}" | sort)
    [ "$actual_sorted" = "$expected_sorted" ]
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
        # model-roles.conf is an INI-like file; use the first exact key and never let
        # duplicate entries turn a scalar into a newline-delimited YAML value.
        awk -F= -v key="$role" '!/^#/ && $1 == key { print substr($0, index($0, "=") + 1); exit }' "$MODEL_ROLES_FILE"
        return 0
    fi
    return 1
}

# Return an ordered Pi model chain for a template role. Pi's prompt extension accepts a comma-separated
# model list, but its bare-ID provider preference is fixed upstream. Pairing each configured model with its
# provider here keeps the user's provider/fallback order in model-roles.conf authoritative.
resolve_pi_model_chain() {
    local role="$1" pi_role="$1" i model provider entry chain=""
    case "$role" in
        execute)     pi_role="implement" ;;
        audit)       pi_role="audit" ;;
        orchestrate) pi_role="discover" ;;
    esac
    for i in 0 1 2 3 4 5 6 7 8 9; do
        if [ "$i" -eq 0 ]; then
            model=$(resolve_model_role "pi_${pi_role}" || true)
            provider=$(resolve_model_role "pi_${pi_role}_provider" || true)
        else
            model=$(resolve_model_role "pi_${pi_role}_fallback_${i}" || true)
            provider=$(resolve_model_role "pi_${pi_role}_fallback_${i}_provider" || true)
        fi
        [ -z "$model" ] && continue
        if [ -z "$provider" ]; then
            echo "  WARNING: missing provider for Pi role '$pi_role' candidate '$model'" >&2
            continue
        fi
        entry="$provider/$model"
        chain="${chain:+$chain, }$entry"
    done
    [ -n "$chain" ] && printf '%s\n' "$chain"
}

# Emit a complete prompt-template consumed by pi-prompt-template-model. This is deliberately separate
# Pi has no Claude Code agent registry — 'general-purpose' and 'Explore' die at
# subagent launch ("Unknown agent", 2026-09-03 hunt failure) when a translating
# agent forwards them. Model ALIASES are already resolved via the role frontmatter
# above; this covers agent-vocabulary in template BODY text. Role semantics:
# general-purpose (full-tool executor) -> worker, Explore (read-only search) -> scout.
# Blanket by design — a per-lens refinement (e.g. reviewer for review lenses) belongs
# in the SOURCE template as an explicit pi variant, not pattern-matched here.
translate_pi_agent_vocab() {
    # [[:<:]] not \b -- BSD sed (macOS) silently ignores \b and matches nothing
    sed -e 's/subagent_type[=:][ "'"'"']*[[:<:]]general-purpose[[:>:]]/subagent_type: worker/g' \
        -e 's/subagent_type[=:][ "'"'"']*[[:<:]]Explore[[:>:]]/subagent_type: scout/g' \
        -e 's/[[:<:]]general-purpose agent[[:>:]]/worker agent/g' \
        -e 's/[[:<:]]general-purpose agents[[:>:]]/worker agents/g' \
        -e 's/[[:<:]]general-purpose[[:>:]]/worker/g' \
        -e 's/[[:<:]]Explore agent[[:>:]]/scout agent/g' \
        -e 's/[[:<:]]Explore agents[[:>:]]/scout agents/g' \
        -e 's/[[:<:]]Explore[[:>:]]/scout/g'
}

# Pi prompt template (differs from generated SKILL.md): the prompt template carries NO model:/thinking: frontmatter — the
# orchestrator inherits the session model (cheap always-on default), and per-agent escalation
# happens at fan-out time inside the template body via ~/.claude/model-roles.conf
# (pi_review/pi_worker/pi_review_quick) + settings.json subagents.agentOverrides.
generate_pi_prompt() {
    local source="$1" target="$2" name="$3" desc="$4"
    $DRY_RUN && { $QUIET || echo "  [dry] $target"; return; }
    {
        echo "---"
        echo "description: $(yaml_quote "$desc")"
        echo "---"
        echo "<!-- Generated by Zet from $(basename "$source") for Pi — do not edit directly -->"
        echo "<!-- Regenerate: zet generate -->"
        echo ""
        # body text passes through translate_pi_agent_vocab -- Claude agent vocabulary in
        # template bodies must not reach Pi's registry (see function comment)
        awk 'BEGIN { fm=0; done=0 } NR==1 && $0=="---" { fm=1; next } fm && $0=="---" { fm=0; done=1; next } !fm && done { print }' "$source" | translate_pi_agent_vocab
    } | write_if_changed "$target"
}

# Thin model-visible stub: ~/.pi/agent/skills/<name>/SKILL.md pointing at the generated prompt
# template. The prompt template owns all logic; the stub only makes the skill discoverable when the
# user mentions /<name> mid-conversation (prompt files are only expanded when typed as a slash
# command at editor position 0). Carries the "Generated by Zet" marker so stale cleanup + manifest
# treat it as zet-owned; hand-written skills in the same dir (no marker) are never touched.
generate_pi_skill_stub() {
    local source="$1" name="$2" desc="$3" args="$4"
    local target="$PI_SKILLS_DIR/$name/SKILL.md"
    $DRY_RUN && { $QUIET || echo "  [dry] $target"; return; }
    {
        echo "---"
        echo "name: $name"
        echo "description: $(yaml_quote "$desc")"
        [ -n "$args" ] && echo "argument-hint: $(yaml_quote "$args")"
        echo "user-invocable: true"
        echo "---"
        echo "<!-- Generated by Zet from $(basename "$source") for Pi skill stub — do not edit directly -->"
        echo "<!-- Regenerate: zet generate -->"
        echo ""
        echo "This is a loader stub. The single source of truth is the generated Pi prompt template."
        echo ""
        echo "1. Read \`$PI_PROMPTS_DIR/$name.md\`"
        echo "2. Execute its instructions completely — it owns ticket resolution, phases, gates, and output format"
        echo ""
        echo "If the user supplied arguments, pass them through. If not, follow the template's CONTEXT INFERENCE section."
    } | write_if_changed "$target"
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

wait_render_at() {
    local index="$1" pid label
    pid="${RENDER_PIDS[$index]}"
    label="${RENDER_LABELS[$index]}"
    if ! wait "$pid"; then
        echo "  ERROR: render job failed: $label" >&2
        RENDER_FAILED=1
    fi
}

enqueue_render_job() {
    local label="$1"
    shift
    if $DRY_RUN || [ "$GENERATE_JOBS" -eq 1 ]; then
        "$@" || RENDER_FAILED=1
        return 0
    fi

    "$@" &
    RENDER_PIDS+=("$!")
    RENDER_LABELS+=("$label")

    while [ $((${#RENDER_PIDS[@]} - RENDER_WAIT_INDEX)) -ge "$GENERATE_JOBS" ]; do
        wait_render_at "$RENDER_WAIT_INDEX"
        RENDER_WAIT_INDEX=$((RENDER_WAIT_INDEX + 1))
    done
}

wait_render_jobs() {
    while [ "$RENDER_WAIT_INDEX" -lt "${#RENDER_PIDS[@]}" ]; do
        wait_render_at "$RENDER_WAIT_INDEX"
        RENDER_WAIT_INDEX=$((RENDER_WAIT_INDEX + 1))
    done
    [ "$RENDER_FAILED" -eq 0 ]
}

write_skill_wrapper() {
    local target="$1" filename="$2" name="$3" desc="$4" model="$5" args="$6" ctx="$7" domain="$8" skill_tags="$9"
    local marker="${10}" prompt_extra="${11}" user_invocable="${12}"

    $DRY_RUN && { $QUIET || echo "  [dry] $target"; return; }
    {
        echo "---"
        echo "name: $name"
        echo "description: $(yaml_quote "$desc")"
        [ "$user_invocable" = "true" ] && echo "user-invocable: true"
        [ -n "$args" ] && echo "argument-hint: \"$args\""
        [ -n "$model" ] && echo "model: $model"
        [ -n "$ctx" ] && echo "context: $ctx"
        [ -n "$domain" ] && echo "domain: $domain"
        [ -n "$skill_tags" ] && echo "tags: $skill_tags"
        echo "---"
        echo "<!-- Generated by Zet from $filename$marker — do not edit directly -->"
        echo "<!-- Regenerate: zet generate -->"
        echo ""
        printf 'follow %s\n' "$TEMPLATE_DIR/$filename"
        if [ -n "$prompt_extra" ]; then
            printf '%s' "$prompt_extra" | sed 's/\\n/\n/g'
            echo ""
        fi
        echo ""
        echo "Read the template file first, then execute its instructions completely."
    } | write_if_changed "$target"
}

render_skill_outputs() {
    local file="$1" filename="$2" name="$3" desc="$4" model="$5" role="$6" args="$7" ctx="$8" domain="$9"
    local skill_tags="${10}" tier="${11}" codex_enabled="${12}" prompt_extra="${13}" pi_role="${14}"
    local skill_dir local_model local_skill_dir codex_skill_dir
    [ -n "$pi_role" ] || pi_role="$role"

    skill_dir="$SKILLS_DIR/$name"
    write_skill_wrapper "$skill_dir/SKILL.md" "$filename" "$name" "$desc" "$model" "$args" "$ctx" "$domain" "$skill_tags" "" "$prompt_extra" "true"
    if $DRY_RUN; then
        [ -n "$AGENTS_STD_DIR" ] && { $QUIET || echo "  [dry] $AGENTS_STD_DIR/$name/SKILL.md"; }
        [ -n "$role" ] && generate_pi_prompt "$file" "$PI_PROMPTS_DIR/$name.md" "$name" "$desc"
        [ -n "$role" ] && generate_pi_skill_stub "$file" "$name" "$desc" "$args"
        [ "$tier" = "local" ] && write_skill_wrapper "$SKILLS_LOCAL_SKILLS_DIR/$name/SKILL.md" "$filename" "$name" "$desc" "" "$args" "$ctx" "$domain" "$skill_tags" " (LOCAL tier)" "$prompt_extra" "true"
        [ "$codex_enabled" != "false" ] && [ -n "$SKILLS_CODEX_DIR" ] && write_skill_wrapper "$SKILLS_CODEX_DIR/$name/SKILL.md" "$filename" "$name" "$desc" "" "" "" "" "" " (Codex projection)" "$prompt_extra" "false"
        return 0
    fi

    # Same SKILL.md format, same model metadata; the open standard target is a portability mirror.
    if [ -n "$AGENTS_STD_DIR" ]; then
        mkdir -p "$AGENTS_STD_DIR/$name"
        copy_file_if_changed "$skill_dir/SKILL.md" "$AGENTS_STD_DIR/$name/SKILL.md"
    fi

    if [ -n "$role" ]; then
        generate_pi_prompt "$file" "$PI_PROMPTS_DIR/$name.md" "$name" "$desc"
        generate_pi_skill_stub "$file" "$name" "$desc" "$args"
    fi

    if [ "$tier" = "local" ]; then
        # The local tier must never inherit a cloud model; resolve through the local column only.
        local_model=""
        if [ -n "$role" ]; then
            local_model=$(resolve_model_role_local "$role" || true)
        elif [ -n "$model" ]; then
            case "$model" in
                ollama_chat/*)      local_model="$model" ;;
                claude-*|*/*)       local_model="" ;;
                opus|sonnet|haiku)  local_model="" ;;
                *)                  local_model="$model" ;;
            esac
        fi
        local_skill_dir="$SKILLS_LOCAL_SKILLS_DIR/$name"
        write_skill_wrapper "$local_skill_dir/SKILL.md" "$filename" "$name" "$desc" "$local_model" "$args" "$ctx" "$domain" "$skill_tags" " (LOCAL tier)" "$prompt_extra" "true"
    fi

    if [ "$codex_enabled" != "false" ] && [ -n "$SKILLS_CODEX_DIR" ]; then
        codex_skill_dir="$SKILLS_CODEX_DIR/$name"
        write_skill_wrapper "$codex_skill_dir/SKILL.md" "$filename" "$name" "$desc" "" "" "" "" "" " (Codex projection)" "$prompt_extra" "false"
    fi
}

generate_file() {
    local source="$1" target="$2" type="$3" variant="${4:-}"
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
                        if [ "$variant" = "pi" ]; then
                            # Pi has no Claude alias registry — resolve through the pi_* column
                            # (provider/id form, first candidate of the ordered chain).
                            resolved=$(resolve_pi_model_chain "$role_val" | cut -d',' -f1 | tr -d ' ')
                        else
                            resolved=$(resolve_model_role "$role_val" || true)
                        fi
                        if [ -n "$resolved" ]; then
                            echo "model: $resolved"
                        elif [ "$variant" = "pi" ]; then
                            echo "  WARNING: no Pi model for role '$role_val' in $source_name" >&2
                        else
                            echo "  WARNING: unknown role '$role_val' in $source_name" >&2
                        fi
                        ;;
                    *) echo "$line" ;;
                esac
            else
                if $frontmatter_done && ! $marker_written; then
                    if [ "$variant" = "pi" ]; then
                        echo "<!-- Generated by Zet from $source_name for Pi — do not edit directly -->"
                    else
                        echo "<!-- Generated by Zet from $source_name — do not edit directly -->"
                    fi
                    echo "<!-- Regenerate: zet generate -->"
                    marker_written=true
                fi
                echo "$line" | translate_pi_agent_vocab
            fi
        done < "$source"

        if $frontmatter_done && ! $marker_written; then
            if [ "$variant" = "pi" ]; then
                echo "<!-- Generated by Zet from $source_name for Pi — do not edit directly -->"
            else
                echo "<!-- Generated by Zet from $source_name — do not edit directly -->"
            fi
            echo "<!-- Regenerate: zet generate -->"
        fi
    } | write_if_changed "$target"
}

rule_roots() {
    local source="$1"
    awk '
        BEGIN { in_fm = 0; in_paths = 0 }
        NR == 1 && $0 == "---" { in_fm = 1; next }
        in_fm && $0 == "---" { exit }
        !in_fm { next }
        /^paths:[[:space:]]*$/ { in_paths = 1; next }
        in_paths && /^[a-zA-Z][a-zA-Z0-9_-]*:/ { in_paths = 0 }
        in_paths && /^[[:space:]]*-[[:space:]]*"?[A-Za-z0-9_.-]+\// {
            value = $0
            sub(/^[[:space:]]*-[[:space:]]*"?/, "", value)
            sub(/"?[[:space:]]*$/, "", value)
            sub(/\*\*.*/, "", value)
            sub(/\*$/, "", value)
            sub(/\/$/, "", value)
            if (value != "" && value !~ /[*?[]/) print value
        }
    ' "$source" | sort -u
}

render_agents_md() {
    local root="$1" sources="$2" target
    target="$ZET_ROOT/$root/AGENTS.md"
    [ -d "$ZET_ROOT/$root" ] || return 0
    $DRY_RUN && { $QUIET || echo "  [dry] $target"; return; }
    {
        echo "<!-- Generated by Zet from path-scoped rules — do not edit directly -->"
        echo "<!-- Regenerate: zet generate -->"
        echo "# Agent Instructions"
        echo ""
        echo "These instructions are compiled from the path-scoped rule templates that apply to this directory."
        local source
        for source in $sources; do
            echo ""
            awk '
                BEGIN { in_fm = 0 }
                NR == 1 && $0 == "---" { in_fm = 1; next }
                in_fm && $0 == "---" { in_fm = 0; next }
                in_fm { next }
                /^<!-- (Generated by Zet|Regenerate:)/ { next }
                { print }
            ' "$source"
        done
    } | write_if_changed "$target"
}

add_rule_source() {
    local root="$1" source="$2" index
    for index in "${!RULE_ROOTS[@]}"; do
        if [ "${RULE_ROOTS[$index]}" = "$root" ]; then
            RULE_SOURCES[$index]="${RULE_SOURCES[$index]} $source"
            return
        fi
    done
    RULE_ROOTS+=("$root")
    RULE_SOURCES+=("$source")
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

CURRENT_GENERATION_FINGERPRINT=$(compute_generation_fingerprint)
if ! $DRY_RUN && generation_cache_hit "$CURRENT_GENERATION_FINGERPRINT"; then
    $QUIET || echo "Generated: skipped (cache hit)"
    exit 0
fi

ensure_dir "$SKILLS_DIR"
ensure_dir "$SKILLS_LOCAL_DIR"
ensure_dir "$AGENTS_DIR"
ensure_dir "$RULES_DIR"
[ -n "$AGENTS_STD_DIR" ] && ensure_dir "$AGENTS_STD_DIR"
ensure_dir "$PI_PROMPTS_DIR"
ensure_dir "$PI_SKILLS_DIR"
[ -n "$SKILLS_CODEX_DIR" ] && ensure_dir "$SKILLS_CODEX_DIR"
# The local set is emitted as a PLUGIN so a local-model client (ccl/openclaude) can load it via --plugin-dir
# (openclaude discovers skills from <pluginroot>/skills/<name>/SKILL.md + a .claude-plugin/plugin.json
# manifest — a bare skills dir is NOT loadable). Local skills live under $SKILLS_LOCAL_SKILLS_DIR (defined +
# guarded against the full dir above); a manifest is written to $SKILLS_LOCAL_DIR/.claude-plugin/plugin.json.
# Generated files are written only when their content changes; stale generated copies are removed after the
# live template set is known, so a skill retagged full-only (or deleted) cannot remain visible locally.
if ! $DRY_RUN; then
    ensure_dir "$SKILLS_LOCAL_SKILLS_DIR"
    # emit the plugin manifest (idempotent — same content every run)
    write_if_changed "$SKILLS_LOCAL_DIR/.claude-plugin/plugin.json" <<'PLUGINJSON'
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
            pi_role=$(get_frontmatter_value "$file" "pi-role")
            # TIER: which sets this skill belongs to. Default "local" — EVERY skill is exposed to a
            # local-model session by default, using the SAME template with its role: resolved through the
            # local model column. A heavy skill (one that fans out many cloud subagents) still appears in the
            # local session rather than "Unknown skill" — if the local
            # model genuinely can't carry it out, that surfaces as the model's own best-effort/limitation
            # response, not a lookup failure. `tier: full-only` is the explicit opt-OUT for a skill that must
            # never even be attempted locally (e.g. needs credentials/hooks only the full session has).
            tier=$(get_frontmatter_value "$file" "tier")
            [ -z "$tier" ] && tier="local"

            # BACKEND: documentation about intended consumers. It does NOT control default projection:
            # Zet is the source of truth and configured output paths decide which harness artifacts exist.
            # "opencode" documents the tier:local mechanism above; "codex" remains accepted for older
            # templates but is no longer required when [paths].skills-codex is configured; "pi" is
            # documentation-only (see the file-header note above — Pi has no filesystem skill drop-in to
            # mirror into). Unknown values fall back to "claude" with a warning rather than silently
            # dropping the skill from the full set.
            backend=$(get_frontmatter_value "$file" "backend")
            [ -z "$backend" ] && backend="claude"
            case "$backend" in
                claude|opencode|codex|pi) ;;
                *)
                    echo "  WARNING: $filename — unknown backend '$backend', treating as 'claude'" >&2
                    backend="claude"
                    ;;
            esac
            codex_enabled=$(get_frontmatter_value "$file" "codex")
            [ -z "$codex_enabled" ] && codex_enabled="true"

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

            $QUIET || echo "  skill: $name"
            skill_count=$((skill_count + 1))

            # PI PROMPT: every role-bearing skill gets a real prompt-template file. Pi discovers this
            # directory as prompts; putting model metadata only in SKILL.md would be a false integration
            # because the pi-prompt-template-model extension does not execute skill frontmatter.
            # PI SKILL STUB: prompts are user-side only (expanded when typed at editor position 0), so a
            # /name mentioned mid-message never reaches the model as a template. The stub in Pi's
            # model-visible skills dir closes that gap — see generate_pi_skill_stub.
            if [ -n "$role" ]; then
                LIVE_PI_PROMPT_NAMES="$LIVE_PI_PROMPT_NAMES $name"
                LIVE_PI_SKILL_STUB_NAMES="$LIVE_PI_SKILL_STUB_NAMES $name"
                $QUIET || echo "  skill: $name (+pi prompt)"
            fi

            # Agent Skills Open Standard output (interop with Codex, Cursor, etc.)
            # Same SKILL.md format but written to /.agents/skills/ for cross-tool discovery
            if [ -n "$AGENTS_STD_DIR" ]; then
                interop_count=$((interop_count + 1))
            fi

            # LOCAL-TIER set: only skills marked `tier: local` are ALSO emitted into SKILLS_LOCAL_DIR, with
            # their model: resolved through the LOCAL column (Ollama), so a local-model client running this
            # skill spawns local subagents instead of reaching for Anthropic. Same body, local model header.
            if [ "$tier" = "local" ]; then
                LIVE_LOCAL_SKILL_NAMES="$LIVE_LOCAL_SKILL_NAMES $name"
                $QUIET || echo "  skill: $name (+local)"
            fi

            # CODEX set: when SKILLS_CODEX_DIR is configured, every generated skill mirrors into Codex
            # unless the template explicitly opts out with `codex: false`.
            # No model: line — Codex has no per-skill model override, it's one global model in
            # ~/.codex/config.toml (verified via `codex exec --help`: model is a top-level -c override,
            # never a SKILL.md field), so emitting one here would just be dead frontmatter Codex ignores.
            if [ "$codex_enabled" != "false" ] && [ -n "$SKILLS_CODEX_DIR" ]; then
                LIVE_CODEX_SKILL_NAMES="$LIVE_CODEX_SKILL_NAMES $name"
                $QUIET || echo "  skill: $name (+codex)"
            fi
            enqueue_render_job "skill:$name" render_skill_outputs "$file" "$filename" "$name" "$desc" "$model" "$role" "$args" "$ctx" "$domain" "$skill_tags" "$tier" "$codex_enabled" "$prompt_extra" "$pi_role"
            ;;

        agent)
            generate_file "$file" "$AGENTS_DIR/$name.md" "agent"
            if [ -n "$AGENTS_PI_DIR" ]; then
                generate_file "$file" "$AGENTS_PI_DIR/$name.md" "agent" pi
                LIVE_PI_AGENT_NAMES="$LIVE_PI_AGENT_NAMES $name"
            fi
            $QUIET || echo "  agent: $name"
            agent_count=$((agent_count + 1))
            ;;

        rule)
            generate_file "$file" "$RULES_DIR/$name.md" "rule"
            while IFS= read -r root; do
                add_rule_source "$root" "$file"
            done < <(rule_roots "$file")
            $QUIET || echo "  rule: $name"
            rule_count=$((rule_count + 1))
            ;;

        *)
            echo "  WARNING: unknown type '$type' in $filename — skipping" >&2
            ;;
    esac
done

if ! wait_render_jobs; then
    echo "ERROR: one or more skill render jobs failed" >&2
    exit 1
fi

for index in "${!RULE_ROOTS[@]}"; do
    render_agents_md "${RULE_ROOTS[$index]}" "${RULE_SOURCES[$index]}"
done

# --- Cleanup stale generated files ---
is_generated_file() {
    # Only clean up files Zet itself created — never touch legacy or hand-written files
    local file="$1"
    grep -q "Generated by Zet" "$file" 2>/dev/null
}

emit_manifest_entry() {
    local file="$1"
    [ -f "$file" ] || return 0
    printf '%s\t%s\n' "$(hash_file_value "$file")" "$file"
}

collect_skill_manifest_entries() {
    local dir="$1" live_handwritten_names="$2" skill_dir item_name skill_md
    [ -d "$dir" ] || return 0
    for skill_dir in "$dir"/*/; do
        [ -d "$skill_dir" ] || continue
        item_name=$(basename "$skill_dir")
        skill_md="$skill_dir/SKILL.md"
        [ -f "$skill_md" ] || continue
        if is_generated_file "$skill_md" || name_list_has "$live_handwritten_names" "$item_name"; then
            emit_manifest_entry "$skill_md"
        fi
    done
}

collect_marked_file_manifest_entries() {
    local dir="$1" glob="$2" marker="$3" file
    [ -d "$dir" ] || return 0
    for file in "$dir"/$glob; do
        [ -f "$file" ] || continue
        grep -q "$marker" "$file" 2>/dev/null || continue
        emit_manifest_entry "$file"
    done
}

collect_generation_manifest() {
    local index agents_md
    collect_skill_manifest_entries "$SKILLS_DIR" ""
    collect_skill_manifest_entries "$SKILLS_LOCAL_SKILLS_DIR" ""
    [ -n "$AGENTS_STD_DIR" ] && collect_skill_manifest_entries "$AGENTS_STD_DIR" "$LIVE_HANDWRITTEN_MIRROR_NAMES"
    [ -n "$SKILLS_CODEX_DIR" ] && collect_skill_manifest_entries "$SKILLS_CODEX_DIR" "$LIVE_HANDWRITTEN_MIRROR_NAMES"
    collect_marked_file_manifest_entries "$AGENTS_DIR" "*.md" "Generated by Zet"
    collect_marked_file_manifest_entries "$RULES_DIR" "*.md" "Generated by Zet"
    collect_marked_file_manifest_entries "$PI_PROMPTS_DIR" "*.md" "Generated by Zet from .* for Pi"
    collect_marked_file_manifest_entries "$PI_SKILLS_DIR" "*/SKILL.md" "Generated by Zet from .* for Pi skill stub"
    for index in "${!RULE_ROOTS[@]}"; do
        agents_md="$ZET_ROOT/${RULE_ROOTS[$index]}/AGENTS.md"
        grep -q "Generated by Zet from path-scoped rules" "$agents_md" 2>/dev/null || continue
        emit_manifest_entry "$agents_md"
    done
    emit_manifest_entry "$SKILLS_LOCAL_DIR/.claude-plugin/plugin.json"
}

save_generation_cache() {
    local fp_tmp manifest_tmp
    $DRY_RUN && return 0
    if ! mkdir -p "$GENERATE_CACHE_ROOT"; then
        $QUIET || echo "  WARNING: could not write generate cache dir: $GENERATE_CACHE_ROOT" >&2
        return 0
    fi

    fp_tmp="$GENERATE_CACHE_FILE.tmp.$$"
    manifest_tmp="$GENERATE_MANIFEST_FILE.tmp.$$"
    if ! printf '%s\n' "$CURRENT_GENERATION_FINGERPRINT" > "$fp_tmp"; then
        rm -f "$fp_tmp" "$manifest_tmp"
        $QUIET || echo "  WARNING: could not write generate cache fingerprint" >&2
        return 0
    fi
    if ! collect_generation_manifest | sort > "$manifest_tmp"; then
        rm -f "$fp_tmp" "$manifest_tmp"
        $QUIET || echo "  WARNING: could not write generate cache manifest" >&2
        return 0
    fi
    mv "$fp_tmp" "$GENERATE_CACHE_FILE"
    mv "$manifest_tmp" "$GENERATE_MANIFEST_FILE"
}

copy_codex_skill_md() {
    # Codex has a single global model in ~/.codex/config.toml. Strip per-skill model overrides when
    # mirroring hand-written Claude skills so Codex output has the same contract as generated Codex
    # projections.
    local source="$1" target="$2"
    awk '
        NR == 1 && $0 == "---" { in_fm = 1; print; next }
        in_fm && $0 == "---" { in_fm = 0; print; next }
        in_fm && /^model:[[:space:]]*/ { next }
        { print }
    ' "$source" | write_if_changed "$target"
}

# --- Mirror hand-written skills into interop dirs ---
# Some skills are authored directly as SKILL.md in $SKILLS_DIR with no matching
# *_prompt_template.md (they predate zet or were written by hand for a one-off wrapper —
# e.g. confluence, jira, slack-reader). The template loop above never sees these, so they
# were previously invisible to AGENTS_STD_DIR/SKILLS_CODEX_DIR — any consumer of the interop
# dir (Pi, Codex, Cursor, ...) silently saw only the templated subset. Mirror any skill dir
# that has valid name+description frontmatter and no corresponding template.
if [ -n "$AGENTS_STD_DIR$SKILLS_CODEX_DIR" ] && ! $DRY_RUN && [ -d "$SKILLS_DIR" ]; then
    for skill_dir in "$SKILLS_DIR"/*/; do
        [ -d "$skill_dir" ] || continue
        hw_name=$(basename "$skill_dir")
        hw_skill_md="$skill_dir/SKILL.md"
        [ -f "$hw_skill_md" ] || continue
        [ -f "$TEMPLATE_DIR/${hw_name}_prompt_template.md" ] && continue
        is_generated_file "$hw_skill_md" && continue

        hw_desc=$(get_frontmatter_value "$hw_skill_md" "description")
        if [ -z "$hw_desc" ]; then
            $QUIET || echo "  WARNING: $hw_name/SKILL.md missing description — skipping interop mirror" >&2
            continue
        fi

        LIVE_HANDWRITTEN_MIRROR_NAMES="$LIVE_HANDWRITTEN_MIRROR_NAMES $hw_name"
        if [ -n "$AGENTS_STD_DIR" ]; then
            mkdir -p "$AGENTS_STD_DIR/$hw_name"
            copy_file_if_changed "$hw_skill_md" "$AGENTS_STD_DIR/$hw_name/SKILL.md"
            $QUIET || echo "  skill: $hw_name (+interop, hand-written)"
            interop_count=$((interop_count + 1))
        fi
        if [ -n "$SKILLS_CODEX_DIR" ]; then
            mkdir -p "$SKILLS_CODEX_DIR/$hw_name"
            copy_codex_skill_md "$hw_skill_md" "$SKILLS_CODEX_DIR/$hw_name/SKILL.md"
            $QUIET || echo "  skill: $hw_name (+codex, hand-written)"
        fi
    done
fi

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

cleanup_stale_named_skill_dirs() {
    local dir="$1" live_names="$2" label="$3" skill_dir item_name skill_md
    [ -d "$dir" ] || return 0
    for skill_dir in "$dir"/*/; do
        [ -d "$skill_dir" ] || continue
        item_name=$(basename "$skill_dir")
        skill_md="$skill_dir/SKILL.md"
        [ -f "$skill_md" ] || continue
        is_generated_file "$skill_md" || continue
        if ! name_list_has "$live_names" "$item_name"; then
            $DRY_RUN || rm -rf "$skill_dir"
            $QUIET || echo "  removed stale $label: $item_name"
        fi
    done
}

cleanup_stale_named_files() {
    local dir="$1" live_names="$2" label="$3" marker="$4" file item_name
    [ -d "$dir" ] || return 0
    for file in "$dir"/*.md; do
        [ -f "$file" ] || continue
        grep -q "$marker" "$file" 2>/dev/null || continue
        item_name=$(basename "$file" .md)
        if ! name_list_has "$live_names" "$item_name"; then
            $DRY_RUN || rm "$file"
            $QUIET || echo "  removed stale $label: $item_name"
        fi
    done
}

$QUIET || echo ""
cleanup_stale "$SKILLS_DIR" "*/" "skill"
cleanup_stale "$AGENTS_DIR" "*.md" "agent"
[ -n "$AGENTS_PI_DIR" ] && cleanup_stale_named_files "$AGENTS_PI_DIR" "$LIVE_PI_AGENT_NAMES" "pi agent" 'Generated by Zet from .* for Pi'
cleanup_stale "$RULES_DIR" "*.md" "rule"
[ -n "$AGENTS_STD_DIR" ] && cleanup_stale "$AGENTS_STD_DIR" "*/" "skill"
cleanup_stale_named_skill_dirs "$SKILLS_LOCAL_SKILLS_DIR" "$LIVE_LOCAL_SKILL_NAMES" "local skill"
[ -n "$SKILLS_CODEX_DIR" ] && cleanup_stale_named_skill_dirs "$SKILLS_CODEX_DIR" "$LIVE_CODEX_SKILL_NAMES" "codex skill"
cleanup_stale_named_files "$PI_PROMPTS_DIR" "$LIVE_PI_PROMPT_NAMES" "Pi prompt" 'Generated by Zet from .* for Pi'
cleanup_stale_named_skill_dirs "$PI_SKILLS_DIR" "$LIVE_PI_SKILL_STUB_NAMES" "Pi skill stub"

save_generation_cache

# --- Summary ---
$QUIET || echo ""
if [ -n "$AGENTS_STD_DIR" ]; then
    $QUIET || echo "Generated: $skill_count skills, $agent_count agents, $rule_count rules ($interop_count interop)"
else
    $QUIET || echo "Generated: $skill_count skills, $agent_count agents, $rule_count rules"
fi
