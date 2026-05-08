#!/usr/bin/env bash
# scripts/espn.sh — ESPN public site API helper for NFL/NBA/NHL.
#
# Subcommands:
#   today_game <league> <teamId>             -> {eventId, gameDate, status, opponent, homeAway} or "null"
#   summary    <league> <eventId>            -> raw summary JSON
#   highlights <league> <eventId> [filter]   -> JSON array of {headline, description, url}
#   tick       <league> <teamId>             -> per-tick driver. stdout is what callers print.
#   today_status <league> <teamId>           -> short human line for SessionStart hook
#
# All endpoints are under https://site.api.espn.com — free, no auth, but
# undocumented. ESPN's response shape has been stable across years; if it
# changes we degrade gracefully (silent on parse failure rather than crash).
#
# Security posture (full threat model in scripts/_lib.sh):
#   - safe_curl pins the hostname allow-list, forces HTTPS+TLS1.2, caps
#     redirects, and enforces a 5 MB response ceiling.
#   - Every league/teamId/eventId is validated against a strict allow-list
#     before being interpolated into a URL or jq filter.
#   - State writes are atomic (temp + rename, mode 0600) and serialised
#     by with_lock to avoid races between concurrent ticks.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_lib.sh
. "$LIB_DIR/_lib.sh"

# Caps on the per-tick output. Real NHL/NFL/NBA games produce far fewer
# scoring plays than these limits, so the only time they kick in is when
# something has gone wrong upstream.
MAX_PLAYS_PER_TICK=50
MAX_HIGHLIGHTS=20

API_BASE="https://site.api.espn.com/apis/site/v2/sports"
STATE_FILE="${SPORTS_STATE_FILE:-state/games.json}"
LOCK_FILE="${STATE_FILE}.lock"

if ! valid_state_path "$STATE_FILE"; then
  echo "invalid SPORTS_STATE_FILE: $STATE_FILE" >&2
  exit 2
fi

# Map a league key to ESPN's URL path fragment. Hard-coded whitelist; any
# other value fails closed with a descriptive error.
sport_path() {
  case "$1" in
    nfl) echo "football/nfl" ;;
    nba) echo "basketball/nba" ;;
    nhl) echo "hockey/nhl" ;;
    *) echo "unsupported league: $1" >&2; return 2 ;;
  esac
}

# Lowercase->uppercase that's locale-safe (avoids tr a-z A-Z which mishandles
# accented letters in some locales — flagged by shellcheck SC2018/SC2019).
upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# All HTTP fetches go through safe_curl; this alias keeps call sites
# readable. Failures (non-2xx, oversize, hostname violation) return non-zero
# with no stderr output — callers branch on that.
curl_json() {
  safe_curl "$1"
}

# Iterate all events on the scoreboard and pick the one involving teamId.
cmd_today_game() {
  local league="${1:?usage: today_game <league> <teamId>}"
  local teamId="${2:?usage: today_game <league> <teamId>}"
  valid_id "$teamId" || { echo "invalid teamId: $teamId" >&2; return 2; }
  local sp; sp="$(sport_path "$league")"
  local raw
  raw="$(curl_json "$API_BASE/$sp/scoreboard")" || { echo "null"; return 0; }

  echo "$raw" | jq -c --arg tid "$teamId" '
    [ .events[]? |
      . as $e |
      ($e.competitions[0].competitors[]? | select(.team.id == $tid)) as $me |
      if $me == null then empty else
        ($e.competitions[0].competitors[]? | select(.team.id != $tid)) as $opp |
        {
          eventId: $e.id,
          gameDate: $e.date,
          status: $e.status.type.state,
          detailedStatus: $e.status.type.detail,
          opponent: $opp.team.displayName,
          homeAway: $me.homeAway
        }
      end
    ] | .[0] // null
  '
}

cmd_summary() {
  local league="${1:?usage: summary <league> <eventId>}"
  local eventId="${2:?usage: summary <league> <eventId>}"
  valid_event_id "$eventId" || { echo "invalid eventId: $eventId" >&2; return 2; }
  local sp; sp="$(sport_path "$league")"
  curl_json "$API_BASE/$sp/summary?event=$eventId"
}

