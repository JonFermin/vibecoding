---
name: auto-execute-roadmap
description: Use when the user asks to execute a ROADMAP.md headless/overnight — runs autonomously with no user interaction, auto-decides at all checkpoints, commits and pushes at every milestone
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

All autonomous decisions are logged to `auto-roadmap.log`. At the end of the run (or on halt), a `auto-roadmap-summary.md` is written for morning review.

## Reusable Agents

Dispatch the same named agents as `execute-roadmap` (defined in `${CLAUDE_PLUGIN_ROOT}/agents/`):

- `@phase-executor` — implements a single task (one per task in parallel mode).
- `@spike-researcher` — investigates `[SPIKE]` tasks and returns a refined scope. Auto-proceed with its recommendation.
- `@ac-verifier` — runs Build/Test/Lint (and optional Dev) and returns per-command pass/fail. Use for per-task AC and phase integration checks — this keeps the main session's tool count low across a long overnight run.
- `@phase-reviewer` — diff-based quality review between integration check and next phase (only if `runPhaseReviewer` is enabled; findings are logged but do not halt execution).

## Plugin Options (read at runtime)

Honor these env vars (set by Claude Code from `plugin.json` `userConfig`), falling back to defaults if unset:

- `CLAUDE_PLUGIN_OPTION_PARALLELAGENTLIMIT` (default `4`) — cap on concurrent phase-executors.
- `CLAUDE_PLUGIN_OPTION_DEFAULTEFFORT` (default `medium`) — effort passed to dispatched agents. `xhigh` requires Opus 4.7.
- `CLAUDE_PLUGIN_OPTION_WORKTREEPARENTDIR` (default `..`) — parent directory for worktrees.
- `CLAUDE_PLUGIN_OPTION_AUTOCOMMITONACPASS` (default `true`) — when `false`, leaves staged changes for morning review instead of auto-committing.
- `CLAUDE_PLUGIN_OPTION_RUNPHASEREVIEWER` (default `true`) — whether to dispatch `@phase-reviewer` after each phase's integration check.

## When to Use

- User says "run the roadmap overnight", "headless execution", "auto-execute"
- User wants unattended, autonomous roadmap execution
- A `ROADMAP.md` exists in the project root

## Autonomous Decision Policy

| Checkpoint | Autonomous Behavior |
|---|---|
| **BLOCKED tasks** | Skip blocked tasks, log reason to `auto-roadmap.log`. Never wait for resolution. |
| **SPIKE findings** | Auto-proceed with the research agent's recommended approach. Log the recommendation. |
| **Parallel mode** | Auto-choose: use parallel if tasks have non-overlapping scopes AND phase has 2+ tasks (default). Otherwise sequential. Log the choice. |
| **AC failure** | Retry once with failure context. If retry fails, skip the task + log. Increment consecutive failure counter. |
| **Phase checkpoint** | Auto-continue after integration check passes. If integration fails, attempt fix once, then **halt**. |
| **Mid-execution re-plan** | Log the discovery, continue as-is. Flag for morning review in summary. |
| **Session break suggestion** | Auto-break: commit ROADMAP.md + push, then resume immediately. |

## Halt Conditions

**Stop execution entirely** (do not skip, do not continue) when:
1. Integration check fails after one fix attempt
2. 3 or more consecutive task failures occur (counter resets on any success)
3. No `ROADMAP.md` found in project root

On halt: write the morning summary immediately before stopping.

## Logging Format

All autonomous decisions are appended to `auto-roadmap.log` in the project root:

```
[YYYY-MM-DD HH:MM:SS] [LEVEL] message
```

Levels: `INFO`, `SKIP`, `RETRY`, `FAIL`, `HALT`, `PUSH`, `DECISION`

Examples:
```
[2026-03-15 02:14:01] [INFO] Starting Phase 2 — 5 tasks (3 parallel, 2 sequential)
[2026-03-15 02:14:02] [SKIP] Task #7 BLOCKED: waiting on external API credentials
[2026-03-15 02:15:30] [DECISION] Parallel mode chosen for Phase 2: 3 tasks with non-overlapping scopes
[2026-03-15 02:30:12] [FAIL] Task #9 AC failed: `npm test` exit code 1
[2026-03-15 02:30:13] [RETRY] Task #9 — retrying with failure context (attempt 2/2)
[2026-03-15 02:35:44] [SKIP] Task #9 — retry failed, skipping. See failure details below.
[2026-03-15 03:01:00] [PUSH] Phase 2 complete — pushed to origin/main
[2026-03-15 04:12:00] [HALT] 3 consecutive failures — stopping execution
```

