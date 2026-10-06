---
name: auto-execute-roadmap
description: Use when the user asks to execute a ROADMAP.md headless/overnight — runs autonomously with no user interaction, independently validates every task by driving the running app, inserts harness tasks when validation can't observe something, and commits and pushes at every milestone
---

# Auto-Execute Roadmap

## How to Run Headless

```bash
# Basic overnight run
claude --dangerously-skip-permissions -p \
  "Run /auto-execute-roadmap on this project. Do not pause for input." \
  2>&1 | tee overnight-output.log

# With resilience loop (re-invokes if session hits context limit)
#!/bin/bash
MAX_RUNS=20
for i in $(seq 1 $MAX_RUNS); do
  echo "=== Run $i at $(date) ===" >> overnight-output.log
  claude --dangerously-skip-permissions -p \
    "Run /auto-execute-roadmap. Resume from where the last session left off." \
    2>&1 | tee -a overnight-output.log
  if grep -q "ROADMAP COMPLETE\|ALL PHASES DONE" auto-roadmap.log 2>/dev/null; then
    echo "Roadmap complete!" >> overnight-output.log
    break
  fi
  sleep 5
done
```

## Overview

Reads a `ROADMAP.md` (produced by `generate-roadmap`), then builds the project phase-by-phase directly on main — **fully autonomously with zero user interaction**. This is a fork of `execute-roadmap` designed for overnight/headless runs. Every checkpoint that would normally ask the user is replaced with an autonomous decision policy.

The same harness-engineering rules apply as in `execute-roadmap`: each task is built by one agent and **independently validated by another** that boots the app and drives it. A task is `DONE` only with a validator `PASS`. When validation can't observe something, the run inserts a `[HARNESS]` task to build the missing capability instead of retrying blindly. Background: `${CLAUDE_PLUGIN_ROOT}/docs/harness-engineering.md`.

All autonomous decisions are logged to `auto-roadmap.log`. At the end of the run (or on halt), `auto-roadmap-summary.md` is written for morning review. Its centerpiece is the evidence index: what was validated, with screenshots and verdicts under `.vibecoding/evidence/`.

## Reusable Agents

Dispatch the same named agents as `execute-roadmap` (defined in `${CLAUDE_PLUGIN_ROOT}/agents/`):

- `@phase-executor` — implements a single task (one per task in parallel mode).
- `@spike-researcher` — investigates `[SPIKE]` tasks and returns a refined scope. Auto-proceed with its recommendation.
- `@ac-verifier` — the mechanical gate: `cmd:`/`invariant:` clauses, Harness Build/Test/Lint/Invariants, Boot→Ready smoke at integration.
- `@validator` — independent behavioral validation of `probe:` clauses and milestone `JOURNEY:` lines. Writes evidence and returns `PASS` / `FAIL` / `CANNOT_VALIDATE`.
- `@phase-reviewer` — diff-based quality review after each phase's integration check (only if `runPhaseReviewer` is enabled).

## Plugin Options (read at runtime)

Honor these env vars (set by Claude Code from `plugin.json` `userConfig`), falling back to defaults if unset:

- `CLAUDE_PLUGIN_OPTION_PARALLELAGENTLIMIT` (default `4`) — cap on concurrent phase-executors.
- `CLAUDE_PLUGIN_OPTION_DEFAULTEFFORT` (default `medium`) — effort passed to dispatched agents. `xhigh` requires an Opus model (`@phase-executor` and `@phase-reviewer` run on Opus 5.5).
- `CLAUDE_PLUGIN_OPTION_WORKTREEPARENTDIR` (default `..`) — parent directory for worktrees.
- `CLAUDE_PLUGIN_OPTION_AUTOCOMMITONACPASS` (default `true`) — when `false`, leaves validated branches unmerged for morning review.
- `CLAUDE_PLUGIN_OPTION_RUNPHASEREVIEWER` (default `true`) — whether to dispatch `@phase-reviewer` after each phase's integration check.
- `CLAUDE_PLUGIN_OPTION_VALIDATORBASEPORT` (default `4800`) — first port for app instances booted by executors and validators (`base + 2 × slot`, and `+1`).

