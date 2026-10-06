# Harness engineering in vibecoding

vibecoding 2.0 is built around the principles in OpenAI's [Harness engineering: leveraging Codex in an agent-first world](https://openai.com/index/harness-engineering/). This doc explains how those principles map onto the plugin, what's implemented, and what's planned.

## The principles we adopt

| Principle (from the article) | What it means here |
|---|---|
| **Humans steer, agents execute.** | The human writes intent (design docs → ROADMAP.md), reviews milestones, and decides on taste. Agents do everything between milestones. |
| **When an agent fails, ask "what capability is missing?"**, not "try harder". | Failures are classified. A harness gap becomes a `[HARNESS]` task that builds the missing capability. A retry won't fix it. |
| **Make the app legible to the agent.** Bootable per worktree; UI, logs, and metrics directly inspectable. | Every roadmap has a `## Harness` section (Boot / Ready / Driver / Observe / Reach). Phase 0 builds whatever is missing. |
| **Agents validate by driving the app.** Reproduce, fix, validate, record. | `@validator` boots the task's worktree, drives it, and writes before/after evidence. No `DONE` without a `PASS`. |
| **Enforce invariants, not implementations.** Custom lints whose errors carry remediation. | `invariant:` AC clauses and a Harness `Invariants` command. Harness lints must say how to fix, not just what's wrong. |
| **Human taste is captured once, then enforced continuously.** | Phase reviewer emits *promote-to-rule* candidates. At milestones the human promotes them to lints or docs. |
| **Repository knowledge is the system of record; AGENTS.md is a map.** | ROADMAP.md plus collapsed phase summaries (now including Harness hooks). Decision log and map linting are planned. |
| **Human attention is the scarce resource.** | Checkpoints only at milestones, and the human reviews evidence (screenshots, verdicts), not diffs. |
| **Entropy needs garbage collection.** | Planned `garden` skill. |

## Agentic validation

### Who checks what

| Agent | Checks | How | Independence |
|---|---|---|---|
| `@phase-executor` | everything, informally (self-probe) | runs commands, boots the app once | builder, not trusted as a verdict |
| `@ac-verifier` | `cmd:` and `invariant:` | runs commands, exit codes | mechanical |
| `@validator` | `probe:` and milestone `JOURNEY:` | boots the worktree on its own port and drives it with a browser, HTTP, headless sim, Godot headless, or CLI | sees only the AC and the Harness, **never the executor's report** |
| `@phase-reviewer` | the diff and the validator's evidence | reads code and `verdict.json` | flags validation gaps and promote-to-rule candidates |

### Typed acceptance criteria

```
AC: cmd: test passes for src/cart/
    probe: add 2 items → badge shows "2" and getState().cart.items.length === 2; no console errors
    invariant: Invariants clean (cart/ has no ui/ imports)
```

- `cmd:` is deterministic. It refers to Harness commands by name.
- `probe:` is written as *action → observable result*, naming what to observe (DOM text, `getState()` field, status code, log line, stdout).
- `invariant:` is a structural rule. It encodes the rule, not the implementation ("parse at the boundary", not "use Zod").

Any task with user-, client-, or player-observable behavior must have a `probe:`.

### The task lifecycle

```
executor (worktree) ──► gate: ac-verifier (cmd + invariant)
                          │ fail → implementation bug → retry with output
                          ▼
                       validator (probe), independent, own port, evidence → main repo
                          │ PASS            → integrity check → merge "Validated: PASS — .vibecoding/evidence/N/"
                          │ FAIL            → implementation bug → retry with repro (max 2 interactive / 1 auto)
                          │ CANNOT_VALIDATE → harness gap → insert [HARNESS] task → run → re-validate
                          ▼
                       DONE
```

**DONE rule (strict, interactive and auto):** all `cmd:`/`invariant:` pass, validator `PASS` on every `probe:`, and validation left the worktree untouched. There's no override.

### CANNOT_VALIDATE is the key verdict

It means the environment can't make the claim observable: no boot command, state that only exists as canvas pixels, no way to reach the state, logs not exposed. The validator has to name the missing capability as a buildable task, for example:

- "Expose `window.__debug.getState().cart` so cart contents are assertable"
- "Add `?scenario=boss-room` to jump to the boss fight"
- "Add `db:seed:test` with one user and two orders"

