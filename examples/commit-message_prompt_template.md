---
type: skill
description: Generate a conventional commit message from staged changes. Use when committing code.
args: "[--scope <module>]"
---

# Commit Message

Read the staged diff and generate a commit message following conventional format.

## Format

```
prefix(scope): description
```

Prefixes: feat, fix, test, refactor, chore, docs, perf, style, ci, build.
Scope is optional — use the module or area affected.
Description: lowercase, imperative, no period.

## Process

1. Run `git diff --cached` to see staged changes
2. Analyze what changed and why (not what files changed, but what behavior changed)
3. Choose the right prefix based on the nature of the change
4. Write a concise description (under 72 chars) that answers "what does this do?"
5. If the change is complex, add a body with bullet points explaining the reasoning

## Rules

- One logical change per commit — if the diff does two unrelated things, suggest splitting
- Focus on the "why" not the "what" — the diff shows what changed, the message explains why
- Never include ticket IDs in commit messages (those go in PR titles)
