---
description: The four building blocks — template, hook, generator, scanner — and how they compose
---

# Core Primitives

- parent:
  - [Concept](concept.md)

Zet has four primitives. Everything else is orchestration around these.

## Template

The fundamental unit. A markdown file with YAML frontmatter that defines a capability.

```
my-skill_prompt_template.md
```

Templates differentiate by `type:` field:
- `skill` — user-invocable capability (slash command)
- `agent` — subagent definition (spawned by skills or other agents)
- `rule` — path-scoped instruction (loads automatically when editing matching files)

Analogy: React component. Self-contained, composable, testable.

Full spec: [template-spec.md](template-spec.md)

## Hook

Intercepts events and enforces constraints mechanically. Runs without human decision.

Hooks fire on lifecycle events (pre-push, post-edit, session-start). They validate, block, or transform — never ask.

Analogy: Express middleware.

Why hooks over rules: a rule says "don't push secrets." A hook prevents it. Deterministic enforcement beats advisory instructions.

## Generator

Transforms templates into deployed config. The build step.

`zet generate` reads all templates, resolves paths, validates structure, and writes the final skill/agent/rule files to their deploy locations.

Analogy: Webpack/Vite. Source → built output.

Why a build step: templates can reference each other, use model-role resolution, include shared frontmatter. The generator resolves these at build time so the deployed config is self-contained.

## Scanner

Detects drift, dead code, and violations. The lint step.

`zet scan` finds:
- Ghost skills (deployed but no source template)
- Orphaned hooks (referenced in config but file missing)
- Duplicate names (two templates generating the same output)
- Stale references (wiki links pointing to deleted files)

Analogy: ESLint + SonarQube.

Why continuous scanning: config rots silently. A file rename, a deleted template, a typo — none produce errors. They just stop working. The scanner catches what humans miss.

## How They Compose

```
Template  →  Generator  →  Deployed config
    ↑                           ↓
Scanner  ←  (detects drift)  ←  Runtime
    ↓
  Hook   →  (enforces rules at edit/push time)
```

The loop: write templates → generate → deploy → scan for drift → hooks prevent common mistakes → repeat.
