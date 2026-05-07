#!/usr/bin/env bash
# SessionStart hook: on game days, inject context telling Claude to start
# /loop 3m /cubs-update. Silent on non-game days.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

status_line="$(bash scripts/cubs.sh today_status 2>/dev/null || true)"
if [[ -z "$status_line" ]]; then
  exit 0
fi

read -r -d '' tail <<'EOF' || true

A Cubs game is happening today. Run `/loop 3m /cubs-update` to start tracking activity in this session, and `/cubs-highlights` to fetch video clips on demand.
EOF

context=$'\n'"$status_line"$'\n'"$tail"

jq -nc --arg c "$context" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $c
  }
}'