## Process Flow

```
Read ROADMAP.md → Parse phases → Find first incomplete phase
  ↓
For each phase:
  ├─ Identify unblocked tasks (skip BLOCKED → log)
  ├─ Handle SPIKEs (auto-proceed with recommendation)
  ├─ Auto-choose parallel vs sequential
  ├─ Dispatch agents
  ├─ Verify AC per task
  │   ├─ Pass → mark DONE, commit
  │   └─ Fail → retry once → skip + log (check halt condition)
  ├─ Update ROADMAP.md (collapse phase if all done)
  ├─ Integration check
  │   ├─ Pass → commit, push, log → next phase
  │   └─ Fail → attempt fix once
  │       ├─ Fixed → commit, push, log → next phase
  │       └─ Still failing → HALT
  └─ Check consecutive failure counter → HALT if ≥ 3
  ↓
All phases DONE → write morning summary → log "ROADMAP COMPLETE"
```

## Step 1 — Read, Validate, and Parse

- Read `ROADMAP.md` from project root. **If it does not exist**, log `[HALT] No ROADMAP.md found` and stop. Do not proceed.
- Read `CLAUDE.md` if it exists — extract coding conventions, tech stack, standards that agents must follow.
- Read architecture/design docs referenced in the project.
- **Parse Tech Stack section:** Extract the Build, Test, Lint, and Dev commands. These are used for AC verification and integration checks throughout execution.
- **Validate format:** Check that every task has `scope:`, `AC:`, a priority, a size, and a sequential `#ID`. If any are missing, log a warning and proceed with best effort — do not halt for format issues.
- Parse phases, task statuses, dependencies.
- Identify the first phase that is not `DONE`.
- **Initialize log:** Append to `auto-roadmap.log`:
  ```
  [timestamp] [INFO] === AUTO-EXECUTE SESSION START ===
  [timestamp] [INFO] Roadmap: X phases, Y tasks total, Z already DONE
  ```
- **Initialize consecutive failure counter** to 0.

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

Order unblocked tasks within the phase: P0 first, then P1, then P2.

## Step 3 — Handle SPIKE Tasks

If a task has the `[SPIKE]` flag:

1. Dispatch the `@spike-researcher` agent with the task id, description, scope, and any open questions from the task. The agent file (`agents/spike-researcher.md`) defines the full contract.
2. **Auto-proceed:** Accept the agent's recommended approach without review.
3. Log: `[DECISION] SPIKE #N — auto-accepted recommendation: {one-line summary}`
4. Update the task description, AC, and size in ROADMAP.md based on findings.
5. Remove the `[SPIKE]` flag and proceed to dispatch the implementation agent.

## Step 4 — Mark In Progress and Dispatch Agent

Before dispatching, mark the task as `IN PROGRESS` in ROADMAP.md and commit. This enables resumability if the session is interrupted.

**Auto-choose dispatch mode:**

- **Parallel mode (default):** If the phase has 2+ unblocked tasks AND their `scope:` values do not overlap → use parallel with worktrees. Log: `[DECISION] Parallel mode chosen for Phase N: {count} tasks with non-overlapping scopes`
- **Sequential mode (fallback):** Otherwise → use sequential. Log: `[DECISION] Sequential mode for Phase N: {reason}`

#### Parallel Mode (default — worktrees)
Multiple agents run simultaneously in isolated git worktrees. Used when:
- Tasks within the phase have **non-overlapping `scope:` values**
- The phase has 2+ independent tasks

#### Sequential Mode (fallback)
One agent at a time on the working tree. Used when:
- Tasks have overlapping scopes
- The phase has only 1 task