The orchestrator inserts it as `[HARNESS]`, runs it, and re-validates. Over a roadmap, the harness grows to fit what the project actually needs to verify. That's the article's "make it legible and enforceable" loop, automated.

Guardrails:

- The same capability requested twice for one task is treated as a spec problem.
- Auto mode halts at 3 harness insertions in one phase, because a harness that thin needs a human to look at it.

### Evidence

- Location: `<repo>/.vibecoding/evidence/<task-id>/`, and `phase-<N>/` for journeys. It's **gitignored**, and execute skills add `.vibecoding/` to `.gitignore`.
- Contents: `plan.md`, `before-*.png` / `after-*.png`, `console.log`, `requests.log` or `responses/`, `boot.log`, `verdict.json`. Re-validations move older runs to `attempt-<n>/`.
- Traceability: merge commits carry `Validated: PASS — .vibecoding/evidence/N/`.
- Written to the main repo, not the worktree, so it survives `ExitWorktree`. The orchestrator also checks that the validator didn't touch the worktree.

### Stack drivers

| Stack | Driver | Observe (prefer state over pixels) | Reach |
|---|---|---|---|
| Vite + Three / Babylon / Phaser | `browser` (Playwright MCP) | `window.__debug.getState()` in dev builds | `?seed=`, `?scenario=` |
| Express / Rails APIs | `http` | response bodies, JSON logs | test seed / fixtures |
| Expo | `browser` on Expo web, plus `http` for the backend | same as above | same as above |
| Deterministic sims (shardfall, implode) | `headless-sim` | structured sim output | scenario args |
| Godot (pavop, duelyst) | `godot-headless` | debug autoload `--dump-state` | scene args |
| CLI / library | `cli` | stdout, files, exit code | input fixtures |

### Ports

Executors and validators each get a port pair: `validatorBasePort` (default 4800) `+ 2 × slot`, with `+1` for the validator's "before" instance. That instance only runs when a probe could already hold at the base ref (bug fixes, regressions), and it boots from the main checkout. The validator never creates a worktree for it. Projects with pinned dev ports (looter-shooter, pool-8ball on 8080) need a Phase 0 harness task so their Boot command honors `$PORT`.

## Checkpoints

- **Non-milestone phases:** integration check, then phase review, then auto-continue. The user is interrupted only for spec problems or blocked tasks.
- **MILESTONE phases:** journey validation (the phase's `JOURNEY:` line, driven end to end), then a checkpoint. The checkpoint shows the evidence, reviewer notes since the last milestone, and promote-to-rule candidates.
- **auto-execute:** the same flow with no pauses. A milestone journey failure halts the run after one fix attempt.

## Rollout

| Step | Status | Contents |
|---|---|---|
| 1 | **Done (2.0.0)** | `## Harness` section, typed AC, Phase 0 harness audit, `@validator`, evidence, strict DONE rule, milestone-only checkpoints with journey validation, legacy roadmap migration |
| 2 | **Done (2.0.0)** | Failure classification (implementation / harness gap / spec), automatic `[HARNESS]` insertion, auto-mode halt on harness churn |
| 3 | Planned | **Agent review loop per task.** Executor ↔ `@task-reviewer` (correctness, invariants, agent legibility) iterate until satisfied, N rounds max. Findings that repeat across tasks get promoted to lints automatically, with human approval at the milestone. |
| 4 | Planned | **Repository as system of record.** Collapsed phase summaries also go to `docs/decisions/` so knowledge survives `archive-roadmap`. The doc-refactor hook lints CLAUDE.md as a ~100-line map with valid pointers. `docs/QUALITY.md` grades each area. |
| 5 | Planned | **`garden` skill.** After each milestone or on a schedule: scan for golden-principle drift and stale docs, update quality grades, and append small cleanup tasks to a `## Gardening` phase. |

## Migrating an existing roadmap

Running `execute-roadmap` or `auto-execute-roadmap` on a 1.x roadmap (`## Tech Stack`, untyped ACs) triggers migration before the first dispatch:

1. `Dev` is treated as `Boot`.
2. Typed ACs are drafted for every remaining `TODO`, with `probe:` added wherever there's observable behavior.
3. `[HARNESS]` Phase 0 tasks are added for missing Boot/Ready/Observe.

Interactive mode shows you the diff once. Auto mode applies it and flags it in the morning summary. Completed (`DONE`) tasks aren't re-validated.
