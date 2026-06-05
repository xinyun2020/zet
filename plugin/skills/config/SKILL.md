---
name: config
description: Audit and manage AI tool configuration (Claude Code, Codex, and future tools)
---

# Config — multi-tool harness configuration management

## When to use
When the user says "config", "audit config", "check hooks", or when config drift is detected.

## Method

Check the session context for which tools are managed (detected from `~/.claude/` and `~/.codex/` existence). Audit each one found.

### Claude Code (`~/.claude/`)

settings.json audit:
1. Read `~/.claude/settings.json`
2. Check allow-list entries: does each `Skill(name)` correspond to an actual skill?
3. Check hook entries: does each hook file exist on disk?
4. Flag ghost entries (reference non-existent skills/hooks)

mcp.yaml audit:
1. Read `~/.claude/mcp.yaml`
2. Check for duplicates between mcp.yaml and settings.json `enabledPlugins`
3. Flag unused MCP servers (defined but never called in templates)

hooks audit:
1. List all hook files in `~/.claude/hooks/`
2. Cross-reference with settings.json hook entries
3. Flag: hooks on disk but not wired, hooks wired but file missing (ghost hooks)

### Codex (`~/.codex/`)

config.toml audit:
1. Read `~/.codex/config.toml`
2. Check model provider is configured and base_url is valid
3. Check project trust levels — any projects that no longer exist on disk?
4. Flag if memories/ or skills/ are empty (setup incomplete)

AGENTS.md audit:
1. Check if AGENTS.md exists at expected locations (project roots, home directory)
2. Compare instruction consistency between CLAUDE.md and AGENTS.md where both exist
3. Flag projects with CLAUDE.md but no AGENTS.md (or vice versa)

### Cross-tool consistency
1. Compare: do both tools have the same project-level instructions?
2. Flag: MCP servers configured in one tool but not the other (where applicable)
3. Check: are credentials for shared services (API keys, tokens) consistent?

## Report format
```
Config health:
Claude Code:
- settings.json: {N} allow-list entries, {N} ghost entries
- mcp.yaml: {N} servers, {N} duplicates with plugins
- hooks: {N} on disk, {N} wired, {N} ghost, {N} unwired

Codex:
- config.toml: {status}
- memories: {N} entries
- skills: {N} entries
- AGENTS.md: {found/missing} at {paths}

Cross-tool:
- {N} projects with both tools, {N} with instruction gaps
```
