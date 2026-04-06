# vibecoding

A Claude Code plugin that transforms design documents into working codebases through autonomous, agent-driven execution.

Provide a spec or design doc, and **vibecoding** handles the rest — breaking it down into dependency-aware phases and executing them with parallel or sequential agents. It's project management that ships code.

## Features

### Skills

| Skill | Description | Use Case |
|-------|-------------|----------|
| **generate-roadmap** | Parses design docs and produces a phased `ROADMAP.md` with dependency tracking | Turn a spec into a structured implementation plan |
| **execute-roadmap** | Walks through the roadmap phase-by-phase, spawning agents per task | Supervised, interactive execution with checkpoints |
| **auto-execute-roadmap** | Fully autonomous headless execution with no interaction required | Unattended overnight runs that commit and push at each milestone |
| **archive-roadmap** | Validates all tasks are complete, then archives the roadmap | Clean up finished roadmaps after delivery |
| **analyze-sessions** | Reads recent session JSONL files, identifies repeated workflows, and recommends automation | Surface opportunities to automate recurring patterns |

### Doc Refactor Hook

A Stop hook that fires at the end of each session. When `CLAUDE.md` has been modified, it automatically:

- Splits H2 sections into individual `.claude/rules/*.md` files via pattern matching
- Syncs tagged sections into external docs (README, CONTRIBUTING) between marker comments
- Deduplicates consecutive lines and collapses excessive whitespace

Safety mechanisms include a `stop_hook_active` re-entrancy guard, SHA-256 hash checks to skip unchanged files, and post-write hash updates to prevent self-triggering.

## Installation

Install via the Claude Code plugin marketplace, or point Claude Code at this repository directly.

**Dependency:** `jq` is required for the doc-refactor hook. All other skills work without additional dependencies.

## License

MIT
