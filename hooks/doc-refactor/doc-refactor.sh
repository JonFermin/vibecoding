#!/bin/bash
# Doc Refactor Stop Hook
# Automatically splits CLAUDE.md H2 sections into .claude/rules/ files,
# syncs tagged sections to external docs, and deduplicates content.

set -euo pipefail

# ── Step 0: Read stdin, check loop guard ──────────────────────
HOOK_INPUT=$(cat)

# Guard: if stop_hook_active is true, this stop was triggered by a hook.
# Exit immediately to prevent infinite loops.
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

# ── Step 1: Check dependencies ────────────────────────────────
command -v jq >/dev/null 2>&1 || { echo "doc-refactor: jq required but not found" >&2; exit 0; }

# ── Step 2: Locate CLAUDE.md ─────────────────────────────────
CLAUDE_MD="CLAUDE.md"
if [[ ! -f "$CLAUDE_MD" ]]; then
  exit 0
fi

# ── Step 3: Load config ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "doc-refactor-config.json" ]]; then
  CONFIG="doc-refactor-config.json"
else
  CONFIG="${SCRIPT_DIR}/config.json"
fi

RULES_DIR=$(jq -r '.rules_dir // ".claude/rules"' "$CONFIG")
HASH_FILE=$(jq -r '.hash_file // ".claude/.doc-refactor-hash"' "$CONFIG")

# ── Step 4: SHA-256 hash check ───────────────────────────────
CURRENT_HASH=$(sha256sum "$CLAUDE_MD" | cut -d' ' -f1)

if [[ -f "$HASH_FILE" ]]; then
  STORED_HASH=$(cat "$HASH_FILE")
  if [[ "$CURRENT_HASH" == "$STORED_HASH" ]]; then
    exit 0
  fi
fi

# ── Step 5: Split H2 sections into .claude/rules/*.md ────────
mkdir -p "$RULES_DIR"

# Extract all H2 sections from CLAUDE.md into temp files
# Each section: from ## heading to next ## heading or EOF
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Parse CLAUDE.md and split by H2 headings
awk '
  /^## / {
    if (outfile) close(outfile)
    # Sanitize heading for filename: lowercase, spaces to hyphens
    heading = substr($0, 4)
    gsub(/[^a-zA-Z0-9 -]/, "", heading)
    gsub(/ +/, "-", heading)
    outfile = ENVIRON["TEMP_DIR"] "/" tolower(heading) ".section"
    # Store original heading as first line
    print substr($0, 4) > (ENVIRON["TEMP_DIR"] "/" tolower(heading) ".heading")
  }
  outfile { print > outfile }
' "$CLAUDE_MD"

# Match sections against configured patterns
NUM_RULES=$(jq '.h2_to_rules | length' "$CONFIG")
for (( i=0; i<NUM_RULES; i++ )); do
  PATTERN=$(jq -r ".h2_to_rules[$i].pattern" "$CONFIG")
  FILENAME=$(jq -r ".h2_to_rules[$i].filename" "$CONFIG")
  TARGET="$RULES_DIR/$FILENAME"

  # Check each extracted section's heading against the pattern
  for heading_file in "$TEMP_DIR"/*.heading 2>/dev/null; do
    [[ -f "$heading_file" ]] || continue
    HEADING=$(cat "$heading_file")

    if echo "$HEADING" | grep -Eq "$PATTERN"; then
      # Found a match — get the corresponding section content
      SECTION_FILE="${heading_file%.heading}.section"
      if [[ -f "$SECTION_FILE" ]]; then
        SECTION_CONTENT=$(cat "$SECTION_FILE")

        # Only write if content differs from existing file
        if [[ -f "$TARGET" ]]; then
          EXISTING=$(cat "$TARGET")
          if [[ "$SECTION_CONTENT" == "$EXISTING" ]]; then
            continue
          fi
        fi

        echo "$SECTION_CONTENT" > "$TARGET"
      fi
    fi
  done
done

# ── Step 6: Sync tagged sections to external docs ────────────
NUM_SYNCS=$(jq '.sync_targets | length' "$CONFIG")
for (( i=0; i<NUM_SYNCS; i++ )); do
  TAG=$(jq -r ".sync_targets[$i].tag" "$CONFIG")
  TARGET_FILE=$(jq -r ".sync_targets[$i].file" "$CONFIG")

  if [[ ! -f "$TARGET_FILE" ]]; then
    continue
  fi

  OPEN_MARKER="<!-- CLAUDE:${TAG} -->"
  CLOSE_MARKER="<!-- /CLAUDE:${TAG} -->"

  # Check both files have the markers
  if ! grep -qF "$OPEN_MARKER" "$CLAUDE_MD"; then
    continue
  fi
  if ! grep -qF "$OPEN_MARKER" "$TARGET_FILE"; then
    continue
  fi

  # Extract content between markers in CLAUDE.md (excluding markers themselves)
  SOURCE_CONTENT=$(awk -v open="$OPEN_MARKER" -v close="$CLOSE_MARKER" '
    BEGIN { printing=0 }
    index($0, open) { printing=1; next }
    index($0, close) { printing=0; next }
    printing { print }
  ' "$CLAUDE_MD")

  if [[ -z "$SOURCE_CONTENT" ]]; then
    continue
  fi

  # Replace content between markers in target file
  TEMP_TARGET="${TARGET_FILE}.doc-refactor.tmp"
  awk -v open="$OPEN_MARKER" -v close="$CLOSE_MARKER" -v src="$SOURCE_CONTENT" '
    BEGIN { skipping=0 }
    index($0, open) {
      print
      # Print source content
      n = split(src, lines, "\n")
      for (i=1; i<=n; i++) print lines[i]
      skipping=1
      next
    }
    index($0, close) {
      skipping=0
      print
      next
    }
    !skipping { print }
  ' "$TARGET_FILE" > "$TEMP_TARGET"

  # Only replace if content actually changed
  if ! diff -q "$TARGET_FILE" "$TEMP_TARGET" >/dev/null 2>&1; then
    mv "$TEMP_TARGET" "$TARGET_FILE"
  else
    rm -f "$TEMP_TARGET"
  fi
done

# ── Step 7: Deduplicate CLAUDE.md ─────────────────────────────
TEMP_CLAUDE="${CLAUDE_MD}.doc-refactor.tmp"

awk '
  # Track blank lines for collapsing 3+ to 2
  /^[[:space:]]*$/ {
    blank++
    if (blank <= 2) print
    next
  }

  # Non-blank line: reset blank counter
  {
    blank = 0
  }

  # Never dedup headings or marker comments
  /^#/ || /^<!-- / {
    prev = ""
    print
    next
  }

  # Remove consecutive duplicate lines
  $0 == prev { next }

  {
    prev = $0
    print
  }
' "$CLAUDE_MD" > "$TEMP_CLAUDE"

if ! diff -q "$CLAUDE_MD" "$TEMP_CLAUDE" >/dev/null 2>&1; then
  mv "$TEMP_CLAUDE" "$CLAUDE_MD"
else
  rm -f "$TEMP_CLAUDE"
fi

# ── Step 8: Update hash ──────────────────────────────────────
mkdir -p "$(dirname "$HASH_FILE")"
NEW_HASH=$(sha256sum "$CLAUDE_MD" | cut -d' ' -f1)
echo "$NEW_HASH" > "$HASH_FILE"

exit 0
