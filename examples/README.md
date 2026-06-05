# Examples

Real templates demonstrating Zet conventions. Copy any of these to your `templates/` directory and run `zet generate`.

## Templates

- `commit-message_prompt_template.md` — skill: generates conventional commit messages from staged changes
- `go-style_prompt_template.md` — rule: enforces Go idioms when editing `.go` files
- `code-reviewer_prompt_template.md` — agent: reviews code for quality, security, and maintainability

## Workflow

```bash
# 1. Copy a template to your harness
cp examples/commit-message_prompt_template.md templates/

# 2. Validate structure
zet validate

# 3. Generate deployed skill
zet generate

# 4. Use it in Claude Code
# /commit-message (now available as a slash command)

# 5. Check harness health
zet doctor
zet scan
```

## Structure

Each template is a markdown file with YAML frontmatter:

```yaml
---
type: skill|agent|rule    # what gets generated
description: ...          # one-line summary (required)
---

# Instructions

(prompt content here)
```

See `docs/template-spec.md` for the full specification.
