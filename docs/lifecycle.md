---
description: The six stages every template passes through — create, validate, generate, test, scan, improve
---

# Template Lifecycle

- parent:
  - [Primitives](primitives.md)

Every template follows this path. Each stage has a Zet command.

## Create

```bash
zet new skill my-feature
zet new agent code-reviewer
zet new rule go-style
```

Scaffolds a template with correct frontmatter structure and naming convention.

## Validate

```bash
zet validate
```

Checks all templates for:
- Required frontmatter fields present and typed correctly
- Filename matches naming convention (`*_prompt_template.md`)
- No duplicate names across templates
- Referenced files exist (relative paths in template body)

Catches typos and structural errors before they silently break generation.

## Generate

```bash
zet generate
```

Builds all templates into deployed config:
- Skills → `skills/{name}/SKILL.md`
- Agents → `agents/{name}.md`
- Rules → `rules/{name}.md`

Resolves: model roles, shared frontmatter, path references, dynamic includes.

## Test

```bash
zet test
```

Runs test suites against the generated output:
- Assertions on generated file structure
- Contract checks (required sections present)
- Regression detection (output changed unexpectedly)

Auto-discovers `tests/test-*.sh` files. Each test is a bash script with assertion helpers.

## Scan

```bash
zet scan
```

Detects drift and dead code in the deployed config:
- Ghost skills (output exists, source template deleted)
- Orphaned hooks (settings reference a file that doesn't exist)
- Stale paths (references to moved/renamed files)
- Duplicate outputs (two templates generating the same target)

## Doctor

```bash
zet doctor
```

Health check across the entire harness:
- Broken symlinks
- Missing descriptions (skills without context for auto-invocation)
- Secret detection (API keys, tokens in templates)
- Role assignment gaps (templates without owner)
- Stale config paths

## Improve

The human step. Based on scan/doctor output:
- Archive unused templates (60+ days no invocation)
- Fix broken references
- Remove dead hooks
- Update stale paths

`zet coverage` shows overall health metrics to guide improvement.

## Full Check

```bash
zet healthcheck
```

Runs all stages in sequence: validate → test → scan → doctor. Single command for CI or pre-push verification.
