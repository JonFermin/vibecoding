# vibecoding

A Claude Code plugin for when you'd rather describe the app than build it.

You know those days where you have a pile of ideas, a solid design doc, and absolutely zero desire to touch a keyboard? This is the plugin for that. Hand Claude a spec, go grab a coffee, and come back to a codebase.

## What It Does

**vibecoding** turns Claude Code into a project manager that actually ships code. It breaks your grand vision into dependency-aware phases, then executes them — with parallel agents if you're feeling ambitious, or sequentially if you want to pretend you're supervising.

### Skills

| Skill | What It Does | When You'd Use It |
|-------|-------------|-------------------|
| **generate-roadmap** | Reads your docs and builds a phased `ROADMAP.md` with dependency tracking | You have a design doc and want a plan without planning |
| **execute-roadmap** | Walks through the roadmap phase-by-phase, spawning agents per task | You want to watch progress bars instead of writing code |
| **auto-execute-roadmap** | Fully autonomous headless execution — no interaction needed | You want to go to sleep and wake up to a PR |
| **archive-roadmap** | Checks if all tasks are done, then files the roadmap away | Spring cleaning for your completed ambitions |
| **doc-refactor-hook** | Stop hook that auto-splits CLAUDE.md into `.claude/rules/` files | You want your docs organized but refuse to organize them yourself |

### The Doc Refactor Hook

A Claude Code Stop hook that fires every time a session ends. If you've touched `CLAUDE.md`, it automatically:

- Splits H2 sections into individual `.claude/rules/*.md` files based on pattern matching
- Syncs tagged sections into external docs (README, CONTRIBUTING) between marker comments
- Deduplicates consecutive duplicate lines and collapses excessive whitespace

Three safety guards keep it from going rogue: a `stop_hook_active` check prevents hook loops, a SHA-256 hash skips unchanged files, and post-write hash updates prevent self-triggering.

## Installation

This is a Claude Code plugin. Install it via the plugin marketplace or point Claude Code at this repo.

**Requires:** `jq` for the doc-refactor hook (the rest works without it).

## License

MIT
