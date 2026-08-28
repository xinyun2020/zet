#!/bin/bash
# Zet Agent Detect — identify which coding-agent CLI a live tmux pane is running
# Usage: source this file, then call zet_agent_detect <tmux-target>
# Dependencies: bash, tmux
#
# This is the CONSUME-SIDE twin of generator.sh's `backend:` frontmatter tag (which is
# PRODUCE-SIDE — which harness a skill is written FOR). This module answers a different
# question: given a LIVE tmux pane, which agent CLI is actually running in it RIGHT NOW.
#
# Extracted from R-utils/scripts/ccs-approve-loop.sh (obsidian-git-sync) so agent identity
# detection is ONE versioned, testable module instead of duplicated logic per consuming script.
# Approval-gating, permission-dialog extraction, and danger-scanning stay in the CONSUMING
# script (e.g. ccs-approve-loop.sh) — those are policy decisions specific to that use case, not
# a concern this module owns. This module answers exactly one question: "which agent is this
# pane running?" — nothing about whether to trust it, approve it, or act on it.
#
# Supported agents today:
#   claude    — comm is "claude" or "claude.exe"
#   opencode  — comm is "opencode" or "opencode.exe"
#   pi        — comm is bare "node" (earendil-works/pi-coding-agent has no distinct process
#               name — it's a node script, same as several unrelated launcher shells) AND the
#               pane TITLE matches Pi's own launch convention ("π - <dirname>"). A manually- or
#               coincidentally-titled unrelated node process would also match; that's the
#               accepted tradeoff of title-anchored detection when comm alone gives no signal.
#
# Example:
#   source core/agent-detect.sh
#   agent="$(zet_agent_detect "session:1.1")"   # prints "claude"/"opencode"/"pi", or nothing
#   case "$agent" in
#     claude)   ... ;;
#     opencode) ... ;;
#     pi)       ... ;;
#     "")       echo "not a recognized agent pane" ;;
#   esac

# current pane_current_command for $1 — the primary identity signal for most agents.
zet_agent_pane_comm() {
    tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# current pane TITLE for $1 — some agents share an ambiguous comm (bare "node") with unrelated
# launcher shells and can only be told apart by title.
zet_agent_pane_title() {
    tmux display-message -p -t "$1" '#{pane_title}' 2>/dev/null
}

# ===== AGENT REGISTRY ================================================================
# One entry per supported agent: "name:detect_fn". Adding a new agent means adding one line
# here plus its own detect function — callers never grow a new "if comm = ..." branch.
_ZET_AGENTS="claude:_zet_detect_claude
opencode:_zet_detect_opencode
pi:_zet_detect_pi"

_zet_detect_claude() {
    local comm; comm="$(zet_agent_pane_comm "$1")"
    [ "$comm" = "claude" ] || [ "$comm" = "claude.exe" ]
}

_zet_detect_opencode() {
    local comm; comm="$(zet_agent_pane_comm "$1")"
    [ "$comm" = "opencode" ] || [ "$comm" = "opencode.exe" ]
}

_zet_detect_pi() {
    local comm; comm="$(zet_agent_pane_comm "$1")"
    [ "$comm" = "node" ] || return 1
    local title; title="$(zet_agent_pane_title "$1")"
    printf '%s' "$title" | grep -qE '^[[:space:]]*π[[:space:]]*-'
}

# Which registered agent (if any) is pane $1 running? Prints the agent name on the first
# match, or nothing + failure if none match. Order matters only in that the first matching
# entry wins — today's three entries are mutually exclusive by construction (comm-anchored
# for claude/opencode, comm+title-anchored for pi), so order has no practical effect.
zet_agent_detect() {
    local target="$1" name detect_fn
    while IFS=: read -r name detect_fn; do
        [ -n "$name" ] || continue
        if "$detect_fn" "$target"; then
            printf '%s' "$name"
            return 0
        fi
    done <<< "$_ZET_AGENTS"
    return 1
}
