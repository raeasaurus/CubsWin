---
description: List Cubs video highlight clips (alias for /sports-highlights cubs)
argument-hint: "[filter]"
allowed-tools: Bash(bash scripts/sports.sh highlights:*), Bash(jq:*)
---

Run `bash scripts/sports.sh highlights cubs $ARGUMENTS`.
Pretty-print up to 10 clips as `- {headline} → {url}`, or print "no
highlights yet" if the array is empty.
