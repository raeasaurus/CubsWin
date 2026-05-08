---
description: Tick game activity for tracked teams (defaults from teams.json, or named teams)
argument-hint: "[team...]"
allowed-tools: Bash(bash scripts/sports.sh tick:*)
---

Run `bash scripts/sports.sh tick $ARGUMENTS` and print its stdout verbatim.
The helper is silent for teams without a game today, so output may be empty.
Do not summarize, paraphrase, or add commentary.

If the helper exits non-zero, surface the error so the loop owner can debug.
