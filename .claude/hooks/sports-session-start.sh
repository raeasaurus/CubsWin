#!/usr/bin/env bash
# SessionStart hook: gather a status line for each default-tracked team
# playing today; inject as additionalContext along with a nudge to start
# /loop 3m /sports-update. Silent if no team has a game today.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"

status_block="$(bash scripts/sports.sh today_status 2>/dev/null || true)"
if [[ -z "$status_block" ]]; then
  exit 0
fi

read -r -d '' tail <<'EOF' || true

One or more tracked teams have games today. Run `/loop 3m /sports-update` to start tracking activity in this session, and `/sports-highlights [team]` to fetch video clips on demand.
EOF

context=$'\n'"$status_block"$'\n'"$tail"

jq -nc --arg c "$context" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $c
  }
}'