**Parallel workflow:**
1. For each task, dispatch the `@phase-executor` agent with `isolation: "worktree"`. Cap concurrent agents at `CLAUDE_PLUGIN_OPTION_PARALLELAGENTLIMIT` (default 4) — queue any remaining tasks and dispatch them as earlier ones merge.
2. Each agent works in its own copy of the repo — no conflicts possible.
3. As each agent completes, **merge its worktree branch into main immediately** in completion order: `git merge <worktree-branch> --no-ff -m "roadmap #N: <description>"`. Do not wait for all agents to finish — merge as they arrive.
4. If a merge conflict occurs: resolve it or fall back to sequential for the conflicting task.
5. After merging, **explicitly call `ExitWorktree`** to clean up the worktree directory and branch. Do not rely on automatic cleanup — always call `ExitWorktree` after the merge completes (or if the agent fails and the worktree is no longer needed).

**`@phase-executor` input contract:**

Pass these inputs when dispatching (full contract in `agents/phase-executor.md`):

- **Task**: `#{id}: {description}`
- **Acceptance criteria**: `{AC line from roadmap}`
- **Scope**: `{scope from roadmap}`
- **Tech Stack commands**: Build / Test / Lint (and Dev if present) — verbatim from `## Tech Stack` in ROADMAP.md.
- **Project conventions**: key points from CLAUDE.md.
- **Completed dependencies**: `depends:` ids + one-line description of what each produced.
- **Phase context**: collapsed summaries of prior completed phases.
- **Task type hint**: `infra` | `ui` | `api` | `test` | omit for general.
- **Effort**: set to `CLAUDE_PLUGIN_OPTION_DEFAULTEFFORT` (default `medium`; `xhigh` on Opus 4.7 for large/risky tasks).

For tasks sized `[L]`, also instruct the executor to commit intermediate progress with messages like `roadmap #{id} (wip): {what was completed}` so overnight session interruptions don't lose work.

**Dispatch rules:**
- Prioritize P0 tasks first within each phase
- Tightly coupled tasks (e.g., a component and its direct wiring) → group into one agent
- In parallel mode, dispatch all independent tasks simultaneously, then merge each as it completes
- In sequential mode, one agent finishes and commits before the next starts

## Step 5 — Verify Acceptance Criteria

After each agent completes:

1. **Verify AC explicitly** — dispatch the `@ac-verifier` agent with `check type: task-ac`, passing the AC line and Tech Stack commands. The agent returns per-command pass/fail. (You may run commands directly from the main session for simple single-command ACs; delegating to the verifier saves tool calls across a long run.)
2. If AC passes:
   - Merge into main (for worktree agents: `git merge <worktree-branch> --no-ff`, then call `ExitWorktree` to clean up; for sequential agents: work is already on main). If `CLAUDE_PLUGIN_OPTION_AUTOCOMMITONACPASS` is `false`, leave staged changes for morning review instead.
   - Mark task as `DONE` in ROADMAP.md.
   - **Reset consecutive failure counter to 0.**
   - Log: `[INFO] Task #N DONE ({completed}/{total} in Phase {P})`
3. If AC fails: proceed to Step 6.

## Step 6 — Handle Failures Autonomously

If an agent fails or AC verification fails:

