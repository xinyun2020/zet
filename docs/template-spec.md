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
| `backend` | skills | `claude` (default), `opencode`, `codex`, or `pi`. `claude` is the plain full-Claude skill, unaffected by this field — every template written before `backend:` existed keeps behaving exactly as before. `opencode` documents that a skill also targets the `tier: local` mirror above. `codex` additionally mirrors the skill into `[paths].skills-codex` when that path is configured (unset = no-op: Codex is typically driven as a stateless one-shot reviewer via `codex exec`/`codex review`, not a loaded skill set, and has no per-skill model override, so no `model:` line is ever emitted into the codex copy). `pi` is accepted as an explicit consumer annotation, but Pi prompt output is generated for every role-bearing skill so existing templates gain routing without a 57-file retagging pass. |

### Pi prompt output

Pi prompt output is intentionally separate from `SKILL.md`. Pi loads a skill as context, but `pi-prompt-template-model` applies `model:` and `thinking:` only to prompt-template files. Every skill with a `role:` therefore gets an additive prompt file; `backend: pi` may be used as an explicit annotation but is not required.

For a template role `R`, Zet reads the Pi chain from the configured model-roles file in this order:

```text
pi_R, pi_R_fallback_1, pi_R_fallback_2, ...
```

Each model must have a matching `pi_R[_fallback_N]_provider`. Zet emits explicit `provider/model` values in that configured order, so extension-level bare-model provider preferences cannot reorder them. `execute` maps to the existing `implement` Pi role, `audit` maps to `review`, and `orchestrate` maps to `discover`. The role's `{R}_effort` becomes the extension's `thinking:` field.

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

## Hook Manifest (`[hooks.<name>]` in zet.toml)

Hooks are a structurally different unit from skills/agents/rules — the source is an existing gate SCRIPT (bash, already wired into a Claude Code `.claude/settings.json` hook), not a markdown template. A `[hooks.<name>]` table in `zet.toml` names that script and declares which other harnesses, if any, have a generated shim for it. `core/hooks-generator.sh` reads these tables and emits Pi extension `.ts` shims — thin translators that shell out to the SAME script, never a reimplementation of its logic.

Fields:

| Field | Required | Description |
|-------|----------|--------------|
| `source` | always | Path (relative to project root) to the one bash script that is the actual gate logic |
| `claude_event` | always | Documentation only, not read by the generator — which Claude Code hook event this fires on (e.g. `PreToolUse matcher=Edit\|Write`), for a human cross-reference against `.claude/settings.json` |
| `targets` | always | Array of harnesses with a generated shim. Valid today: `["pi"]`, or `[]` for documentation-only |
| `pi_event` | when `pi` in targets | Which Pi `ExtensionAPI` event the shim subscribes to (currently always `tool_call`) |
| `pi_input_shape` | when `pi` in targets | `bash_command` (extract `event.input.command`, pipe to the script's `--why` mode on stdin) or `edit_write_content` (reconstruct the script's `{tool_name, tool_input}` stdin JSON from Pi's edit/write event) |
| `note` | when `targets = []` | Free-text explaining why this hook is not portable yet (e.g. the target harness has no hook API, or the event shape needed doesn't exist) |

`targets = []` is a valid, intentional state — not every hook can or should be ported. It requires a `note` so the gap is documented rather than silently missing.

Example:

```toml
[hooks.danger-scan]
source = "R-utils/scripts/ccs-danger-scan.sh"
claude_event = "PreToolUse matcher=Bash"
targets = ["pi"]
pi_event = "tool_call"
pi_input_shape = "bash_command"

[hooks.require-codex-on-script-change]
source = "R-utils/dotfiles/.claude/hooks/require-codex-on-script-change.sh"
claude_event = "Stop"
targets = []
note = "Pi has no event exposing a transcript file path in a shape this script's parser understands — porting would require a second, independent parser, which duplicates gate logic."
```

Output dir is configured via `[paths].pi-extensions` (or `ZET_PI_EXTENSIONS`), same no-destructive-default pattern as `[paths].skills-codex` — unset means the feature is off, and a hook targeting `pi` with no output dir configured is a loud `WARNING`, not a silent no-op (a missing safety shim is a safety-relevant gap, unlike a missing skill mirror).

## Validation Rules

`zet validate` enforces:
- `type:` field must be present and one of: skill, agent, rule
- Skills must have `description:` (non-empty string)
- Rules must have either `paths:` or `global: true`
- Filename must match `*_prompt_template.md` pattern
- No duplicate names across all templates
