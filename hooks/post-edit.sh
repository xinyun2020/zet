#!/bin/bash
# Post-edit hook — regenerate config when a template is modified
# Attach to your AI tool's PostToolUse event for Edit/Write operations.
# Only fires when the edited file is a template.
#
# Environment:
#   EDITED_FILE — path of the file that was edited (set by your AI tool)
#   ZET_ROOT    — project root (default: current directory)

FILE_PATH="${EDITED_FILE:-${CLAUDE_FILE_PATH:-$1}}"
ZET_ROOT="${ZET_ROOT:-$(pwd)}"

# Only fire for template edits
if [[ "$FILE_PATH" == *"_prompt_template.md"* ]]; then
    ZET_BIN="$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd)"
    if [ -x "$ZET_BIN/zet" ]; then
        "$ZET_BIN/zet" generate --quiet >/dev/null 2>&1
    fi
fi

exit 0
