# Contributing to Zet

Thanks for your interest in contributing.

## Developer Certificate of Origin (DCO)

All contributions must be signed off to certify you have the right to submit them under the project's MIT license. This is a lightweight alternative to a CLA — you keep your copyright, you just confirm the work is yours to submit.

Add `Signed-off-by` to every commit:

```bash
git commit -s -m "feat: your change"
```

This adds a line like:
```
Signed-off-by: Your Name <your@email.com>
```

By signing off, you agree to the [DCO](https://developercertificate.org/):

> I certify that my contribution is made under the terms of the MIT License and I have the right to submit it.

PRs without sign-off will be flagged by CI. Use `git commit --amend -s` to add sign-off to your last commit.

## Development Setup

```bash
git clone git@github.com:xinyun2020/zet.git
cd zet
git checkout dev
chmod +x bin/zet core/*.sh tests/*.sh
```

Verify everything works:

```bash
./bin/zet test
./bin/zet validate
./bin/zet scan
```

## Branching

- `main` — stable releases only. Protected branch — requires PR with passing CI
- `dev` — active development. PRs target here
- `feat/<name>` — feature branches, PR to `dev`

## Making Changes

1. Create a feature branch from `dev`:
   ```bash
   git checkout dev && git pull
   git checkout -b feat/your-feature
   ```

2. Make your changes. Write tests for new functionality

3. Run the full check:
   ```bash
   ./bin/zet doctor
   ```

4. Commit with conventional format and sign-off:
   ```
   feat: add new validate rule for paths field

   Signed-off-by: Your Name <your@email.com>
   ```

5. Push and open a PR to `dev`

## Design Principles

Before proposing changes, understand what Zet values:

- Zero external dependencies (bash + python3 only)
- Convention over configuration
- Extract from working systems, don't invent
- Every error message should teach (include WHY and HOW TO FIX)
- Tests are the spec — if it's not tested, it doesn't exist

## What We Accept

- Bug fixes with regression tests
- New scanner checks (dead code patterns)
- New validator rules (template anti-patterns)
- Documentation improvements
- Performance improvements to existing commands

## What Needs Discussion First

Open an issue before working on:

- New CLI commands
- Changes to the template spec
- New dependencies
- Architectural changes

## Code Style

- Shell scripts: `set -e`, functions for reusable logic, no bashisms beyond bash 4+
- Comments explain WHY, not WHAT
- Error messages: "ERROR: what happened — how to fix"
- Keep files under 400 lines

## Tests

Tests use `core/test-runner.sh`. Pattern:

```bash
#!/bin/bash
source "$(dirname "$0")/../core/test-runner.sh"

zet_test_setup
# ... your assertions ...
zet_test_teardown
zet_test_results
```

Every new feature needs tests. Every bug fix needs a regression test.
