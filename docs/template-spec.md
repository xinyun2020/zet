---
description: Full frontmatter reference — required fields, optional fields, naming conventions, type-specific behavior
---

# Template Specification v0.1

- parent:
  - [Lifecycle](lifecycle.md)

Templates are the fundamental unit in Zet. A template is a markdown file with YAML frontmatter that defines a capability — a skill, agent, or rule.

## Filename Convention

```
{kebab-name}_prompt_template.md
```

The name is derived from the filename: strip `_prompt_template.md` suffix. This name becomes the skill/agent/rule identifier.

## Frontmatter

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | enum: `skill`, `agent`, `rule` | What this template generates |

### Required for Skills

| Field | Type | Description |
|-------|------|-------------|
| `description` | string | One-line description (shown in help, skill listings) |

### Optional Fields

| Field | Applies to | Description |
|-------|-----------|-------------|
| `model` | all | Override model for this template (e.g. `haiku`, `sonnet`, `opus`) |
| `role` | all | Alias resolved via `[model-roles]` in `zet.toml`. Takes priority over `model` |
| `paths` | rules | Glob patterns — rule only loads when editing matching files |
| `global` | rules | `true` = rule loads in every session (default: false) |
| `args` | skills | Hint for CLI arguments (shown in help) |
| `context` | skills | Context loading strategy |
| `prompt` | skills | Additional prompt text appended after the follow directive |
| `tier` | skills | `local` (default) or `full-only`. `local` also mirrors the skill into `[paths].skills-local` with `role:` resolved through the local (Ollama) model column, for a local-model client (e.g. `ccl`) loading it via `--plugin-dir`. `full-only` opts a skill out of that mirror entirely (e.g. it needs credentials/hooks only the full session has) |
| `backend` | skills | `claude` (default), `opencode`, or `codex`. `claude` is the plain full-Claude skill, unaffected by this field — every template written before `backend:` existed keeps behaving exactly as before. `opencode` documents that a skill also targets the `tier: local` mirror above. `codex` additionally mirrors the skill into `[paths].skills-codex` when that path is configured (unset = no-op: Codex is typically driven as a stateless one-shot reviewer via `codex exec`/`codex review`, not a loaded skill set, and has no per-skill model override, so no `model:` line is ever emitted into the codex copy) |
| `scope` | skills | `vault` (default) or `universal`. `vault` is the plain full-Claude skill, excluded from the minimal profile — every template written before `scope:` existed keeps behaving exactly as before. `universal` (repo-agnostic, safe in any project) ALSO mirrors the skill into `[paths].skills-minimal` when that path is configured (unset = no-op), using the SAME `model:` as the full skill (a discovery/path filter, not a model-tier swap). A minimal-profile launch (e.g. the `ccm` alias, `--plugin-dir` pointed at `skills-minimal`) discovers only `scope: universal` skills instead of the full set — for a session outside the vault/personal-system context |

### Pass-through Fields

Any frontmatter field not in the above list is passed through unchanged to the generated output. This allows tool-specific fields without framework changes.

## Body

The markdown body after frontmatter is the template content. For skills, this is the instruction set. For agents, this is the agent definition. For rules, this is the constraint text.

## Examples

### Skill

```yaml
---
type: skill
description: Run daily workflow phases
role: execute
args: "[phase-number]"
---
# Daily Workflow

Follow these steps...
```

### Agent

```yaml
---
type: agent
description: Code review specialist
model: sonnet
---
# Code Reviewer

You are a code review agent...
```

### Rule

```yaml
---
type: rule
paths:
  - "src/**/*.ts"
  - "src/**/*.tsx"
---
# TypeScript Conventions

When editing TypeScript files...
```

## Validation Rules

`zet validate` enforces:
- `type:` field must be present and one of: skill, agent, rule
- Skills must have `description:` (non-empty string)
- Rules must have either `paths:` or `global: true`
- Filename must match `*_prompt_template.md` pattern
- No duplicate names across all templates
