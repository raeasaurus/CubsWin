# CubsWin agent

A small Claude Code project that watches the Chicago Cubs during a game and
posts short summaries of recent activity in your session every few minutes.
On-demand video highlights are available via a separate command.

It uses the free [MLB Stats API](https://statsapi.mlb.com/) — no key required.

## What's in here

```
scripts/cubs.sh                        the only real logic (curl + jq)
state/cubs-game.json                   gitignored; remembers last reported play
.claude/commands/cubs-update.md        per-tick slash command
.claude/commands/cubs-highlights.md    on-demand highlights command
.claude/hooks/cubs-session-start.sh    auto-detects game days, prompts the loop
.claude/settings.json                  registers the hook + permission allowlist
```

## Setup

Open this folder as your Claude Code project (`cd cubswin-agent && claude`).
That's it. The first time you open it on a Cubs game day, the SessionStart
hook tells Claude that a game is happening today and suggests starting the
loop. On non-game days the hook is silent.

Requires `bash`, `curl`, and `jq` on your PATH.

## Commands

| Command | What it does |
| --- | --- |
| `/cubs-update` | One tick: prints any plays completed since the last call. The first call of the day caches the `gamePk`; subsequent calls only print new activity. |
| `/loop 3m /cubs-update` | The intended way to use the agent during a game. Repeats every 3 minutes. Stop it with the loop skill's stop command. |
| `/cubs-highlights [filter]` | Lists video clips for the active or most recent Cubs game, e.g. `/cubs-highlights hr` to filter by headline. Prints up to 10 links. |

## How it stays quiet when nothing happens

- **No game today** → `/cubs-update` prints "No Cubs game today." once and the
  loop is safe to leave running.
- **Pre-game** → prints first-pitch time once per tick.
- **Mid-inning, no completed plate appearance since last tick** → prints a
  short alive-ping (`Cubs vs X — Bot 4, 2-3. At bat: Suzuki vs Wainwright.`).
- **Final** → prints the score once, clears state, then reverts to "no game"
  on subsequent ticks until you stop the loop.

## Direct helper usage (debugging)

```sh
bash scripts/cubs.sh today_game             # JSON or "null"
bash scripts/cubs.sh today_status           # human-readable line for the hook
bash scripts/cubs.sh live_feed <gamePk>     # raw MLB live feed JSON
bash scripts/cubs.sh highlights <gamePk> hr # filter by headline substring
bash scripts/cubs.sh tick                   # what /cubs-update would print
```

State is at `state/cubs-game.json`. Delete it to force a re-fetch on the
next tick.
