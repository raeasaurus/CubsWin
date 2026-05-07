---
description: Print one tick of Cubs game activity (run periodically via /loop)
allowed-tools: Bash(bash scripts/cubs.sh tick)
---

Run `bash scripts/cubs.sh tick` from the repo root and print its stdout
verbatim. Do not summarize, paraphrase, or add commentary — the helper has
already formatted the output. If the helper exits non-zero, print the error
exactly as received so the loop owner can debug.
