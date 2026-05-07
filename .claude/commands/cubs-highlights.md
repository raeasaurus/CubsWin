---
description: List Cubs video highlight clips for today's (or most recent) game
argument-hint: "[filter]"
allowed-tools: Bash(bash scripts/cubs.sh:*), Bash(jq:*), Read(state/cubs-game.json)
---

Goal: print a short list of Cubs video highlight links.

1. Read `state/cubs-game.json` if it exists; extract `gamePk`.
2. If no `gamePk` is cached, run `bash scripts/cubs.sh today_game` and use that
   `gamePk`. If still none, print "No Cubs game found for today." and stop.
3. Run `bash scripts/cubs.sh highlights <gamePk> $ARGUMENTS` (the filter is
   optional — leave empty if no argument was given).
4. The helper returns a JSON array. Pretty-print up to 10 items as:
   `- {headline} → {url}`
5. If the array is empty, print "No highlights available yet." (clips usually
   appear a few minutes after the play and post-game).

Do not embed the videos; just list URLs. Keep it tight — no extra commentary.