1. **Log the failure:** `[FAIL] Task #N AC failed: {details}`
2. **Increment consecutive failure counter.**
3. **Check halt condition:** If consecutive failures ≥ 3 → write morning summary and **HALT**.
4. **Retry once** (max 1 retry per task):
   - Log: `[RETRY] Task #N — retrying with failure context (attempt 2/2)`
   - Re-dispatch agent with additional context about what went wrong.
   - If retry succeeds: mark DONE, reset failure counter, continue.
   - If retry fails:
     - Log: `[SKIP] Task #N — retry failed, skipping`
     - Mark task as `TODO` with a note: `[FAILED: {reason}]`
     - **If the agent ran in a worktree, call `ExitWorktree` to clean it up** — unattended runs must not leave stale worktrees on disk for morning review.
     - Increment consecutive failure counter again.
     - **Check halt condition again** after the retry failure.
     - Continue to next task.

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
   Built: {what was created/implemented}. Patterns: {architectural decisions, conventions established, design patterns chosen}. Key files: {important new/modified files or directories}. Skipped: {any blocked/failed tasks}. (X/Y tasks completed, Z skipped)
   ```

4. Commit the updated `ROADMAP.md` with message: `roadmap: complete phase N`

## Step 8 — Phase Completion: Integration Check and Auto-Continue

After all dispatchable tasks in a phase are complete:

1. **Integration check:** Dispatch the `@ac-verifier` agent with `check type: phase-integration`, passing the Tech Stack commands. It runs Build / Test / Lint / Dev and returns a compact per-command pass/fail report.

2. **If integration passes:**
   - Log: `[INFO] Phase {N} integration check passed`
   - **Phase review** (optional): If `CLAUDE_PLUGIN_OPTION_RUNPHASEREVIEWER` is `true`, dispatch `@phase-reviewer` with the phase number, completed task ids, and diff range. Log any `needs rework` findings — do NOT halt for them; they are surfaced in the morning summary.
   - **Push to remote:** `git push origin main`
   - Log: `[PUSH] Phase {N} complete — pushed to origin/main`
   - Auto-continue to next phase — no pause.

3. **If integration fails:**
   - Log: `[FAIL] Phase {N} integration check failed: {details}`
   - **Attempt fix once:** Diagnose the issue, apply a fix, commit.
   - Re-run integration check.
   - If fixed:
     - Log: `[INFO] Phase {N} integration fix applied`
     - Push and continue as above.
   - If still failing:
     - Log: `[HALT] Phase {N} integration check failed after fix attempt`
     - Write morning summary.
     - **HALT.**

## Step 9 — Next Phase

Return to Step 2 with the next incomplete phase. Repeat until all phases are `DONE`.

When all phases are complete:
1. Log: `[INFO] === ALL PHASES DONE — ROADMAP COMPLETE ===`
2. Push final state: `git push origin main`
3. Write morning summary.

## Session Budget Awareness

Large phases can exhaust the conversation context. To manage this:
- If a phase has more than ~8 tasks, after completing each batch of ~5 tasks, commit all ROADMAP.md updates and push. If context is getting long, the resilience loop wrapper will re-invoke and resume.
- When dispatching agents, keep prompts lean — collapsed phase summaries only, not full histories.
- If you notice the conversation is getting long, commit ROADMAP.md and push at the next natural checkpoint. The resilience loop will pick up where you left off.

## Dependency Verification Between Phases

When starting a new phase, before dispatching any tasks:
1. Identify all dependency tasks referenced by `depends:` in this phase
2. Re-run the AC checks for those dependency tasks to confirm they still pass
3. If a dependency's AC now fails, attempt to fix it (counts as one fix attempt). If unfixable, halt.

## Resumability

If a session is interrupted mid-phase (or re-invoked by the resilience loop):
1. On resume, read ROADMAP.md and look for `IN PROGRESS` tasks
2. Check git log for commits referencing those task IDs — if work was committed, mark as `DONE`
3. For tasks marked `IN PROGRESS` with no committed work, reset to `TODO`
4. Read `auto-roadmap.log` to understand what happened in previous sessions
5. **Auto-continue** from where things left off — no user prompt needed.

## Mid-Execution Re-Planning (Autonomous)

If during execution you discover that future phases are invalidated:

1. Finish the current task — don't leave work half-done.
2. Log: `[DECISION] Re-plan trigger: {what changed and which future tasks/phases are affected}`
3. **Continue as-is.** Do NOT re-plan autonomously — this risks diverging from the user's intent.
4. Add the discovery to the morning summary for human review.

## Checkpoint Commits

Commit ROADMAP.md at these moments to ensure recoverability:
- **Task start:** After marking a task `IN PROGRESS`
- **Task end:** After marking a task `DONE`
- **Phase end:** After collapsing the completed phase

These commits create a reliable audit trail.

## Agent Context Management

Each dispatched agent receives:
- **Current task(s):** Full description, scope, and AC from roadmap
- **Project conventions:** Key points from CLAUDE.md (tech stack, naming, patterns)
- **Completed phases:** One-line collapsed summaries only (NOT full task lists)
- **Relevant doc excerpts:** Only the sections of architecture/design docs relevant to this task
- **Dependency outputs:** Brief description of what the dependency tasks produced

This keeps agent context lean. Do NOT send the entire ROADMAP.md or full doc contents to each agent.

## Morning Summary

At the end of a run — whether all phases complete or execution halts — write `auto-roadmap-summary.md` in the project root:

```markdown
# Auto-Execute Roadmap — Summary

