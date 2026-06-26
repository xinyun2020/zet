# Zet Eval — Skill Quality Measurement

Evals verify that your skills produce correct output. Three layers, cheapest first:

- Layer 1: Deterministic assertions (regex, contains, line counts) — free, instant
- Layer 2: LLM judge (semantic correctness, binary pass/fail) — cheap, async
- Layer 3: Human calibration (manual review queue) — expensive, quarterly

## Quick Start

```bash
# Run all evals (Layer 1 only by default)
zet eval

# Run evals for one skill
zet eval commit-message

# JSON output for automation
zet eval --json

# Score real skill output (continuous eval mode)
zet eval my-skill --output /tmp/skill-output.txt --json
```

## Writing Scenarios

Create `evals/{skill-name}/scenario-{name}.md`:

```yaml
---
description: what this scenario tests
layer: 1
assertions:
  - type: contains
    value: "expected string"
  - type: not_contains
    value: "should not appear"
  - type: regex
    value: "^feat\\(.*\\):"
---
(test input below frontmatter)
```

## Assertion Types

| Type | What it checks |
|------|---------------|
| `contains` | Output includes exact string |
| `not_contains` | Output does NOT include string |
| `regex` | Output matches extended regex |
| `not_regex` | Output does NOT match regex |
| `exit_code` | Process exit code matches |
| `file_exists` | File was created at path |
| `json_valid` | Output is parseable JSON |
| `line_count_min` | At least N lines |
| `line_count_max` | At most N lines |

## Continuous Eval (Private Eval Loop)

Score real skill output against golden scenarios:

```bash
# 1. Capture skill output
skill-output > /tmp/output.txt

# 2. Score against assertions
zet eval my-skill --output /tmp/output.txt --json > result.json

# 3. Track pass rate over time (your metrics system)
pass_rate=$(jq '.passed / .total * 100' result.json)
```

## CI Mode (Regression Detection)

```bash
# Fails if pass_rate drops below previous run
zet eval --ci

# Stores baseline in .zet/eval-baseline.json
# Compares current run against last recorded pass_rate
# Exit 1 on regression, exit 0 on stable or improved
```

## Design Principles

- Cheapest layer first: 81% of skill failures are structural — catch them with free regex/contains before reaching for expensive LLM judges
- One behavior per scenario: each scenario tests ONE property (safety, format, quality). Composable, not monolithic
- Framework is generic: scenarios are private. The `evals/` directory in YOUR project contains YOUR golden scenarios. Zet provides the runner and examples
- Assertions over vibes: "the output felt wrong" is not actionable. "regex X didn't match" is

## Integration with Improvement Loops

The eval score becomes the fitness function for self-improvement:

```
Capture output → Score (zet eval) → Track trends → Detect degradation → Improve template → Re-score (regression check)
```

This closes the loop between "something is wrong" (friction) and "is it getting better?" (eval trend).
