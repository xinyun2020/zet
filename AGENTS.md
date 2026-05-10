# Zet

The framework for natural language as code. Zet treats prompt templates, skills, hooks, and rules with the same engineering rigor as application code — validation, testing, dead code detection, and health checks.

## Quick Reference

- Run tests: `bin/zet test`
- Validate templates: `bin/zet validate`
- Check health: `bin/zet doctor`
- Coverage: `bin/zet coverage`
- Generate from templates: `bin/zet generate`

## Code Conventions

- Shell scripts only (bash + python3 standard lib). Zero external dependencies
- All core modules in `core/`. CLI dispatcher in `bin/zet`
- Tests in `tests/test-*.sh` — source `core/test-runner.sh` for assert helpers
- Config: `zet.toml` (section-aware TOML, read by `core/config.sh`)
- Templates: `*_prompt_template.md` with YAML frontmatter (`type:`, `description:`, optional `model:`/`role:`)

## Branching

- `main` — releases only (tagged)
- `dev` — active development (PRs merge here)
- `feat/*` — feature branches (PR to dev)

## Testing

Every new feature needs a test. Run `bin/zet test` before committing. Target: all assertions green, coverage >80%.

## Architecture

```
bin/zet          → CLI dispatcher (routes subcommands)
core/config.sh   → TOML reader (zet_config_init, zet_config_get, zet_config_section)
core/generator.sh → template → deployed config (skills, agents, rules)
core/scanner.sh   → dead code detection
core/coverage.sh  → harness health metrics
core/test-runner.sh → assert helpers + test isolation (zet_test_setup/teardown)
hooks/           → built-in hook library (pre-push, post-edit, check-datetime)
templates/       → example templates
tests/           → self-tests (test-generator, test-config, test-hooks)
```
