#!/bin/bash
# vibecoding subagent statusline — shows ROADMAP.md progress.
# Prints nothing when no ROADMAP.md is present in the project root,
# so the bar is silent outside vibecoding-managed projects.

set -euo pipefail

ROADMAP="ROADMAP.md"
[[ -f "$ROADMAP" ]] || exit 0

# Total checked vs unchecked task-level checkboxes across the whole roadmap.
# Tasks live under "## Phase N" headings as "- TODO" / "- DONE" / "- IN PROGRESS".
TOTAL=$(grep -cE '^- (TODO|DONE|IN PROGRESS)' "$ROADMAP" || true)
DONE=$(grep -cE '^- DONE' "$ROADMAP" || true)
IN_PROGRESS=$(grep -cE '^- IN PROGRESS' "$ROADMAP" || true)

# Phase accounting: count phases and find the first non-DONE phase.
PHASE_TOTAL=$(grep -cE '^## Phase ' "$ROADMAP" || true)
CURRENT_PHASE_LINE=$(grep -nE '^## Phase ' "$ROADMAP" | grep -vE 'DONE$' | head -1 || true)

if [[ -n "$CURRENT_PHASE_LINE" ]]; then
  # Extract "Phase N" from e.g. "42:## Phase 3 — MILESTONE: Backend API"
  CURRENT_PHASE=$(echo "$CURRENT_PHASE_LINE" | sed -E 's/^[0-9]+:## (Phase [0-9]+).*/\1/')
  CURRENT_NUM=$(echo "$CURRENT_PHASE" | sed -E 's/Phase //')
else
  CURRENT_PHASE="all phases"
  CURRENT_NUM="$PHASE_TOTAL"
fi

# Guard against zero totals
if [[ "$TOTAL" -eq 0 ]]; then
  echo "vibecoding ▸ ROADMAP.md present but empty"
  exit 0
fi

STATUS="vibecoding ▸ ${CURRENT_PHASE}/${PHASE_TOTAL} ▸ ${DONE}/${TOTAL} tasks done"
if [[ "$IN_PROGRESS" -gt 0 ]]; then
  STATUS="${STATUS} ▸ ${IN_PROGRESS} in progress"
fi

echo "$STATUS"