cmd_highlights() {
  local league="${1:?usage: highlights <league> <eventId> [filter]}"
  local eventId="${2:?usage: highlights <league> <eventId> [filter]}"
  local filter="${3:-}"
  valid_event_id "$eventId" || { echo "invalid eventId: $eventId" >&2; return 2; }
  if [[ -n "$filter" ]] && ! valid_filter "$filter"; then
    echo "invalid filter: $filter" >&2; return 2
  fi
  local sp; sp="$(sport_path "$league")"
  local raw
  raw="$(curl_json "$API_BASE/$sp/summary?event=$eventId")" || { echo "[]"; return 0; }

  # NFL summary doesn't reliably include downloadable mp4s; for that league
  # we always fall back to a recap-page link.
  if [[ "$league" == "nfl" ]]; then
    echo "$raw" | jq '
      [ (.header.links // [])[]? |
        select((.rel // []) | any(. == "summary" or . == "boxscore")) |
        { headline: (.text // "Game recap"), description: "", url: .href }
      ] | unique_by(.url) | .[0:'"$MAX_HIGHLIGHTS"']
    '
    return 0
  fi

  echo "$raw" | jq --arg f "$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')" --argjson cap "$MAX_HIGHLIGHTS" '
    [ .videos[]? |
      {
        headline: (.headline // .title // ""),
        description: (.description // ""),
        url: (
          (.links.source.HD.href // .links.source.full.href // .links.source.href //
           .links.web.href // .links.mobile.alert // "")
        )
      } |
      select(.url != "") |
      select($f == "" or (.headline | ascii_downcase | contains($f)))
    ] | .[0:$cap]
  '
}

cmd_today_status() {
  local league="${1:?usage: today_status <league> <teamId>}"
  local teamId="${2:?usage: today_status <league> <teamId>}"
  valid_id "$teamId" || { echo "invalid teamId: $teamId" >&2; return 2; }
  local game; game="$(cmd_today_game "$league" "$teamId")"
  if [[ "$game" == "null" || -z "$game" ]]; then return 0; fi

  local eventId status opponent homeAway gameDate
  eventId="$(echo "$game" | jq -r '.eventId')"
  status="$(echo "$game" | jq -r '.status')"
  opponent="$(echo "$game" | jq -r '.opponent')"
  homeAway="$(echo "$game" | jq -r '.homeAway')"
  gameDate="$(echo "$game" | jq -r '.gameDate')"

  local vsAt; [[ "$homeAway" == "home" ]] && vsAt="vs" || vsAt="at"
  local localTime
  localTime="$(date -d "$gameDate" "+%-I:%M %p %Z" 2>/dev/null || echo "")"

  case "$status" in
    pre)
      printf '%s %s %s — %s.' "$league" "$vsAt" "$opponent" "$localTime"
      ;;
    in)
      local summary period clock home away
      summary="$(cmd_summary "$league" "$eventId")"
      period="$(echo "$summary" | jq -r '.header.competitions[0].status.period // 0')"
      clock="$(echo "$summary"  | jq -r '.header.competitions[0].status.displayClock // ""')"
      away="$(echo "$summary"   | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="away") | .score] | first // "?"')"
      home="$(echo "$summary"   | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="home") | .score] | first // "?"')"
      printf '%s %s %s LIVE — P%s %s, %s-%s.' "$league" "$vsAt" "$opponent" "$period" "$clock" "$away" "$home"
      ;;
    post)
      local summary home away
      summary="$(cmd_summary "$league" "$eventId")"
      away="$(echo "$summary" | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="away") | .score] | first // "?"')"
      home="$(echo "$summary" | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="home") | .score] | first // "?"')"
      printf '%s %s %s FINAL — %s-%s.' "$league" "$vsAt" "$opponent" "$away" "$home"
      ;;
    *)
      printf '%s %s %s — %s.' "$league" "$vsAt" "$opponent" "$status"
      ;;
  esac
}

# Tick driver. State key is "<league>:<teamId>" inside state/games.json.
# The public entrypoint wraps this in with_lock; see cmd_tick at the bottom
# of the subcommand list.
_cmd_tick_inner() {
  local league="${1:?usage: tick <league> <teamId>}"
  local teamId="${2:?usage: tick <league> <teamId>}"
  valid_id "$teamId" || { echo "invalid teamId: $teamId" >&2; return 2; }
  sport_path "$league" >/dev/null
  local key="${league}:${teamId}"
  local today; today="$(date +%Y-%m-%d)"

  # Tolerate corrupted/missing state files: validate as JSON first, fall back
  # to {} if parse fails. Avoids set -e crashes on partially-written state.
  local state team_state
  if [[ -f "$STATE_FILE" ]] && state="$(jq -c . "$STATE_FILE" 2>/dev/null)"; then
    :
  else
    state='{}'
  fi
  team_state="$(echo "$state" | jq -c --arg k "$key" '.[$k] // {}')"

  local cachedId cachedDate
  cachedId="$(echo "$team_state" | jq -r '.eventId // empty')"
  cachedDate="$(echo "$team_state" | jq -r '.date // empty')"

  if [[ -z "$cachedId" || "$cachedDate" != "$today" ]]; then
    local game; game="$(cmd_today_game "$league" "$teamId")"
    if [[ "$game" == "null" || -z "$game" ]]; then
      # silent on no-game days
      return 0
    fi
    cachedId="$(echo "$game" | jq -r '.eventId')"
    team_state="$(jq -nc --argjson g "$game" --arg d "$today" \
      '{eventId: $g.eventId, date: $d, opponent: $g.opponent, homeAway: $g.homeAway, lastPlayId: ""}')"
    state="$(echo "$state" | jq -c --arg k "$key" --argjson v "$team_state" '.[$k] = $v')"
    atomic_write "$STATE_FILE" "$state"
  fi

  local summary status
  summary="$(cmd_summary "$league" "$cachedId")"
  status="$(echo "$summary" | jq -r '.header.competitions[0].status.type.state // ""')"
  local opponent homeAway vsAt
  opponent="$(echo "$team_state" | jq -r '.opponent')"
  homeAway="$(echo "$team_state" | jq -r '.homeAway')"
  [[ "$homeAway" == "home" ]] && vsAt="vs" || vsAt="at"

  case "$status" in
    pre)
      local announced; announced="$(echo "$team_state" | jq -r '.announced // false')"
      if [[ "$announced" != "true" ]]; then
        local gameDate localTime
        gameDate="$(echo "$summary" | jq -r '.header.competitions[0].date')"
        localTime="$(date -d "$gameDate" "+%-I:%M %p %Z" 2>/dev/null || echo "")"
        echo "[$(upper "$league")] ${vsAt^} $opponent — $localTime"
        team_state="$(echo "$team_state" | jq -c '.announced = true')"
        state="$(echo "$state" | jq -c --arg k "$key" --argjson v "$team_state" '.[$k] = $v')"
        atomic_write "$STATE_FILE" "$state"
      fi
      ;;
    in)
      # Score + new scoring plays since lastPlayId
      local lastId away home period clock
      lastId="$(echo "$team_state" | jq -r '.lastPlayId // ""')"
      away="$(echo "$summary" | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="away") | .score] | first // "?"')"
      home="$(echo "$summary" | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="home") | .score] | first // "?"')"
      period="$(echo "$summary" | jq -r '.header.competitions[0].status.period // 0')"
      clock="$(echo "$summary" | jq -r '.header.competitions[0].status.displayClock // ""')"

      # ESPN summary `plays` array: filter scoring + new since lastId.
      # ESPN sometimes returns scoring plays under .scoringPlays, sometimes
      # only under .plays with a scoringPlay flag — concatenate and let
      # unique_by(.id) sort it out. Output is hard-capped at
      # MAX_PLAYS_PER_TICK so a malformed feed can't flood the chat.
      local newPlays
      newPlays="$(echo "$summary" | jq -c --arg last "$lastId" --argjson cap "$MAX_PLAYS_PER_TICK" '
        ((.scoringPlays // []) + (.plays // [])) as $all |
        ([ $all[] | select(.scoringPlay == true) | { id: (.id // ""), text: (.text // ""), period: (.period.number // 0), clock: (.clock.displayValue // "") } ]
         | unique_by(.id)) as $scores |
        ( if $last == "" then $scores
          else
            ($scores | map(.id) | index($last)) as $i |
            if $i == null then $scores else $scores[($i+1):] end
          end
        ) | .[0:$cap]
      ')"

      local n; n="$(echo "$newPlays" | jq 'length')"
      if [[ "$n" == "0" ]]; then
        echo "[$(upper "$league")] ${vsAt^} $opponent — P$period $clock, $away-$home"
      else
        echo "[$(upper "$league")] ${vsAt^} $opponent — P$period $clock, $away-$home"
        echo "$newPlays" | jq -r '.[] | "  P\(.period) \(.clock): \(.text)"'
        local newLastId
        newLastId="$(echo "$newPlays" | jq -r '.[-1].id')"
        team_state="$(echo "$team_state" | jq -c --arg id "$newLastId" '.lastPlayId = $id')"
        state="$(echo "$state" | jq -c --arg k "$key" --argjson v "$team_state" '.[$k] = $v')"
        atomic_write "$STATE_FILE" "$state"
      fi
      ;;
    post)
      local away home
      away="$(echo "$summary" | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="away") | .score] | first // "?"')"
      home="$(echo "$summary" | jq -r '[.header.competitions[0].competitors[] | select(.homeAway=="home") | .score] | first // "?"')"
      echo "[$(upper "$league")] FINAL ${vsAt^} $opponent — $away-$home. /sports-highlights"
      state="$(echo "$state" | jq -c --arg k "$key" 'del(.[$k])')"
      printf '%s\n' "$state" > "$STATE_FILE"
      ;;
    *)
      echo "[$(upper "$league")] ${vsAt^} $opponent — $status"
      ;;
  esac
}

# Public tick entrypoint: serialise mutations under a per-state-file lock
# so concurrent /sports-update invocations can't both rewrite lastPlayId
# and lose the latest scoring play. See with_lock in scripts/_lib.sh.
cmd_tick() {
  with_lock "$LOCK_FILE" _cmd_tick_inner "$@"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    today_game)   cmd_today_game "$@" ;;
    summary)      cmd_summary "$@" ;;
    highlights)   cmd_highlights "$@" ;;
    today_status) cmd_today_status "$@" ;;
    tick)         cmd_tick "$@" ;;
    ""|-h|--help|help) sed -n '2,9p' "$0" ;;
    *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
  esac
}
main "$@"
