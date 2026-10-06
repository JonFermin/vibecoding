# vibecoding

A Claude Code plugin that transforms design documents into working codebases through autonomous, agent-driven execution.

Provide a spec or design doc, and **vibecoding** handles the rest — breaking it down into dependency-aware phases and executing them with parallel or sequential agents. It's project management that ships code.

**Harness-first (2.0).** Following OpenAI's [harness engineering](https://openai.com/index/harness-engineering/) principles, every task is independently validated by an agent that boots the app and drives it, and nothing is `DONE` without a `PASS`. When validation can't observe something, vibecoding builds the missing capability as a `[HARNESS]` task instead of retrying. You review evidence at milestones, not diffs. See [docs/harness-engineering.md](docs/harness-engineering.md).

## Features

### Skills

| Skill | Description | Use Case |
|-------|-------------|----------|
| **generate-roadmap** | Parses design docs, audits the harness (boot / observe / drive / invariants), and produces a phased `ROADMAP.md` with typed, agent-verifiable AC | Turn a spec into a structured implementation plan |
| **execute-roadmap** | Walks through the roadmap phase-by-phase, spawning agents per task and validating each by driving the running app | Supervised execution with checkpoints at milestones |
| **auto-execute-roadmap** | Fully autonomous headless execution with no interaction required | Unattended overnight runs that commit and push at each milestone |
| **archive-roadmap** | Validates all tasks are complete, then archives the roadmap | Clean up finished roadmaps after delivery |
| **analyze-sessions** | Reads recent session JSONL files, identifies repeated workflows, and recommends automation | Surface opportunities to automate recurring patterns |

### Agents

| Agent | Role |
|-------|------|
| **phase-executor** | Implements one task in an isolated worktree |
| **ac-verifier** | Mechanical gate: `cmd:` / `invariant:` clauses, build/test/lint/architecture lints |
| **validator** | Independent behavioral check: boots the worktree, drives it (browser, HTTP, headless sim, Godot, CLI), writes evidence to `.vibecoding/evidence/`, returns PASS / FAIL / CANNOT_VALIDATE |
| **phase-reviewer** | Reviews each phase's diff and evidence; proposes rules to promote into lints |
| **spike-researcher** | Read-only investigation for `[SPIKE]` tasks |

### Doc Refactor Hook

A Stop hook that fires at the end of each session. When `CLAUDE.md` has been modified, it automatically:

- Splits H2 sections into individual `.claude/rules/*.md` files via pattern matching
- Syncs tagged sections into external docs (README, CONTRIBUTING) between marker comments
- Deduplicates consecutive lines and collapses excessive whitespace

Safety mechanisms include a `stop_hook_active` re-entrancy guard, SHA-256 hash checks to skip unchanged files, and post-write hash updates to prevent self-triggering.

## Installation

Install via the Claude Code plugin marketplace, or point Claude Code at this repository directly.

**Dependencies:** `jq` is required for the doc-refactor hook. Browser validation uses the Playwright MCP server if available, and otherwise falls back to the project's own Playwright install.

## License

MIT
