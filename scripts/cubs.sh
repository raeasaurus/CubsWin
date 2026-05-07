#!/usr/bin/env bash
# CubsWin agent helpers. Subcommands:
#   today_game           -> JSON {gamePk, gameDate, status, opponent, homeAway} or "null"
#   live_feed <gamePk>   -> raw live feed JSON
#   highlights <gamePk> [filter] -> JSON array of {headline, description, url}
#   today_status         -> short human line for the SessionStart hook (or empty if no game)
#   tick                 -> per-loop driver. stdout is what /cubs-update prints.
#
# All curl calls hit https://statsapi.mlb.com (free, no auth).

set -euo pipefail

CUBS_TEAM_ID=112
SPORT_ID=1
API_BASE="https://statsapi.mlb.com/api"
STATE_FILE_DEFAULT="state/cubs-game.json"
STATE_FILE="${CUBS_STATE_FILE:-$STATE_FILE_DEFAULT}"

# ---- low-level helpers ------------------------------------------------------

today_local() {
  # Cubs are Central Time; use America/Chicago so the schedule lookup matches
  # the day a fan would call "today" even if the host is on UTC.
  TZ="America/Chicago" date +%Y-%m-%d
}

curl_json() {
  curl -fsSL --max-time 10 "$1"
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
  curl_json "$API_BASE/v1.1/game/$gamePk/feed/live"
}

cmd_highlights() {
  local gamePk="${1:?usage: highlights <gamePk> [filter]}"
  local filter="${2:-}"
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
  if [[ -f "$STATE_FILE" ]]; then cat "$STATE_FILE"; else echo '{}'; fi
}

write_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n' "$1" > "$STATE_FILE"
}

cmd_tick() {
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

      # New completed plays since last tick
      local newPlays
      newPlays="$(echo "$feed" | jq -c --argjson last "$lastIdx" '
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
        ]
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