## When to Use

- User says "run the roadmap overnight", "headless execution", "auto-execute"
- User wants unattended, autonomous roadmap execution
- A `ROADMAP.md` exists in the project root

## Autonomous Decision Policy

| Checkpoint | Autonomous Behavior |
|---|---|
| **Legacy / untyped AC** | Auto-migrate: draft typed `cmd:`/`probe:`/`invariant:` ACs for remaining `TODO` tasks, add Harness fields and `[HARNESS]` Phase 0 tasks for missing Boot/Ready/Observe. Commit, log `DECISION`, flag for morning review. |
| **BLOCKED tasks** | Skip blocked tasks, log reason to `auto-roadmap.log`. Never wait for resolution. |
| **SPIKE findings** | Auto-proceed with the research agent's recommended approach. Log the recommendation. |
| **Parallel mode** | Auto-choose: use parallel if tasks have non-overlapping scopes AND phase has 2+ tasks (default). Otherwise sequential. Log the choice. |
| **Gate failure / validator FAIL** (implementation bug) | Retry once with the failing output or validator repro. If retry fails, skip the task + log. Increment consecutive failure counter. |
| **Validator CANNOT_VALIDATE** (harness gap) | Insert a `[HARNESS]` task for the named capability, run it, re-validate the original. Doesn't count as a failure or a retry. Log `HARNESS`. |
| **Spec problem** | Skip the task with `[FAILED: spec — reason]`, log it, flag for morning review. Never rewrite an AC to make it pass. |
| **Phase reviewer `needs rework`** | Treat as a validator `FAIL` for that task (one retry). Other findings are logged for the summary. |
| **Non-milestone phase end** | Auto-continue after integration check passes. If integration fails, attempt fix once, then **halt**. |
| **Milestone phase end** | Run journey validation. On PASS: push, log, continue. On FAIL: attempt fix once, then **halt**. |
| **Mid-execution re-plan** | Log the discovery, continue as-is. Flag for morning review in summary. |
| **Session break suggestion** | Auto-break: commit ROADMAP.md + push, then resume immediately. |

## Halt Conditions

**Stop execution entirely** (do not skip, do not continue) when:
1. Integration check fails after one fix attempt
2. Milestone journey validation fails after one fix attempt
3. 3 or more consecutive task failures occur (counter resets on any validated success)
4. 3 or more `[HARNESS]` tasks inserted in a single phase. The harness is too thin for unattended work, and a human should look at the gaps.
5. No `ROADMAP.md` found in project root

On halt: write the morning summary immediately before stopping.

## Logging Format

All autonomous decisions are appended to `auto-roadmap.log` in the project root:

```
[YYYY-MM-DD HH:MM:SS] [LEVEL] message
```

Levels: `INFO`, `SKIP`, `RETRY`, `FAIL`, `HALT`, `PUSH`, `DECISION`, `VALIDATE`, `HARNESS`

Examples:
```
[2026-03-15 02:14:01] [INFO] Starting Phase 2 — 5 tasks (3 parallel, 2 sequential)
[2026-03-15 02:14:02] [SKIP] Task #7 BLOCKED: waiting on external API credentials
[2026-03-15 02:15:30] [DECISION] Parallel mode chosen for Phase 2: 3 tasks with non-overlapping scopes
[2026-03-15 02:28:40] [VALIDATE] Task #8 PASS — .vibecoding/evidence/8/
[2026-03-15 02:30:12] [VALIDATE] Task #9 FAIL — badge shows "1" after adding 2 items
[2026-03-15 02:30:13] [RETRY] Task #9 — retrying with validator repro (attempt 2/2)
[2026-03-15 02:41:02] [VALIDATE] Task #10 CANNOT_VALIDATE — cart total only rendered to canvas
[2026-03-15 02:41:03] [HARNESS] Inserted #23 for #10: expose cart total via window.__debug.getState()
[2026-03-15 03:01:00] [VALIDATE] Phase 2 journey PASS — .vibecoding/evidence/phase-2/
[2026-03-15 03:01:05] [PUSH] Phase 2 complete — pushed to origin/main
[2026-03-15 04:12:00] [HALT] 3 consecutive failures — stopping execution
```