**Run date:** {date}
**Status:** {COMPLETE | HALTED — reason}
**Phases completed:** {N of M}
**Tasks completed:** {X of Y}

## Phases

### Phase 1 — {status}
- Completed tasks: #1, #2, #3
- Skipped/failed: none

### Phase 2 — {status}
- Completed tasks: #5, #6
- Skipped: #7 (BLOCKED: waiting on API creds)
- Failed: #9 (AC failed after retry — npm test exit 1)

## Blocked Tasks (need human action)
- #7: waiting on external API credentials
- #14: depends on #7

## Failed Tasks (need investigation)
- #9: AC `npm test` failed — test output: {brief excerpt}

## Re-plan Flags (discoveries during execution)
- Phase 4 task #18 may need scope adjustment — auth middleware shape differs from roadmap assumption

## Next Steps
- Resolve blocked tasks and re-run, or adjust roadmap
- Investigate failed task #9 test output
- Review re-plan flags before continuing
```

Commit `auto-roadmap-summary.md` and push.

## Roadmap Format Reference

The skill expects `ROADMAP.md` in the format produced by `generate-roadmap`:

```markdown
## Tech Stack
- Language: ...
- Framework: ...

## Phase N — DONE
Summary of completed work (X/X tasks)

## Phase M — MILESTONE: description
- TODO [P0] [M] #id: Task description — depends: #x ✓, #y — scope: path/
  AC: `command` exits 0; expected behavior observed
- IN PROGRESS [P1] [S] #id: Another task — depends: #z ✓ — scope: path/
  AC: `test command` passes
```

## Common Mistakes

- **Asking the user anything:** This skill is fully autonomous. NEVER use AskUserQuestion or pause for input. Every decision point has a defined autonomous policy above. If you find yourself wanting to ask the user, refer to the Autonomous Decision Policy table.
- **Not pushing after phases:** Every passed integration check must be followed by `git push origin main`. This is how progress is preserved across session boundaries.
- **Not writing the morning summary:** Always write `auto-roadmap-summary.md` on halt or completion. This is the user's primary way to understand what happened overnight.
- **Attempting re-plans:** Do not re-plan or re-generate the roadmap autonomously. Log discoveries and continue. The user will review in the morning.
- **Endless retries:** Max 1 retry per task. After that, skip and log. The halt condition (3 consecutive failures) prevents runaway failures.
- **Sending too much context to agents:** Only send relevant doc sections and collapsed phase summaries, not everything.
- **Not checking AC:** "Looks good" is not verification. Run the actual AC commands and check the output.
- **Skipping the roadmap update:** The collapsed phase summaries are critical for context management in later phases. Always update.
- **Skipping integration checks:** Individual tasks may work in isolation but break together. Always run a build after completing a phase.
- **Referencing skills in agent prompts:** Dispatched agents don't have access to the Skill tool. Inline all instructions directly in the agent prompt.
- **Skipping SPIKE research:** If a task is flagged `[SPIKE]`, don't jump straight to implementation. Run the research agent first.
- **Parallel dispatch with overlapping scopes:** Never dispatch tasks in parallel if their `scope:` values overlap — this causes merge conflicts. Fall back to sequential.
- **Forgetting to merge worktrees:** After parallel agents complete, merge each worktree branch into main as it completes. Don't leave orphaned worktree branches.
- **Forgetting to call ExitWorktree:** After merging a worktree branch (or after a failed agent), always call `ExitWorktree` to remove the worktree directory and its branch. Skipping this leaves stale worktrees on disk.
- **Losing architectural context in collapsed summaries:** When collapsing a phase, include key decisions and patterns — not just "what was built."
- **Hardcoding build commands:** Always use the commands from the `## Tech Stack` section in ROADMAP.md.
- **Not verifying dependencies between phases:** Re-run AC checks for dependency tasks at the start of each new phase.
- **Dispatching BLOCKED tasks:** Never dispatch an agent for a `[BLOCKED]` task. Skip and log.
- **Not initializing or appending to the log:** Always append to `auto-roadmap.log`, never overwrite. Multiple sessions should accumulate in the same log file.
- **Forgetting the consecutive failure counter:** Track consecutive failures. Reset to 0 on any success. Halt at 3.
