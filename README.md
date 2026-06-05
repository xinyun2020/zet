# Zet

The framework for natural language as code.

https://github.com/user-attachments/assets/55ad60d0-d67f-46dd-a371-589cc6f65fb0

## Why

Natural language is code now. Prompt templates are functions. Skills are modules. Hooks are middleware. Rules are linters. Your AI config directory is a codebase.

But there's no framework for it. No linter catches your broken template references. No test runner verifies your skills still work. No scanner finds the dead config you forgot to delete. No health checker spots the API key you accidentally left in a prompt.

You'd never ship JavaScript without a framework, linter, and test suite. Your AI configuration deserves the same rigor.

## What Zet Does

Zet gives you the full lifecycle for AI agent configuration:

```
create → validate → generate → deploy → test → scan → improve
```

- **Validate** your templates (frontmatter, structure, required fields)
- **Generate** deployed skills, agents, and rules from source templates
- **Test** that your harness works after changes
- **Scan** for dead code, orphaned hooks, stale references
- **Doctor** your config health (broken links, secrets, drift)

Think: `package.json` defines a Node project. `zet.toml` defines an AI harness.

## Quick Start

```bash
# Option 1: npx (zero install)
npx @xinyun2020/zet init
npx @xinyun2020/zet generate

# Option 2: npm global install
npm install -g @xinyun2020/zet
zet init
zet generate

# Option 3: Homebrew (macOS)
brew tap xinyun2020/tap && brew install zet

# Option 4: curl install (no Node required)
curl -fsSL https://raw.githubusercontent.com/xinyun2020/zet/main/install.sh | bash
```

`zet init` scaffolds a `zet.toml` and starter template. From there:

```bash
zet validate          # Check template structure and frontmatter
zet generate          # Build skills/agents/rules from templates
zet test              # Run your test suite
zet scan              # Detect dead code, orphaned hooks, drift
zet doctor            # Health check (broken links, stale paths, secrets)
zet healthcheck       # All of the above in one pass
zet new <type> <name> # Create a new template (skill, agent, or rule)
zet coverage          # Report test and documentation coverage
```

## The Pain Without a Framework

At 3 skills, you're fine. At 30:

- You rename a file → 4 references break silently, your AI gives wrong answers
- You delete a template → the deployed skill stays forever, confusing your agent
- Your AI tool updates → no way to know which skills still work
- A teammate copies your skills → they don't work (missing model-roles config)
- An API key sits in a template → you push to GitHub

`zet doctor` catches all of this. Once you see the output, you can't go back.

## Configuration

`zet.toml` — one file, everything configured:

```toml
[project]
name = "my-harness"
version = "0.1.0"

[paths]
templates = "templates/"
skills = "~/.claude/skills/"
agents = "~/.claude/agents/"
rules = "~/.claude/rules/"

# Optional: generate Agent Skills Open Standard output for cross-tool interop
# agents-std = ".agents/skills/"

[model-roles]
audit = "haiku"
execute = "sonnet"
think = "opus"
```

### Multi-tool output (Codex, Cursor, Gemini CLI, etc.)

Zet generates Claude Code config by default. To also output the [Agent Skills Open Standard](https://agentskills.io) format (read by 30+ tools including Codex CLI, Cursor, Gemini CLI, Kiro, and Windsurf), add `agents-std` to your paths:

```toml
[paths]
templates = "templates/"
skills = "~/.claude/skills/"
agents-std = ".agents/skills/"   # interop output (gitignored or committed — your choice)
```

Then run `zet generate` as normal. Skills are written to BOTH locations from the same templates — single source of truth, multiple consumers.

You can also set it via environment variable for one-off runs:

```bash
ZET_AGENTS_STD=".agents/skills/" zet generate
```

The interop output uses the same SKILL.md format (YAML frontmatter + markdown body) that Claude Code uses. No translation, no lossy conversion — the format IS the standard.

## Documentation

- [Concept](docs/concept.md) — why AI config needs engineering rigor
- [Primitives](docs/primitives.md) — the four building blocks (template, hook, generator, scanner)
- [Lifecycle](docs/lifecycle.md) — create → validate → generate → test → scan → improve
- [Template Spec](docs/template-spec.md) — full frontmatter reference and naming conventions
- [Examples](examples/) — real templates you can copy and use immediately

## Upgrade

```bash
npm update -g @xinyun2020/zet
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