## Process Flow

```
Read ROADMAP.md → Parse Harness → migrate legacy AC if needed → Find first incomplete phase
  ↓
For each phase:
  ├─ Identify unblocked tasks (skip BLOCKED → log); [HARNESS] first, then P0
  ├─ Handle SPIKEs (auto-proceed with recommendation)
  ├─ Auto-choose parallel vs sequential
  ├─ Dispatch executors
  ├─ Per task, in its worktree:
  │   ├─ Gate (ac-verifier: cmd + invariant)
  │   ├─ Validate (validator: probe, independent, evidence)
  │   ├─ PASS → merge, mark DONE, commit
  │   ├─ FAIL → retry once with repro → skip + log (check halt)
  │   └─ CANNOT_VALIDATE → insert [HARNESS] task → run it → re-validate (check halt)
  ├─ Update ROADMAP.md (collapse phase if all done)
  ├─ Integration check (+ phase review)
  │   ├─ Fail → attempt fix once → still failing → HALT
  ├─ MILESTONE? → journey validation → fail → fix once → still failing → HALT
  ├─ Commit, push, log → next phase
  └─ Check consecutive failure counter → HALT if ≥ 3
  ↓
All phases DONE → write morning summary → log "ROADMAP COMPLETE"
```

## Step 1 — Read, Validate, and Parse

- Read `ROADMAP.md` from project root. **If it does not exist**, log `[HALT] No ROADMAP.md found` and stop. Do not proceed.
- Read `CLAUDE.md` if it exists — extract coding conventions, tech stack, standards that agents must follow.
- Read architecture/design docs referenced in the project.
- **Parse the Harness section:** extract Build, Test, Lint, Invariants, Boot, Ready, Driver, Observe, Reach. Legacy roadmaps call it `## Tech Stack` with Build/Test/Lint/Dev. Treat `Dev` as `Boot`.
- **Evidence directory:** ensure `.vibecoding/` is in the project's `.gitignore` (add and commit `chore: ignore vibecoding evidence` if not).
- **Legacy migration:** if ACs are untyped, or tasks with observable behavior lack a `probe:`, auto-migrate per the decision policy. Log `[DECISION] Migrated N tasks to typed AC; inserted M harness tasks`.
- **Validate format:** Check that every task has `scope:`, `AC:`, a priority, a size, and a sequential `#ID`. If any are missing, log a warning and proceed with best effort — do not halt for format issues.
- Parse phases, task statuses, dependencies.
- Identify the first phase that is not `DONE`.
- **Initialize log:** Append to `auto-roadmap.log`:
  ```
  [timestamp] [INFO] === AUTO-EXECUTE SESSION START ===
  [timestamp] [INFO] Roadmap: X phases, Y tasks total, Z already DONE
  ```
- **Initialize consecutive failure counter** to 0, and a per-phase harness-insertion counter to 0.

## Step 2 — Identify Unblocked Tasks

Within the current phase, find all tasks where:
- Status is `TODO` (skip `DONE` or `IN PROGRESS`)
- Task is NOT flagged `[BLOCKED: ...]`
- All `depends: #x` references point to tasks marked `DONE` or in a completed phase

**Handle BLOCKED tasks autonomously:**
1. For each blocked task, log: `[SKIP] Task #N BLOCKED: {reason}`
2. Do NOT attempt to resolve blockers — skip them entirely.
3. If ALL tasks in a phase are blocked:
   - Log: `[SKIP] Phase N entirely blocked — all tasks have unresolved blockers`
   - Skip to the next phase. If no more phases, halt.
