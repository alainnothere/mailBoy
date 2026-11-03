#!/bin/sh
# Shell-level check of the built binary: a fake curl is put first on PATH so
# no network is needed. Run from the repo root: sh tests/cli_smoke.sh
set -u
BIN=${BIN:-bin/mailboy}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ln -s "$PWD/tests/fixtures/fakebin/fakehttp" "$TMP/curl"
export PATH="$TMP:$PATH"
COLL=tests/fixtures/cli/cli.collection.json
ENV=tests/fixtures/cli/cli.environment.json
fail=0
check() { # name expected_exit actual_exit
  if [ "$2" -eq "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected exit $2, got $3"; fail=1; fi
}

"$BIN" --version >/dev/null 2>&1; check "version" 0 $?
"$BIN" --help 2>/dev/null | grep -q "Usage:"; check "help text" 0 $?

out=$("$BIN" --list --collection $COLL 2>/dev/null); rc=$?
check "list exit" 0 $rc
[ "$(printf '%s\n' "$out" | wc -l)" -eq 4 ]; check "list has 4 requests" 0 $?

out=$("$BIN" --run ping --collection $COLL 2>/dev/null); rc=$?
check "run text exit" 0 $rc
printf '%s' "$out" | head -1 | grep -q "^HTTP/1.1 200 OK"; check "run text status line" 0 $?
printf '%s' "$out" | tail -1 | grep -q '^{"status":200'; check "run text body is last line, no trailing newline" 0 $?

out=$("$BIN" --run Payments/send --collection $COLL --env $ENV --var amount=7 --json 2>/dev/null); rc=$?
check "run json exit" 0 $rc
printf '%s' "$out" | grep -q '"status" : 201'; check "json status 201" 0 $?
printf '%s' "$out" | grep -q 'Bearer ENVTOKEN'; check "env token used" 0 $?
printf '%s' "$out" | grep -q '{\\"amount\\": 7}'; check "var substituted in body" 0 $?

"$BIN" --run nope --collection $COLL >/dev/null 2>&1; check "not found -> 3" 3 $?
"$BIN" --run dup --collection $COLL >/dev/null 2>&1; check "ambiguous -> 3" 3 $?
"$BIN" --run ping --collection missing.json >/dev/null 2>&1; check "missing file -> 2" 2 $?
"$BIN" --run ping --collection $COLL --var host=fail.test >/dev/null 2>&1; check "transport failure -> 1" 1 $?
"$BIN" --bogus >/dev/null 2>&1; check "bad option -> 2" 2 $?
"$BIN" --run ping --collection $COLL --var 'host={{nowhere}}' >/dev/null 2>"$TMP/err"; check "undefined url variable -> 2" 2 $?
grep -q "URL still contains {{nowhere}}" "$TMP/err"; check "undefined url variable named" 0 $?
PATH=/nonexistent "$BIN" --run ping --collection $COLL >/dev/null 2>&1; check "no curl -> 4" 4 $?

# Hooks.
HOOKS=tests/fixtures/hooks
out=$("$BIN" --run ping --collection $COLL --hook $HOOKS/add_header.sh --json 2>/dev/null); rc=$?
check "hook run exit" 0 $rc
printf '%s' "$out" | grep -q 'x-acme-signature: sig-1'; check "hook header sent" 0 $?
printf '%s' "$out" | grep -q '"hookError" : null'; check "hookError null" 0 $?
"$BIN" --run ping --collection $COLL --hook $HOOKS/fail.sh >/dev/null 2>"$TMP/err"; check "hook exit 1 -> 5" 5 $?
grep -q "Traceback: boom" "$TMP/err"; check "hook stderr reported" 0 $?
"$BIN" --run ping --collection $COLL --hook $HOOKS/garbage.sh >/dev/null 2>"$TMP/err"; check "hook garbage -> 5" 5 $?
grep -q "debug: starting" "$TMP/err"; check "garbage shown in stderr" 0 $?
"$BIN" --run ping --collection $COLL --hook $HOOKS/sleep.sh --hook-timeout 1 >/dev/null 2>&1; check "hook timeout -> 5" 5 $?
"$BIN" --list --collection $COLL --verbose 2>/dev/null | grep -q "^ping \[test\]$"; check "list --verbose marks scripts" 0 $?

# No display: the GUI must never be touched in CLI mode.
DISPLAY= "$BIN" --list --collection $COLL >/dev/null 2>"$TMP/err"; rc=$?
check "headless list without DISPLAY" 0 $rc
! grep -qi "gtk\|display" "$TMP/err"; check "no widgetset noise on stderr" 0 $?

exit $fail
