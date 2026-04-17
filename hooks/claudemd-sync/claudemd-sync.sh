#!/bin/bash
# PostToolUse hook: nudge Claude to update CLAUDE.md when project-significant files change.
# Only fires for files that signal project structure changes (new deps, new projects, config changes).
# Deliberately silent for normal code edits.

set -euo pipefail

INPUT=$(cat)

# Extract file_path without jq — match the JSON key
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"//;s/"$//')

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")
DIR=$(dirname "$FILE_PATH")

# Only trigger for project-significant files
SIGNIFICANT=false
case "$BASENAME" in
  package.json|Cargo.toml|pyproject.toml|project.godot|app.json|app.config.*|tauri.conf.json|drizzle.config.*|tsconfig.json|vite.config.*|next.config.*|expo-env.d.ts)
    SIGNIFICANT=true
    ;;
esac

# Also trigger if a new top-level project directory appears (new CLAUDE.md or package.json in a subdir)
# by checking if it's a direct child of the workspace root
WORKSPACE="$HOME/DEVELOP"
PARENT=$(dirname "$DIR")
if [[ "$PARENT" == "$WORKSPACE" || "$DIR" == "$WORKSPACE" ]]; then
  case "$BASENAME" in
    CLAUDE.md|.cursorrules)
      SIGNIFICANT=true
      ;;
  esac
fi

# Skip if the edit is to the root CLAUDE.md itself (avoid circular nudges)
if [[ "$FILE_PATH" == "$WORKSPACE/CLAUDE.md" ]]; then
  exit 0
fi

if [[ "$SIGNIFICANT" != "true" ]]; then
  exit 0
fi

# Output context for Claude — not blocking, just a nudge
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "A project-significant file was just edited. Check if CLAUDE.md needs a concise update (e.g., new project, changed stack, removed project). Do NOT add unless the change materially affects the workspace overview. Keep entries minimal."
  }
}
EOF

exit 0
