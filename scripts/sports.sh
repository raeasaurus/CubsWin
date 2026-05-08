#!/usr/bin/env bash
# scripts/sports.sh — orchestrator that dispatches per-league helpers.
#
# Subcommands:
#   resolve <name>                   -> {league, id, name} or non-zero
#   tick [team...]                   -> tick all defaults, or only the named teams
#   today_status [team...]           -> human-readable status lines (one per playing team)
#   highlights [team] [filter]       -> highlights for a team (defaults to most-recent-final)
#   watch <team>                     -> add team to defaults (idempotent)
#   unwatch <team>                   -> remove team from defaults
#   defaults                         -> print current defaults
#
# Dispatches MLB to scripts/cubs.sh and NFL/NBA/NHL to scripts/espn.sh.
#
# Security posture (full threat model in scripts/_lib.sh):
#   - Every team name passed in by the user is checked against
#     valid_team_name BEFORE it touches jq, awk, or shell. The catalog is
#     re-validated on first read via assert_catalog_sane so a tampered
#     team-catalog.json can't escalate (e.g. by injecting a non-numeric id).
#   - The orchestrator never builds URLs itself; URL construction lives in
#     cubs.sh / espn.sh, both of which go through safe_curl.
#   - State writes (config/teams.json, state/games.json) are atomic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=scripts/_lib.sh
. "$SCRIPT_DIR/scripts/_lib.sh"

CATALOG="config/team-catalog.json"
TEAMS="config/teams.json"

# Validate the catalog the first time we touch it. This runs lazily so
# subcommands that don't need the catalog (e.g. `defaults`) stay fast.
_catalog_validated=0
ensure_catalog_sane() {
  if (( _catalog_validated == 0 )); then
    if ! assert_catalog_sane "$CATALOG"; then
      echo "config/team-catalog.json failed integrity check" >&2
      echo "(run scripts/build-catalog.sh to regenerate)" >&2
      exit 2
    fi
    _catalog_validated=1
  fi
}

