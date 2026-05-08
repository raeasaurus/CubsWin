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
echo "== hostname pinning (safe_curl) =="
# Inline-source the lib in a subshell and probe safe_curl directly.
# Anything off the allow-list — including http://, file://, evil hosts,
# IPs, and userinfo-prefixed URLs — must be refused before the process
# ever leaves the script.
probe_safe_curl() {
  ( . scripts/_lib.sh && safe_curl "$1" ) >/dev/null 2>&1
}
assert_fail "safe_curl refuses http (no TLS)" probe_safe_curl "http://statsapi.mlb.com/api/v1/teams"
assert_fail "safe_curl refuses non-allowlisted host" probe_safe_curl "https://evil.example.com/path"
assert_fail "safe_curl refuses raw IP host"          probe_safe_curl "https://127.0.0.1/api"
assert_fail "safe_curl refuses userinfo splice"      probe_safe_curl "https://statsapi.mlb.com@evil.example.com/path"
assert_fail "safe_curl refuses file://"              probe_safe_curl "file:///etc/passwd"

echo
echo "== atomic state writes + 0600 mode =="
# Write a state via espn.sh (tick wraps atomic_write internally). Even
# though the upstream API call fails in the sandbox, the run still
# touches state/games.json. Verify the file isn't world-readable and
# that no leftover .cubswin.* tmp file remains.
mkdir -p state
rm -f state/games.json state/.cubswin.*
( . scripts/_lib.sh && atomic_write state/games.json '{"probe":1}' )
mode="$(stat -c '%a' state/games.json 2>/dev/null || stat -f '%A' state/games.json)"
if [[ "$mode" == "600" ]]; then
  echo "PASS: atomic_write sets 0600 mode"; PASS=$((PASS+1))
else
  echo "FAIL: atomic_write left mode=$mode (want 600)"; FAIL=$((FAIL+1)); FAILED_CASES+=("0600 mode")
fi
if compgen -G 'state/.cubswin.*' >/dev/null; then
  echo "FAIL: atomic_write left a tmp file behind"; FAIL=$((FAIL+1)); FAILED_CASES+=("tmp leak")
else
  echo "PASS: atomic_write leaves no tmp file"; PASS=$((PASS+1))
fi
rm -f state/games.json

echo
echo "== lockfile mutex =="
# with_lock must (a) actually run the body when the lock is free and
# (b) silently skip when another holder is active. Re-implemented as an
# if/else (instead of `cmd && pass || fail`) so a failing PASS branch
# can't be misread as the FAIL branch.
if ( . scripts/_lib.sh && with_lock /tmp/cubswin-test.lock true ); then
  echo "PASS: with_lock runs the body once"; PASS=$((PASS+1))
else
  echo "FAIL: with_lock body didn't run"; FAIL=$((FAIL+1)); FAILED_CASES+=("with_lock")
fi

# Hold the lock in this shell, then ask with_lock to run a body that
# would fail if it actually executed. with_lock should see the held
# lock, return 0 without running anything, and the test passes.
if (
  . scripts/_lib.sh
  exec 200>/tmp/cubswin-test.lock
  flock -n 200 || exit 0
  with_lock /tmp/cubswin-test.lock false
) >/dev/null 2>&1; then
  echo "PASS: with_lock skips when another holder is active"; PASS=$((PASS+1))
else
  echo "FAIL: with_lock didn't skip"; FAIL=$((FAIL+1)); FAILED_CASES+=("with_lock skip")
fi
rm -f /tmp/cubswin-test.lock

echo
echo "== catalog integrity =="
# Tampering with the catalog (non-numeric id, oversized name, wrong
# top-level type) must trip assert_catalog_sane on next resolve.
cp config/team-catalog.json /tmp/cubswin-catalog.bak
trap 'cp /tmp/cubswin-catalog.bak config/team-catalog.json; rm -f /tmp/cubswin-catalog.bak' EXIT

# Inject a non-integer id — catalog should be rejected.
jq '.mlb[0].id = "0; rm -rf /"' /tmp/cubswin-catalog.bak > config/team-catalog.json
assert_fail "resolve fails on non-integer catalog id" \
  bash scripts/sports.sh resolve cubs

# Inject an absurdly long team name — should fail length check.
jq --arg n "$(printf 'A%.0s' {1..200})" '.mlb[0].name = $n' /tmp/cubswin-catalog.bak > config/team-catalog.json
assert_fail "resolve fails on oversized catalog name" \
  bash scripts/sports.sh resolve cubs

# Truncate league below the minimum size threshold.
jq '.mlb = [.mlb[0]]' /tmp/cubswin-catalog.bak > config/team-catalog.json
assert_fail "resolve fails on shrunken league" \
  bash scripts/sports.sh resolve cubs

# Restore.
cp /tmp/cubswin-catalog.bak config/team-catalog.json
rm -f /tmp/cubswin-catalog.bak
trap - EXIT

echo
echo "== output caps =="
# Verify the highlights cap clauses exist in the jq filters. Static check
# rather than runtime — runtime would need a live API.
# shellcheck disable=SC2016  # we want grep to see the literal $cap
assert_pass "espn highlights jq filter contains [0:\$cap]" \
  grep -qF '.[0:$cap]' scripts/espn.sh
assert_pass "cubs highlights jq filter caps at .[0:20]" \
  grep -qF '.[0:20]' scripts/cubs.sh

echo
echo "== tighter team-name regex =="
# Length+charset alone permitted "; ;" (all punctuation); the new
# regex requires at least one alphanumeric.
assert_fail "resolve rejects all-punctuation name" \
  bash scripts/sports.sh resolve "; ;"

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
