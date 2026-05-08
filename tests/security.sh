#!/usr/bin/env bash
# Probe the CubsWin agent helpers for the obvious vulnerability classes:
# shell injection, command substitution, path traversal in env, and state
# file corruption. Each case is wrapped to assert exit code and confirm no
# side effect occurred (e.g. no unexpected file created).
#
# Run from repo root:  bash tests/security.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

PASS=0
FAIL=0
FAILED_CASES=()
CANARY="$(mktemp -u)"

assert_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $desc — expected non-zero, got success"
    FAIL=$((FAIL+1)); FAILED_CASES+=("$desc")
  else
    echo "PASS: $desc"
    PASS=$((PASS+1))
  fi
}

assert_no_canary() {
  local desc="$1"
  if [[ -e "$CANARY" ]]; then
    echo "FAIL: $desc — canary file was created at $CANARY"
    rm -f "$CANARY"
    FAIL=$((FAIL+1)); FAILED_CASES+=("$desc (canary)")
  fi
}

assert_pass() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
    PASS=$((PASS+1))
  else
    echo "FAIL: $desc — expected success, got non-zero"
    FAIL=$((FAIL+1)); FAILED_CASES+=("$desc")
  fi
}

echo "== shell-injection probes =="
# A team-name arg that contains shell metacharacters must be rejected by
# input validation. Even if it weren't, bash's quoted arg expansion would
# pass it as a single literal — the canary check confirms no command-
# substitution side effect occurred.
assert_fail "resolve rejects ;rm metacharacters" \
  bash scripts/sports.sh resolve "; touch $CANARY"
assert_no_canary "resolve ;rm canary"

assert_fail "resolve rejects \$(...) substitution" \
  bash scripts/sports.sh resolve "\$(touch $CANARY)"
assert_no_canary "resolve \$() canary"

assert_fail "resolve rejects backtick substitution" \
  bash scripts/sports.sh resolve "\`touch $CANARY\`"
assert_no_canary "resolve backtick canary"

assert_fail "resolve rejects pipe metachar" \
  bash scripts/sports.sh resolve "cubs | id"

assert_fail "tick rejects shell metas" \
  bash scripts/sports.sh tick "; touch $CANARY"
assert_no_canary "tick ;rm canary"

assert_fail "watch rejects shell metas" \
  bash scripts/sports.sh watch "\$(touch $CANARY)"
assert_no_canary "watch \$() canary"

assert_fail "highlights filter rejects metas" \
  bash scripts/sports.sh highlights cubs "\$(touch $CANARY)"
assert_no_canary "highlights filter canary"

echo
echo "== id / event-id validation =="
# Non-integer team IDs must be rejected (espn.sh).
assert_fail "espn today_game rejects non-int teamId" \
  bash scripts/espn.sh today_game nfl "1; touch $CANARY"
assert_no_canary "espn teamId canary"

assert_fail "espn summary rejects bogus eventId" \
  bash scripts/espn.sh summary nhl "foo&inject=bar"

assert_fail "espn tick rejects unknown league" \
  bash scripts/espn.sh tick wnba 1

assert_fail "cubs live_feed rejects non-int gamePk" \
  bash scripts/cubs.sh live_feed "12; rm -rf /"
assert_no_canary "cubs gamePk canary"

assert_fail "cubs highlights rejects non-int gamePk" \
  bash scripts/cubs.sh highlights "abc"

echo
echo "== path traversal in state-file env =="
assert_fail "espn rejects absolute STATE_FILE" \
  env SPORTS_STATE_FILE=/etc/passwd bash scripts/espn.sh tick nfl 3

assert_fail "espn rejects .. STATE_FILE" \
  env SPORTS_STATE_FILE='../../../tmp/evil' bash scripts/espn.sh tick nfl 3

assert_fail "cubs rejects absolute STATE_FILE" \
  env CUBS_STATE_FILE=/etc/passwd bash scripts/cubs.sh tick

assert_fail "cubs rejects .. STATE_FILE" \
  env CUBS_STATE_FILE='../../etc/passwd' bash scripts/cubs.sh tick

echo
echo "== malformed-state recovery =="
mkdir -p state
echo "not valid json {{{" > state/games.json
# espn.sh tick must not crash on a corrupt state file. Returns 0 because
# upstream API is unreachable from the sandbox; the key is that it doesn't
# hang or exit with a parse error.
assert_pass "espn tick survives corrupt state" \
  bash scripts/espn.sh tick nfl 3
rm -f state/games.json

echo "garbage" > state/cubs-game.json
assert_pass "cubs tick survives corrupt state" \
  bash scripts/cubs.sh tick
rm -f state/cubs-game.json

echo
echo "== happy-path sanity =="
# Make sure validation didn't break legitimate inputs.
assert_pass "resolve cubs"      bash scripts/sports.sh resolve cubs
assert_pass "resolve avs"       bash scripts/sports.sh resolve avs
assert_pass "resolve red sox"   bash scripts/sports.sh resolve "red sox"
assert_pass "defaults"          bash scripts/sports.sh defaults

echo
echo "================================"
echo "PASS: $PASS    FAIL: $FAIL"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
