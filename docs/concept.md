---
description: Why AI config needs engineering rigor — the category-defining argument for harness engineering
---

# The Harness is the Variable

Your AI agent is only as good as the configuration it runs on. Models improve every quarter — the harness rots every day.

## The Problem

At 10+ skills, your AI config directory becomes a codebase. But unlike application code, it has:
- No linter (typo in frontmatter = silent failure)
- No tests (rename a file = broken references nobody catches)
- No dead code detection (deleted template = ghost skill stays deployed)
- No health checks (API key in a template = leaked on push)

The model isn't the variable anymore. The harness is.

## The Evidence

- LangChain's Terminal Bench: moved from rank 30 to rank 5 by changing only the harness, not the model
- Claude Code: 40% of its codebase IS the harness. $2.5B ARR from execution environment, not model quality
- MOP Paradox: frontier models have the HIGHEST meltdown rates because they pursue ambitious strategies — more capable model needs more guardrails, not fewer

## What Zet Does

Four primitives that give your AI config the same engineering rigor as application code:

- Template — the fundamental unit (skill, agent, or rule as markdown + frontmatter)
- Hook — intercepts events, enforces constraints mechanically
- Generator — transforms templates into deployed config (the build step)
- Scanner — detects drift, dead code, violations (the lint step)

Lifecycle: `create → validate → generate → test → scan → improve`

## Who This is For

Anyone with 10+ AI skills/agents/rules who has:
- Renamed a file and broken references silently
- Deleted a template but the deployed skill stayed
- Found a secret that shouldn't be in a template
- Lost track of what's alive vs dead in their config

## The Category

Harness Engineering — treating your AI configuration as a first-class engineering artifact that needs validation, testing, scanning, and lifecycle management. Not a new idea — it's what application code has had for 30 years. Now your prompts need it too.
