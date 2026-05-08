---
description: List video highlight clips for a tracked team (or most recent final)
argument-hint: "[team] [filter]"
allowed-tools: Bash(bash scripts/sports.sh highlights:*), Bash(jq:*)
---

Run `bash scripts/sports.sh highlights $ARGUMENTS`.

The helper returns either a JSON array of clip objects (`{headline, description, url}`)
or a plain-text "no game found" line.

If JSON: pretty-print up to 10 entries as `- {headline} → {url}`.
If plain text: print it verbatim.

For NFL games the array typically contains a single recap-page link rather
than an mp4 — that's expected (NFL clips are licensed and usually not
embeddable).