cmd_resolve() {
  local name="${1:?usage: resolve <name>}"
  # Reject anything that isn't an alphanumeric-flavoured short string. The
  # tightened regex (require at least one alphanumeric, see _lib.sh)
  # blocks all-punctuation inputs like "; ;" that would otherwise match
  # a length+character-set check.
  if ! valid_team_name "$name"; then
    echo "invalid team name: $name" >&2
    return 2
  fi
  ensure_catalog_sane
  local q; q="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  jq -e --arg q "$q" '
    [
      ((.mlb // [])[] | . + {league:"mlb"}),
      ((.nfl // [])[] | . + {league:"nfl"}),
      ((.nba // [])[] | . + {league:"nba"}),
      ((.nhl // [])[] | . + {league:"nhl"})
    ]
    | map(select(
        ((.name | ascii_downcase) == $q) or
        ((.abbrev | ascii_downcase) == $q) or
        ((.aliases // []) | map(ascii_downcase) | index($q) != null)
      ))
    | if length == 0 then null else .[0] | { league, id, name } end
  ' "$CATALOG"
}

# Resolve a team name to {league, id, name}; print error and exit non-zero on miss.
resolve_or_die() {
  local r
  if r="$(cmd_resolve "$1")"; then
    printf '%s' "$r"
  else
    echo "unknown team: $1" >&2
    return 2
  fi
}

# Build the team list to operate on:
#   - no args        -> defaults from teams.json
#   - one+ args      -> resolved teams, one per arg
team_list() {
  if [[ $# -eq 0 ]]; then
    jq -c '[ .defaults[] | { league, id, name } ]' "$TEAMS"
  else
    local arr='[]'
    local t r
    for t in "$@"; do
      r="$(resolve_or_die "$t")" || return $?
      arr="$(jq -nc --argjson a "$arr" --argjson r "$r" '$a + [$r]')"
    done
    printf '%s' "$arr"
  fi
}

dispatch_tick() {
  local league="$1" id="$2"
  case "$league" in
    mlb) bash scripts/cubs.sh tick ;;
    nfl|nba|nhl) bash scripts/espn.sh tick "$league" "$id" ;;
    *) echo "unknown league: $league" >&2; return 2 ;;
  esac
}

dispatch_status() {
  local league="$1" id="$2"
  case "$league" in
    mlb) bash scripts/cubs.sh today_status ;;
    nfl|nba|nhl) bash scripts/espn.sh today_status "$league" "$id" ;;
    *) return 2 ;;
  esac
}

cmd_tick() {
  local list; list="$(team_list "$@")" || return $?
  local n; n="$(echo "$list" | jq 'length')"
  local i=0
  while (( i < n )); do
    local league id
    league="$(echo "$list" | jq -r ".[$i].league")"
    id="$(echo "$list" | jq -r ".[$i].id")"
    dispatch_tick "$league" "$id" || true
    i=$((i+1))
  done
}

cmd_today_status() {
  local list; list="$(team_list "$@")" || return $?
  local n; n="$(echo "$list" | jq 'length')"
  local i=0
  while (( i < n )); do
    local league id line
    league="$(echo "$list" | jq -r ".[$i].league")"
    id="$(echo "$list" | jq -r ".[$i].id")"
    line="$(dispatch_status "$league" "$id" 2>/dev/null || true)"
    [[ -n "$line" ]] && echo "$line"
    i=$((i+1))
  done
}

cmd_highlights() {
  local team="${1:-}"
  local filter="${2:-}"
  if [[ -n "$filter" ]] && ! valid_filter "$filter"; then
    echo "invalid filter: $filter" >&2
    return 2
  fi
  if [[ -z "$team" ]]; then
    # No team given: pick the most-recent-final game from current state.
    local key
    key="$(jq -r 'to_entries | map(select(.value.lastFinal // false)) | sort_by(.value.finalAt // .value.date) | last | .key // empty' state/games.json 2>/dev/null || true)"
    if [[ -z "$key" ]]; then
      echo "No team specified and no recent final game in state. Try '/sports-highlights cubs'."
      return 0
    fi
    local league id
    league="${key%%:*}"
    id="${key##*:}"
    dispatch_highlights_by_state "$league" "$id" "$filter"
    return $?
  fi

  local r league id
  r="$(resolve_or_die "$team")" || return $?
  league="$(echo "$r" | jq -r .league)"
  id="$(echo "$r" | jq -r .id)"
  dispatch_highlights_by_state "$league" "$id" "$filter"
}

dispatch_highlights_by_state() {
  local league="$1" id="$2" filter="${3:-}"
  case "$league" in
    mlb)
      # cubs.sh expects gamePk; resolve from state or today's schedule.
      local gamePk
      gamePk="$(jq -r --arg k "mlb:$id" '.[$k].gamePk // empty' state/games.json 2>/dev/null || true)"
      if [[ -z "$gamePk" ]]; then
        gamePk="$(bash scripts/cubs.sh today_game | jq -r '.gamePk // empty')"
      fi
      if [[ -z "$gamePk" ]]; then echo "No MLB game found."; return 0; fi
      bash scripts/cubs.sh highlights "$gamePk" "$filter"
      ;;
    nfl|nba|nhl)
      local eventId
      eventId="$(jq -r --arg k "$league:$id" '.[$k].eventId // empty' state/games.json 2>/dev/null || true)"
      if [[ -z "$eventId" ]]; then
        eventId="$(bash scripts/espn.sh today_game "$league" "$id" | jq -r '.eventId // empty')"
      fi
      if [[ -z "$eventId" ]]; then echo "No $league game found."; return 0; fi
      bash scripts/espn.sh highlights "$league" "$eventId" "$filter"
      ;;
    *) return 2 ;;
  esac
}

cmd_watch() {
  local r; r="$(resolve_or_die "$1")" || return $?
  local league id name
  league="$(echo "$r" | jq -r .league)"
  id="$(echo "$r" | jq -r .id)"
  name="$(echo "$r" | jq -r .name)"
  local short
  short="$(echo "$name" | awk '{print $NF}')"

  local updated
  updated="$(jq --arg l "$league" --argjson id "$id" --arg n "$short" \
    '.defaults |= (if any(.[]; .league == $l and .id == $id) then . else . + [{ name: $n, league: $l, id: $id }] end)' \
    "$TEAMS")"
  atomic_write "$TEAMS" "$updated"
  echo "Defaults:"
  echo "$updated" | jq -r '.defaults[] | "  - \(.name) (\(.league))"'
}

cmd_unwatch() {
  local r; r="$(resolve_or_die "$1")" || return $?
  local league id
  league="$(echo "$r" | jq -r .league)"
  id="$(echo "$r" | jq -r .id)"

  local updated
  updated="$(jq --arg l "$league" --argjson id "$id" \
    '.defaults |= map(select(.league != $l or .id != $id))' \
    "$TEAMS")"
  atomic_write "$TEAMS" "$updated"
  echo "Defaults:"
  echo "$updated" | jq -r '.defaults[] | "  - \(.name) (\(.league))"'
}

cmd_defaults() {
  jq -r '.defaults[] | "  - \(.name) (\(.league))"' "$TEAMS"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    resolve)      cmd_resolve "$@" ;;
    tick)         cmd_tick "$@" ;;
    today_status) cmd_today_status "$@" ;;
    highlights)   cmd_highlights "$@" ;;
    watch)        cmd_watch "$@" ;;
    unwatch)      cmd_unwatch "$@" ;;
    defaults)     cmd_defaults ;;
    ""|-h|--help|help) sed -n '2,11p' "$0" ;;
    *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
  esac
}
main "$@"
