# CubsWin agent

A small Claude Code project that watches your favorite teams during their
games and posts short summaries of recent activity in your session every few
minutes. On-demand video highlights are available via a separate command.

Out of the box it tracks five teams (Cubs, Bears, Blackhawks, Avalanche,
Spurs), but every team in the NFL/NBA/NHL/MLB is in the catalog and can be
selected ad-hoc or promoted to the defaults.

It uses two free public APIs — no keys required:
- [MLB Stats API](https://statsapi.mlb.com/) for the Cubs (and any other MLB team)
- [ESPN site API](https://site.api.espn.com/) for the NFL, NBA, and NHL

## What's in here

```
config/team-catalog.json               every NFL/NBA/NHL/MLB team + API ids
config/teams.json                      your default tracked teams
scripts/cubs.sh                        MLB Stats API helper (curl + jq)
scripts/espn.sh                        ESPN API helper (NFL/NBA/NHL)
scripts/sports.sh                      orchestrator: resolve, tick, watch, highlights
scripts/build-catalog.sh               regenerates team-catalog.json from live APIs
state/games.json                       gitignored; remembers last reported play per team
.claude/commands/sports-update.md      per-tick slash command (any team)
.claude/commands/sports-highlights.md  on-demand highlights (any team)
.claude/commands/sports-watch.md       promote a team to defaults
.claude/commands/sports-unwatch.md     demote a team from defaults
.claude/commands/cubs-update.md        thin alias for /sports-update cubs
.claude/commands/cubs-highlights.md    thin alias for /sports-highlights cubs
.claude/hooks/sports-session-start.sh  auto-detects game days, prompts the loop
.claude/settings.json                  registers the hook + permission allowlist
```

## Setup

Open this folder as your Claude Code project (`cd cubswin-agent && claude`).
On a game day for any of your defaults, the SessionStart hook tells Claude
which teams are playing and suggests starting the loop. On non-game days the
hook is silent.

Requires `bash`, `curl`, and `jq` on your PATH.

The shipped `config/team-catalog.json` is a hand-curated baseline — IDs for
recent NHL expansion teams (Seattle Kraken, Utah HC) may need to be refreshed
against live data. Run `bash scripts/build-catalog.sh` once locally to
regenerate the catalog from the live league APIs.

## Commands

| Command | What it does |
| --- | --- |
| `/sports-update` | Ticks every default team; silent for teams without a game today. |
| `/sports-update <team>...` | Ticks only the named teams. Names are case-insensitive and accept abbreviations (`CHI`, `LAC`), city + nickname (`Chicago Bulls`), or any alias listed in the catalog (`avs`, `niners`, `cards`). |
| `/loop 3m /sports-update` | The intended way to use the agent during games. Repeats every 3 minutes. Stop with the loop skill's stop command. |
| `/sports-highlights [team] [filter]` | Lists video clips for a team's active or most recent game. Up to 10 entries. NFL games typically return a recap-page link rather than mp4s (licensing). |
| `/sports-watch <team>` | Adds a team to your defaults (idempotent). |
| `/sports-unwatch <team>` | Removes a team from your defaults. |
| `/cubs-update`, `/cubs-highlights` | Aliases for `/sports-update cubs` and `/sports-highlights cubs`. |

## How it stays quiet when nothing happens

- **No tracked team plays today** → all commands silent; the loop is safe to
  leave running.
- **Pre-game** → prints kickoff/first-pitch time once per team per day.
- **Mid-game, nothing new since last tick** → prints a short alive-ping
  (period/inning, clock, score).
- **Final** → prints the score, clears state for that team, reverts to
  "no game" on subsequent ticks.

To keep ticks readable, NFL/NBA/NHL only print **scoring plays** plus the
period/score line. MLB prints every completed plate appearance (the data is
much terser). NBA games would otherwise produce hundreds of lines per tick.

## Direct helper usage (debugging)

```sh
bash scripts/sports.sh resolve cubs                # catalog lookup
bash scripts/sports.sh defaults                    # list defaults
bash scripts/sports.sh tick                        # tick all defaults
bash scripts/sports.sh tick bulls celtics          # tick just two teams
bash scripts/sports.sh today_status                # status lines for SessionStart
bash scripts/sports.sh highlights bears            # highlights for one team
bash scripts/sports.sh watch bulls                 # promote
bash scripts/sports.sh unwatch bulls               # demote

# Per-league helpers (stable, called by sports.sh)
bash scripts/cubs.sh today_game                    # MLB schedule probe
bash scripts/cubs.sh live_feed <gamePk>            # raw MLB live feed
bash scripts/espn.sh today_game nfl 3              # ESPN scoreboard probe
bash scripts/espn.sh summary nhl <eventId>         # raw ESPN summary
```

State lives at `state/games.json`, keyed by `<league>:<teamId>`. Delete it
to force a fresh re-detection on the next tick.

## Security checks

Two layers run automatically in CI (see `.github/workflows/security.yml`)
and can be run locally:

```sh
shellcheck -f gcc -x scripts/*.sh tests/*.sh .claude/hooks/*.sh
bash tests/security.sh
```

`tests/security.sh` probes for shell injection, command substitution,
path traversal in `STATE_FILE` env vars, and corrupt-state recovery
(22 cases). The helpers reject any team name, id, or filter that contains
shell metacharacters; state-file env overrides must be project-relative.

## Adding a team

Three options, in order of effort:

1. **One-off** — `/sports-update <team>`. Resolves against the full catalog;
   no config change.
2. **Promote** — `/sports-watch <team>`. Adds to `config/teams.json` so
   `/sports-update` (no args) and the SessionStart hook also pick it up.
3. **Edit** — open `config/teams.json` and append `{name, league, id}`. Use
   the catalog to find the league + id, or run `bash scripts/sports.sh
   resolve <name>`.
