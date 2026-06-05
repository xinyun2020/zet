---
name: improve
description: Improve templates and config by processing friction logs and recurring patterns
---

# Improve — system-level template and config improvement

## When to use
When the user says "improve", "system-improve", or when friction patterns are detected.

## Method

1. Scan the last 14 daily files for `friction:` entries mentioning skills or templates (cap at 14 files to avoid context bloat)
2. Group by skill/template name
3. For each friction cluster:
   - Read the template
   - Identify the root cause (missing instruction, wrong assumption, unclear wording)
   - Propose a targeted fix (minimal diff, preserve existing behavior)
4. Apply fixes, run `zet validate` after each

## Quality gate
- Every template change must pass `zet validate`
- Changes must be minimal — fix the friction, don't redesign
- If a friction pattern suggests a structural problem (wrong skill boundaries, missing skill), flag it rather than patching
