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
