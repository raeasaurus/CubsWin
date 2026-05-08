#!/usr/bin/env bash
# scripts/cubs.sh — MLB Stats API helper for the Cubs.
#
# Subcommands:
#   today_game           -> JSON {gamePk, gameDate, status, opponent, homeAway} or "null"
#   live_feed <gamePk>   -> raw live feed JSON
#   highlights <gamePk> [filter] -> JSON array of {headline, description, url}
#   today_status         -> short human line for the SessionStart hook (or empty if no game)
#   tick                 -> per-loop driver. stdout is what /cubs-update prints.
#
# Security posture (see scripts/_lib.sh for the full threat model):
#   - All curl calls are funnelled through safe_curl, which pins the
#     hostname to the allow-list and forces HTTPS with size + redirect caps.
#   - gamePk is validated before it reaches a URL so a hostile schedule
#     response can't smuggle path or query injection.
#   - State writes go through atomic_write (temp + rename, mode 0600) and
#     are serialised by with_lock so concurrent ticks can't tear state.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_lib.sh
. "$LIB_DIR/_lib.sh"

# Output cap so a hostile or buggy live feed can't flood the chat with
# thousands of "plays" in a single tick. ~50 plate appearances covers an
# entire 9-inning game; anything beyond that is suspicious.
MAX_PLAYS_PER_TICK=50

CUBS_TEAM_ID=112
SPORT_ID=1
API_BASE="https://statsapi.mlb.com/api"
STATE_FILE_DEFAULT="state/cubs-game.json"
STATE_FILE="${CUBS_STATE_FILE:-$STATE_FILE_DEFAULT}"
LOCK_FILE="${STATE_FILE}.lock"

# Reject env-supplied state paths that escape the project tree. Defence in
# depth: the agent typically runs in the user's account, so an attacker
# would already need shell to set this — but we'd rather refuse than write
# /etc/passwd.
if ! valid_state_path "$STATE_FILE"; then
  echo "invalid CUBS_STATE_FILE: $STATE_FILE" >&2
  exit 2
fi

# ---- low-level helpers ------------------------------------------------------

today_local() {
  # Cubs are Central Time; use America/Chicago so the schedule lookup matches
  # the day a fan would call "today" even if the host is on UTC.
  TZ="America/Chicago" date +%Y-%m-%d
}

# Thin alias kept for readability at call sites. Behaviour comes from
# safe_curl in _lib.sh; see that function for the security flags.
curl_json() {
  safe_curl "$1"
}

# Replace the only legacy validator that callers reference. The shared
# definition (valid_game_pk in _lib.sh? No — kept local for now) lives
# here because gamePk is MLB-specific.
valid_game_pk() {
  [[ "$1" =~ ^[0-9]{1,12}$ ]]
}

# ---- subcommands ------------------------------------------------------------