4. At phase end, blocked tasks are listed in the morning summary for review.

Order unblocked tasks within the phase: `[HARNESS]` first, then P0, then P1, then P2.

## Step 3 — Handle SPIKE Tasks

If a task has the `[SPIKE]` flag:

1. Dispatch the `@spike-researcher` agent with the task id, description, scope, and any open questions from the task. The agent file (`agents/spike-researcher.md`) defines the full contract.
2. **Auto-proceed:** Accept the agent's recommended approach without review.
3. Log: `[DECISION] SPIKE #N — auto-accepted recommendation: {one-line summary}`
4. Update the task description, typed AC, and size in ROADMAP.md based on findings.
5. Remove the `[SPIKE]` flag and proceed to dispatch the implementation agent.

## Step 4 — Mark In Progress and Dispatch Agent

Before dispatching, mark the task as `IN PROGRESS` in ROADMAP.md and commit. This enables resumability if the session is interrupted.

**Auto-choose dispatch mode:**

- **Parallel mode (default):** If the phase has 2+ unblocked tasks AND their `scope:` values do not overlap → use parallel with worktrees. Log: `[DECISION] Parallel mode chosen for Phase N: {count} tasks with non-overlapping scopes`
- **Sequential mode (fallback):** Otherwise → use sequential. Log: `[DECISION] Sequential mode for Phase N: {reason}`

**Parallel workflow:**
1. For each task, dispatch the `@phase-executor` agent with `isolation: "worktree"`. Cap concurrent agents at `CLAUDE_PLUGIN_OPTION_PARALLELAGENTLIMIT` (default 4) — queue any remaining tasks and dispatch them as earlier ones merge.
2. Each agent works in its own copy of the repo — no conflicts possible.
3. As each agent completes, run Step 5 **in its worktree** and merge only on `PASS`, in completion order. Don't wait for all agents to finish.
4. If a merge conflict occurs: resolve it or fall back to sequential for the conflicting task.
5. After merging, **explicitly call `ExitWorktree`** to clean up the worktree directory and branch. Do not rely on automatic cleanup — always call `ExitWorktree` after the merge completes (or once a failed task's worktree is no longer needed).

**`@phase-executor` input contract** (full contract in `agents/phase-executor.md`):

- **Task**: `#{id}: {description}`
- **Acceptance criteria**: typed `cmd:` / `probe:` / `invariant:` clauses, verbatim
- **Scope**: `{scope from roadmap}`
- **Harness**: verbatim from `## Harness` in ROADMAP.md
- **Port**: `CLAUDE_PLUGIN_OPTION_VALIDATORBASEPORT + 2 × slot`
- **Project conventions**: key points from CLAUDE.md
- **Completed dependencies**: `depends:` ids + one-line description of what each produced
- **Phase context**: collapsed summaries of prior completed phases
- **Task type hint**: `harness` | `infra` | `ui` | `api` | `test` | omit for general
- **Prior attempt** (retry only): the gate's failing output or the validator's repro
- **Effort**: `CLAUDE_PLUGIN_OPTION_DEFAULTEFFORT` (default `medium`; `xhigh` for large/risky tasks)

For tasks sized `[L]`, also instruct the executor to commit intermediate progress with messages like `roadmap #{id} (wip): {what was completed}` so overnight session interruptions don't lose work.

**Dispatch rules:**
- `[HARNESS]` first, then P0, within each phase
- Tightly coupled tasks (e.g., a component and its direct wiring) → group into one agent
- In parallel mode, dispatch all independent tasks simultaneously, then gate, validate, and merge each as it completes
- In sequential mode, one task is gated, validated, and committed before the next starts

## Step 5 — Gate, Validate, then Merge

A task is `DONE` only when every `cmd:`/`invariant:` clause passes, `@validator` returns `PASS` for its `probe:` clauses, and validation left the worktree unchanged. No exceptions in auto mode.

1. **Gate:** dispatch `@ac-verifier` (`check type: task-ac`) in the task's worktree with the `cmd:`/`invariant:` clauses and Harness. Fail → Step 6 (implementation bug).
2. **Validate** (tasks with `probe:` clauses): record the worktree's `git status --porcelain` and `HEAD`, then dispatch `@validator` with `check type: task-probe`, the task line, **only** its `probe:` clauses (never the executor's report), the Harness, the worktree path, a free port pair, evidence dir `<repo root>/.vibecoding/evidence/<id>/` (move any previous contents into `attempt-<n>/` first), the base ref, and a **Before checkout**. Pass the main repo root if its `HEAD` equals the base ref and `git status --porcelain` is clean, otherwise `none`. It is always `none` in sequential mode. While a validator holds the main repo as its Before checkout, queue merges into main until it returns.
3. **Integrity check:** if the worktree's status or `HEAD` changed, restore it and re-validate once. A verdict from a run that modified code doesn't count.
4. **Verdict:**
   - `PASS` → log `[VALIDATE] Task #N PASS — <evidence dir>`. Merge with `git merge <branch> --no-ff -m "roadmap #N: <description>" -m "Validated: PASS — .vibecoding/evidence/N/"` and call `ExitWorktree` (if `CLAUDE_PLUGIN_OPTION_AUTOCOMMITONACPASS` is `false`, leave the branch unmerged and list it in the summary). Mark `DONE`. **Reset consecutive failure counter to 0.** Log `[INFO] Task #N DONE ({completed}/{total} in Phase {P})`.
   - `FAIL` → log `[VALIDATE] Task #N FAIL — <one-line>`, go to Step 6 as an implementation bug.
   - `CANNOT_VALIDATE` → log `[VALIDATE] Task #N CANNOT_VALIDATE — <missing capability>`, go to Step 6 as a harness gap.

