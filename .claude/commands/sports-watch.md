---
description: Promote a team to the default tracked list
argument-hint: "<team>"
allowed-tools: Bash(bash scripts/sports.sh watch:*)
---

Run `bash scripts/sports.sh watch $ARGUMENTS` and print its output verbatim.
Idempotent — running it twice for the same team is a no-op.