cmd_today_game() {
  local date
  date="$(today_local)"
  local url="$API_BASE/v1/schedule?sportId=$SPORT_ID&teamId=$CUBS_TEAM_ID&date=$date"
  local raw
  raw="$(curl_json "$url")" || { echo "null"; return 0; }

  echo "$raw" | jq -c --arg cubs "$CUBS_TEAM_ID" '
    (.dates[0].games[0] // null) as $g |
    if $g == null then null
    else
      ($g.teams.home.team.id|tostring) as $homeId |
      {
        gamePk:   $g.gamePk,
        gameDate: $g.gameDate,
        status:   $g.status.abstractGameState,
        detailedStatus: $g.status.detailedState,
        opponent: (if $homeId == $cubs then $g.teams.away.team.name else $g.teams.home.team.name end),
        homeAway: (if $homeId == $cubs then "home" else "away" end)
      }
    end
  '
}

cmd_live_feed() {
  local gamePk="${1:?usage: live_feed <gamePk>}"
  valid_game_pk "$gamePk" || { echo "invalid gamePk: $gamePk" >&2; return 2; }
  curl_json "$API_BASE/v1.1/game/$gamePk/feed/live"
}

cmd_highlights() {
  local gamePk="${1:?usage: highlights <gamePk> [filter]}"
  local filter="${2:-}"
  valid_game_pk "$gamePk" || { echo "invalid gamePk: $gamePk" >&2; return 2; }
  if [[ -n "$filter" ]] && ! valid_filter "$filter"; then
    echo "invalid filter: $filter" >&2; return 2
  fi
  local raw
  raw="$(curl_json "$API_BASE/v1/game/$gamePk/content")" || { echo "[]"; return 0; }

  echo "$raw" | jq --arg f "$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')" '
    [ .highlights.highlights.items[]? |
      {
        headline: (.headline // .title // ""),
        description: (.description // ""),
        url: (
          # Pick best mp4 <= 1800kbps, else the highest mp4 we can find.
          ([ .playbacks[]? | select(.url | test("\\.mp4$")) |
             . + { kbps: ((.name // "") | capture("(?<n>[0-9]+)K") | .n | tonumber? // 0) } ]
           | sort_by(.kbps)) as $mp4s |
          ( ($mp4s | map(select(.kbps <= 1800)) | last) // ($mp4s | last) ).url // ""
        )
      } |
      select(.url != "") |
      select($f == "" or (.headline | ascii_downcase | contains($f)))
    ]
    # Hard cap on returned clips. The downstream slash command prints
    # "up to 10" already, but capping here keeps a malicious or buggy
    # upstream from making us pipe megabytes of mp4 URLs into bash.
    | .[0:20]
  '
}

cmd_today_status() {
  local game
  game="$(cmd_today_game)"
  if [[ "$game" == "null" || -z "$game" ]]; then
    return 0
  fi
  local gamePk status opponent homeAway gameDate
  gamePk="$(echo "$game" | jq -r '.gamePk')"
  status="$(echo "$game" | jq -r '.status')"
  opponent="$(echo "$game" | jq -r '.opponent')"
  homeAway="$(echo "$game" | jq -r '.homeAway')"
  gameDate="$(echo "$game" | jq -r '.gameDate')"

  local vsAt; [[ "$homeAway" == "home" ]] && vsAt="vs" || vsAt="at"
  local localTime
  localTime="$(TZ="America/Chicago" date -d "$gameDate" "+%-I:%M %p %Z" 2>/dev/null || echo "")"

  case "$status" in
    Preview)
      printf 'Cubs %s %s today, first pitch %s.' "$vsAt" "$opponent" "$localTime"
      ;;
    Live)
      local feed inning half away home
      feed="$(cmd_live_feed "$gamePk")"
      inning="$(echo "$feed" | jq -r '.liveData.linescore.currentInning // "?"')"
      half="$(echo "$feed" | jq -r '.liveData.linescore.inningHalf // ""')"
      away="$(echo "$feed" | jq -r '.liveData.linescore.teams.away.runs // 0')"
      home="$(echo "$feed" | jq -r '.liveData.linescore.teams.home.runs // 0')"
      printf 'Cubs %s %s LIVE — %s %s, away %s home %s.' "$vsAt" "$opponent" "$half" "$inning" "$away" "$home"
      ;;
    Final)
      local feed away home
      feed="$(cmd_live_feed "$gamePk")"
      away="$(echo "$feed" | jq -r '.liveData.linescore.teams.away.runs // 0')"
      home="$(echo "$feed" | jq -r '.liveData.linescore.teams.home.runs // 0')"
      printf 'Cubs %s %s FINAL — away %s home %s.' "$vsAt" "$opponent" "$away" "$home"
      ;;
    *)
      printf 'Cubs %s %s today (%s).' "$vsAt" "$opponent" "$status"
      ;;
  esac
}

read_state() {
  # Validate as JSON; fall back to {} if file is missing or corrupt. This is
  # what makes a partially-written state file recoverable instead of fatal.
  if [[ -f "$STATE_FILE" ]] && jq -c . "$STATE_FILE" 2>/dev/null; then
    return 0
  fi
  echo '{}'
}

write_state() {
  # atomic_write writes to a sibling tmp file with mode 0600 and renames
  # into place. Concurrent readers see either the old file or the new one,
  # never a half-written one. See scripts/_lib.sh.
  atomic_write "$STATE_FILE" "$1"
}

# The actual tick body — extracted so the public entry point can wrap it
# in with_lock without affecting the rest of the script's structure.
_cmd_tick_inner() {
  local game state cachedPk cachedDate today
  today="$(today_local)"
  state="$(read_state)"
  cachedPk="$(echo "$state" | jq -r '.gamePk // empty')"
  cachedDate="$(echo "$state" | jq -r '.date // empty')"

  if [[ -z "$cachedPk" || "$cachedDate" != "$today" ]]; then
    game="$(cmd_today_game)"
    if [[ "$game" == "null" || -z "$game" ]]; then
      echo "No Cubs game today."
      write_state '{}'
      return 0
    fi
    cachedPk="$(echo "$game" | jq -r '.gamePk')"
    state="$(jq -nc --argjson g "$game" --arg d "$today" \
      '{gamePk: $g.gamePk, date: $d, opponent: $g.opponent, homeAway: $g.homeAway, lastPlayIndex: -1}')"
    write_state "$state"
  fi

  local feed status
  feed="$(cmd_live_feed "$cachedPk")"
  status="$(echo "$feed" | jq -r '.gameData.status.abstractGameState')"
  local opponent homeAway vsAt
  opponent="$(echo "$state" | jq -r '.opponent')"
  homeAway="$(echo "$state" | jq -r '.homeAway')"
  [[ "$homeAway" == "home" ]] && vsAt="vs" || vsAt="at"

  case "$status" in
    Preview)
      local gameDate localTime
      gameDate="$(echo "$feed" | jq -r '.gameData.datetime.dateTime')"
      localTime="$(TZ="America/Chicago" date -d "$gameDate" "+%-I:%M %p %Z" 2>/dev/null || echo "")"
      echo "Cubs $vsAt $opponent — first pitch $localTime."
      ;;
    Live)
      local lastIdx newIdx away home half inning
      lastIdx="$(echo "$state" | jq -r '.lastPlayIndex // -1')"
      away="$(echo "$feed" | jq -r '.liveData.linescore.teams.away.runs // 0')"
      home="$(echo "$feed" | jq -r '.liveData.linescore.teams.home.runs // 0')"
      half="$(echo "$feed" | jq -r '.liveData.linescore.inningHalf // ""')"
      inning="$(echo "$feed" | jq -r '.liveData.linescore.currentInning // 0')"

      # New completed plays since last tick. Capped at MAX_PLAYS_PER_TICK
      # so a hostile or replay-bug feed can't flood the chat — a real game
      # produces ~50 plate appearances total, so this only kicks in on
      # pathological responses.
      local newPlays
      newPlays="$(echo "$feed" | jq -c --argjson last "$lastIdx" --argjson cap "$MAX_PLAYS_PER_TICK" '
        [ .liveData.plays.allPlays[]? |
          select(.about.isComplete == true and .about.atBatIndex > $last) |
          {
            idx: .about.atBatIndex,
            half: .about.halfInning,
            inning: .about.inning,
            batter: (.matchup.batter.fullName // ""),
            event: (.result.event // ""),
            desc: (.result.description // ""),
            awayScore: (.result.awayScore // 0),
            homeScore: (.result.homeScore // 0)
          }
        ] | .[0:$cap]
      ')"

      newIdx="$(echo "$newPlays" | jq 'if length == 0 then null else (max_by(.idx).idx) end')"
      if [[ "$newIdx" == "null" || -z "$newIdx" ]]; then
        # No new plays — alive-ping line.
        local batter pitcher
        batter="$(echo "$feed" | jq -r '.liveData.plays.currentPlay.matchup.batter.fullName // ""')"
        pitcher="$(echo "$feed" | jq -r '.liveData.plays.currentPlay.matchup.pitcher.fullName // ""')"
        if [[ -n "$batter" && -n "$pitcher" ]]; then
          echo "Cubs $vsAt $opponent — $half $inning, $away-$home. At bat: $batter vs $pitcher."
        else
          echo "Cubs $vsAt $opponent — $half $inning, $away-$home."
        fi
      else
        echo "Cubs $vsAt $opponent — $half $inning, $away-$home"
        echo "$newPlays" | jq -r '.[] |
          "  \(.half[0:3]) \(.inning): \(.batter) — \(.event). (\(.awayScore)-\(.homeScore))"'
        state="$(echo "$state" | jq -c --argjson i "$newIdx" '.lastPlayIndex = $i')"
        write_state "$state"
      fi
      ;;
    Final)
      local away home
      away="$(echo "$feed" | jq -r '.liveData.linescore.teams.away.runs // 0')"
      home="$(echo "$feed" | jq -r '.liveData.linescore.teams.home.runs // 0')"
      echo "FINAL: Cubs $vsAt $opponent — away $away, home $home. Run /cubs-highlights for clips."
      write_state '{}'
      ;;
    *)
      echo "Cubs $vsAt $opponent — status: $status"
      ;;
  esac
}

# Public tick: serialise mutations under a per-state-file lock so two
# concurrent /cubs-update invocations can't both rewrite the play index
# and lose ground. with_lock is non-blocking — if a previous tick is
# still running, this one is silently skipped.
cmd_tick() {
  with_lock "$LOCK_FILE" _cmd_tick_inner "$@"
}

# ---- dispatch ---------------------------------------------------------------

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    today_game)    cmd_today_game "$@" ;;
    live_feed)     cmd_live_feed "$@" ;;
    highlights)    cmd_highlights "$@" ;;
    today_status)  cmd_today_status "$@" ;;
    tick)          cmd_tick "$@" ;;
    ""|-h|--help|help)
      sed -n '2,9p' "$0"
      ;;
    *)
      echo "unknown subcommand: $cmd" >&2
      exit 2
      ;;
  esac
}

main "$@"