Tasks with no `probe:` clauses skip steps 2–3.

## Step 6 — Classify and Handle Failures Autonomously

**Implementation bug** (gate failure, validator `FAIL`):
1. Log `[FAIL] Task #N: {details}` and increment the consecutive failure counter. If it's ≥ 3 → summary + **HALT**.
2. **Retry once:** log `[RETRY] Task #N — retrying with {gate output | validator repro} (attempt 2/2)`, re-dispatch the executor with it as **Prior attempt**, then rerun Step 5.
3. If the retry fails: log `[SKIP] Task #N — retry failed, skipping`, mark the task `TODO` with `[FAILED: {reason}]`, call `ExitWorktree`, increment the counter again, re-check the halt condition, and continue.

**Harness gap** (validator `CANNOT_VALIDATE`, a `FAIL` whose repro can't reach the described state, or the same executor friction reported twice):
1. If this task already had a harness task inserted for the **same** capability, treat it as a spec problem instead.
2. Append `- TODO [P0] [S] [HARNESS] #<next id>: <missing capability> — scope: <smallest plausible path>` to the current phase, with a `probe:` AC demonstrating the capability, and add `depends: #<new>` to the original task.
3. Commit ROADMAP.md (`roadmap: insert harness #<new> for #<orig>`), log `[HARNESS] Inserted #<new> for #<orig>: ...`, and increment the phase's harness counter. If it's ≥ 3 → summary + **HALT**.
4. Run the harness task through Steps 4–5 immediately. Once it's merged, rebase the original task's branch onto main and rerun Step 5 on it. If the harness task itself fails after its retry, skip both and log.

**Spec problem** (AC contradicts docs or itself, probe unachievable as written, repeated harness request): log `[SKIP] Task #N — spec problem: {reason}`, mark `TODO` with `[FAILED: spec — reason]`, call `ExitWorktree`, and flag it for morning review. Doesn't increment the failure counter.

**No rollback in auto mode.** Failed tasks are skipped and flagged for morning review.

## Step 7 — Update ROADMAP.md

After each task completes successfully:

1. Mark the task as `DONE`:
   ```
   - DONE [P0] [M] #5: Wire columns to IPC list_dir — depends: #2 ✓, #4 ✓ — scope: src/views/
   ```

2. In subsequent phases, mark newly satisfied dependencies with `✓`:
   ```
   - TODO [P0] [M] #7: Quick Look overlay — depends: #5 ✓ — scope: src/overlay/
   ```

3. If ALL non-blocked tasks in the phase are done, collapse using this structured template:
   ```
   ## Phase N — DONE
   Built: {what was created/implemented}. Patterns: {architectural decisions, conventions established, design patterns chosen}. Harness: {capabilities added}. Key files: {important new/modified files or directories}. Skipped: {any blocked/failed tasks}. (X/Y tasks validated, Z skipped)
   ```
   If the Harness gained a capability, update the `## Harness` section too.

4. Commit the updated `ROADMAP.md` with message: `roadmap: complete phase N`

## Step 8 — Phase Completion: Integration, Milestone Journey, Push

After all dispatchable tasks in a phase are complete:

1. **Integration check:** dispatch `@ac-verifier` with `check type: phase-integration`, the Harness commands, and a free port (Build / Test / Lint / Invariants / Boot→Ready).
   - Fail → log `[FAIL] Phase {N} integration check failed: {details}`, attempt one fix, commit, re-run. Still failing → log `[HALT] ...`, write the summary, **HALT**.
2. **Phase review** (optional): if `CLAUDE_PLUGIN_OPTION_RUNPHASEREVIEWER` is `true`, dispatch `@phase-reviewer` with the phase number, completed task ids, diff range, and each task's verdict line and evidence dir. `needs rework` → one retry of that task (Step 6, implementation bug). Log other findings and promote-to-rule candidates for the summary. Never auto-apply promote-to-rule candidates; the human decides those.
3. **Milestone journey:** if the phase header has `MILESTONE:`, dispatch `@validator` with `check type: journey`, the `JOURNEY:` line (derive one from the milestone title and write it into ROADMAP.md if missing), the Harness, repo root, a free port, and evidence dir `<repo root>/.vibecoding/evidence/phase-<N>/`.
   - PASS → log `[VALIDATE] Phase {N} journey PASS — <evidence dir>`.
   - FAIL / CANNOT_VALIDATE → attempt one fix (an implementation fix, or a harness task for a gap), then re-run. Still failing → log `[HALT] Phase {N} journey failed`, write the summary, **HALT**.
4. **Push:** `git push origin main`, log `[PUSH] Phase {N} complete — pushed to origin/main`, and auto-continue. No pause, at milestones or anywhere else.

## Step 9 — Next Phase

Return to Step 2 with the next incomplete phase. Repeat until all phases are `DONE`.

When all phases are complete:
1. Log: `[INFO] === ALL PHASES DONE — ROADMAP COMPLETE ===`
2. Push final state: `git push origin main`
3. Write morning summary.

## Session Budget Awareness

Large phases can exhaust the conversation context. To manage this:
- If a phase has more than ~8 tasks, after completing each batch of ~5 tasks, commit all ROADMAP.md updates and push. If context is getting long, the resilience loop wrapper will re-invoke and resume.
- When dispatching agents, keep prompts lean — collapsed phase summaries only, not full histories. Don't read evidence files into the main session; the verdict line is enough.
- If you notice the conversation is getting long, commit ROADMAP.md and push at the next natural checkpoint. The resilience loop will pick up where you left off.

## Dependency Verification Between Phases

When starting a new phase, before dispatching any tasks:
1. Identify all dependency tasks referenced by `depends:` in this phase
2. Re-run their `cmd:`/`invariant:` checks via `@ac-verifier` (and their `probe:` checks if the previous phase touched the same scope)
3. If a dependency's AC now fails, attempt to fix it (counts as one fix attempt). If unfixable, halt.

## Resumability

If a session is interrupted mid-phase (or re-invoked by the resilience loop):
1. On resume, read ROADMAP.md and look for `IN PROGRESS` tasks
2. Check git log for commits referencing those task IDs. A merge commit with `Validated: PASS` → mark `DONE`. Work committed but not validated → run Step 5 on it now.
3. For tasks marked `IN PROGRESS` with no committed work, reset to `TODO`
4. Read `auto-roadmap.log` to understand what happened in previous sessions (including harness insertions and their counters for the current phase)
5. **Auto-continue** from where things left off — no user prompt needed.

## Mid-Execution Re-Planning (Autonomous)

If during execution you discover that future phases are invalidated:

1. Finish the current task — don't leave work half-done.
2. Log: `[DECISION] Re-plan trigger: {what changed and which future tasks/phases are affected}`
3. **Continue as-is.** Do NOT re-plan autonomously — this risks diverging from the user's intent. (Inserting a `[HARNESS]` task is not re-planning. It adds a capability without changing intent.)
4. Add the discovery to the morning summary for human review.

## Checkpoint Commits

Commit ROADMAP.md at these moments to ensure recoverability:
- **Task start:** After marking a task `IN PROGRESS`
- **Harness insertion:** After inserting a `[HARNESS]` task
- **Task end:** After marking a task `DONE`
- **Phase end:** After collapsing the completed phase

These commits create a reliable audit trail.

## Agent Context Management

Each dispatched executor receives:
- **Current task(s):** Full description, scope, and typed AC from roadmap
- **Harness:** the `## Harness` section verbatim
- **Project conventions:** Key points from CLAUDE.md (tech stack, naming, patterns)
- **Completed phases:** One-line collapsed summaries only (NOT full task lists)
- **Relevant doc excerpts:** Only the sections of architecture/design docs relevant to this task
- **Dependency outputs:** Brief description of what the dependency tasks produced

`@validator` receives only the task line, its `probe:` clauses, the Harness, the worktree, a port, the evidence path, the base ref, and the Before checkout. Nothing from the executor.

This keeps agent context lean. Do NOT send the entire ROADMAP.md or full doc contents to each agent.

## Morning Summary

At the end of a run — whether all phases complete or execution halts — write `auto-roadmap-summary.md` in the project root:

```markdown
# Auto-Execute Roadmap — Summary

**Run date:** {date}
**Status:** {COMPLETE | HALTED — reason}
**Phases completed:** {N of M}
**Tasks completed (validated):** {X of Y}

## Start here: evidence
Evidence is local and gitignored, under `.vibecoding/evidence/`.
- Milestone Phase 2 journey: PASS — `.vibecoding/evidence/phase-2/` (after-*.png)
- #5 PASS `evidence/5/` · #6 PASS `evidence/6/` · #8 PASS `evidence/8/`

## Phases

### Phase 1 — {status}
- Validated: #1, #2, #3
- Skipped/failed: none

### Phase 2 — {status}
- Validated: #5, #6
- Harness inserted: #23 (expose cart total via debug bridge) for #10
- Skipped: #7 (BLOCKED: waiting on API creds)
- Failed: #9 (validator FAIL after retry — badge shows "1" after adding 2 items; evidence/9/)

## Harness gaps found
- #23 cart total only rendered to canvas → added getState().cart.total
- {any gap that triggered a halt}

## Promote-to-rule candidates (from phase reviewer — your call)
- "Services must not read process.env directly" → lint with message "inject config via Config layer (docs/architecture.md#layers)"

## Blocked Tasks (need human action)
- #7: waiting on external API credentials
- #14: depends on #7

## Failed Tasks (need investigation)
- #9: validator repro: 1. open / 2. add item twice 3. badge shows "1" — evidence/9/

## Spec Problems
- #12: probe requires offline mode, which docs/spec.md says is out of scope

## Re-plan Flags (discoveries during execution)
- Phase 4 task #18 may need scope adjustment — auth middleware shape differs from roadmap assumption

## Next Steps
- Review milestone evidence
- Resolve blocked tasks / spec problems and re-run
- Decide on promote-to-rule candidates
```

Commit `auto-roadmap-summary.md` and push.

## Roadmap Format Reference

The skill expects `ROADMAP.md` in the format produced by `generate-roadmap`:

```markdown
## Harness
- Build: `...`   Test: `...`   Lint: `...`   Invariants: `...`
- Boot: `... --port $PORT`   Ready: GET http://localhost:$PORT/healthz → 200
- Driver: browser   Observe: window.__debug.getState()   Reach: ?scenario=<name>

## Phase N — DONE
Built: ... Patterns: ... Harness: ... Key files: ... (X/X tasks validated)

## Phase M — MILESTONE: description
JOURNEY: end-to-end flow the validator drives at phase end
- TODO [P0] [M] #id: Task description — depends: #x ✓, #y — scope: path/
  AC: cmd: test passes for path/
      probe: action → observable result
      invariant: Invariants clean
```

## Common Mistakes

- **Asking the user anything:** This skill is fully autonomous. NEVER use AskUserQuestion or pause for input. Every decision point has a defined autonomous policy above, milestones included.
- **Marking DONE without a validator PASS:** the overnight run's output is only trustworthy because every task was independently driven. No PASS, no DONE.
- **Passing the executor's report to the validator:** independence is the point. The validator gets the probe clauses and the harness, nothing else.
- **Retrying a harness gap:** `CANNOT_VALIDATE` means insert a `[HARNESS]` task. A retry won't change the outcome.
- **Rewriting ACs to get a PASS:** never weaken a probe overnight. If an AC is wrong, it's a spec problem: skip and flag.
- **Auto-applying promote-to-rule candidates:** those encode human taste. List them in the summary and let the user decide.
- **Validating after merge / evidence inside the worktree / port collisions:** validate in the worktree, write evidence to the main repo's `.vibecoding/evidence/`, and give each instance its own port pair.
- **Not pushing after phases:** Every passed integration check (and milestone journey) must be followed by `git push origin main`. This is how progress is preserved across session boundaries.
- **Not writing the morning summary:** Always write `auto-roadmap-summary.md` on halt or completion. It's the user's main way to understand what happened overnight. Lead with the evidence index.
- **Attempting re-plans:** Do not re-plan or re-generate the roadmap autonomously. Log discoveries and continue. The user will review in the morning.
- **Endless retries:** Max 1 implementation retry per task, max 3 harness insertions per phase. The halt conditions prevent runaway loops.
- **Sending too much context to agents:** Only send relevant doc sections and collapsed phase summaries, not everything.
- **Skipping the roadmap update:** The collapsed phase summaries are critical for context management in later phases. Always update.
- **Skipping integration checks:** Individual tasks may work in isolation but break together. Always run integration after completing a phase.
- **Referencing skills in agent prompts:** Dispatched agents don't have access to the Skill tool. Inline all instructions directly in the agent prompt.
- **Skipping SPIKE research:** If a task is flagged `[SPIKE]`, don't jump straight to implementation. Run the research agent first.
- **Parallel dispatch with overlapping scopes:** Never dispatch tasks in parallel if their `scope:` values overlap. This causes merge conflicts. Fall back to sequential.
- **Forgetting to call ExitWorktree:** After merging a worktree branch (or after a failed task is abandoned), always call `ExitWorktree`. Skipping this leaves stale worktrees on disk.
- **Losing architectural context in collapsed summaries:** When collapsing a phase, include key decisions, patterns, and harness hooks, not just "what was built."
- **Hardcoding build commands:** Always use the commands from the `## Harness` section in ROADMAP.md.
- **Not verifying dependencies between phases:** Re-run AC checks for dependency tasks at the start of each new phase.
- **Dispatching BLOCKED tasks:** Never dispatch an agent for a `[BLOCKED]` task. Skip and log.
- **Not initializing or appending to the log:** Always append to `auto-roadmap.log`, never overwrite. Multiple sessions should accumulate in the same log file.
- **Forgetting the counters:** Track consecutive failures (reset on any validated success, halt at 3) and harness insertions per phase (halt at 3).
