# Zet Optimize — Harness Optimization

`zet doctor` finds broken things. `zet optimize` finds inefficiencies and over-exposure in config that already works — the stuff that quietly costs you tokens, leaks privilege, or never fires.

## Quick Start

```bash
# Human-readable report
zet optimize

# Structured JSON for automation
zet optimize --json

# Exit code only (0 = clean, 1 = opportunities found) — use as a CI gate
zet optimize --quiet

# Show per-skill detail even when nothing is flagged
zet optimize --verbose
```

## What It Checks

### 1. Permission surface

What tools each skill can reach, classified by risk:

- high — can modify state or run arbitrary code (Bash, Write, Edit, Agent)
- medium — can read sensitive data or talk to the outside (WebFetch, WebSearch, mcp__*)
- low — read-only and local (Read, Grep, Glob, Skill)

A read-only skill that pulls in Bash is over-privileged. Tighten it.

### 2. Redundancy

Overlapping instruction blocks across skills. When two skills repeat the same 3+ lines, that content wants to be a shared rule, not copy-pasted into each skill.

### 3. Token cost

A per-skill estimate of context cost. Sort by size to find the skills eating the most of your window.

### 4. Invocation reliability

The metric most config tools miss: will a skill's description actually trigger it?

Research across 2026 (Vercel, dev.to) found skills frequently never fire — not because they are low quality, but because the agent never selects them. A skill that never fires is dead weight, and worse, it adds noise that can suppress the skills that should fire.

`zet optimize` scores each skill's description deterministically:

- likely — the description carries a trigger phrase (`use when…`, `when the user says…`, `triggers on…`) and is long enough to be specific
- unlikely — too short, has no trigger phrase (reads as passive documentation), or is near-identical to another skill's description (the agent can't disambiguate, so invocation becomes a coin flip)

```bash
zet optimize --json | python3 -c "import json,sys; print([s['skill'] for s in json.load(sys.stdin)['invocation_reliability'] if s['reliability']=='unlikely'])"
```

Fix an `unlikely` skill by adding an explicit trigger and concrete specifics to its description, or — when two skills overlap — by merging or retiring one.

## JSON Shape

```json
{
  "total_skills": 12,
  "permissions": [{"skill": "deploy", "tools": ["Bash", "Read"], "risk": "high"}],
  "token_costs": [{"skill": "deploy", "estimated_tokens": 430}],
  "redundancy": [{"skill_a": "a", "skill_b": "b", "shared_lines": 4, "sample": ["..."]}],
  "invocation_reliability": [
    {"skill": "standup", "reliability": "likely"},
    {"skill": "helper", "reliability": "unlikely"},
    {"skill": "review-a", "reliability": "unlikely", "ambiguous_with": ["review-b"]}
  ]
}
```

## Design Principles

- Deterministic-first: every check is bash/awk/grep/python-stdlib. Zero LLM cost, zero external deps, runs in CI
- Optimize, don't break: this finds inefficiency in working config — it never edits anything. You decide what to act on
- The description is the API: a skill's description is the only thing the agent sees when deciding whether to invoke it. Treat it like a function signature, not a comment
