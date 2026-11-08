#!/bin/bash
# Test di rclone_bisync.sh: validazione, lock, rinvii, resync.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"
setup_bisync_fixture

BISYNC="$TEST_TMP/bisync.sh"
SRC="$TEST_TMP/src"
LOCKDIR="$TEST_TMP/conf/conf_dir_tst/lock_files"
LOG="$TEST_TMP/conf/conf_dir_tst/log_files/bisync-tst.log"
BLOCKED="$LOCKDIR/bisync-tst.blocked"

printf '\n-- validazione argomenti --\n'
"$BISYNC" >/dev/null 2>&1
assert_eq 1 "$?" "nessun argomento -> 1"

"$BISYNC" "$SRC" "tst" >/dev/null 2>&1
assert_eq 1 "$?" "remote senza ':' -> 1"

"$BISYNC" "$SRC" "nope:" >/dev/null 2>&1
assert_eq 1 "$?" "remote non configurato -> 1"

"$BISYNC" "$TEST_TMP/nope" "tst:" >/dev/null 2>&1
assert_eq 1 "$?" "directory locale mancante -> 1"

printf '\n-- lock --\n'
hold_fd "$LOCKDIR/remote-tst.lock" "w" 5
pid=$HOLDER_PID
sleep 0.5
LOCK_WAIT=1 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "lock 201 occupato -> 75"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

hold_fd "$LOCKDIR/bisync-tst.lock" "w" 5
pid=$HOLDER_PID
sleep 0.5
LOCK_WAIT=1 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "lock 200 occupato -> 75"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

printf '\n-- file aperti --\n'
touch "$SRC/open.txt"
hold_fd "$SRC/open.txt" "r" 5
pid=$HOLDER_PID
sleep 0.5
LSOF_WAIT_SECONDS=1 LSOF_MAX_RETRIES=1 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "file aperto -> 75"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

printf '\n-- run normale --\n'
rm -f "$LOG"
STUB_SLEEP=0 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 0 "$?" "run normale -> 0"
assert_contains "$LOG" "Rclone bisync completato (exit 0)." "output nel file di log"
assert_contains "$LOG" "[BISYNC]" "il log riporta il tag del componente"
assert_absent "$BLOCKED" "nessun marker dopo successo"

printf '\n-- errori rclone --\n'
STUB_FAIL_ALWAYS=1 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "exit 1 -> rinvio 75"
assert_absent "$BLOCKED" "exit 1 non crea il marker"

rm -f "$COUNT_FILE"
STUB_FAIL_FIRST=1 STUB_SLEEP=0 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 0 "$?" "exit 7 con resync ok -> 0"
assert_absent "$BLOCKED" "resync ok rimuove il marker"
assert_eq 2 "$(tr -d '[:space:]' < "$COUNT_FILE")" "run + resync = 2 chiamate"

rm -f "$COUNT_FILE" "$BLOCKED"
STUB_FAIL_ALWAYS=7 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 7 "$?" "exit 7 con resync ko -> 7"
assert_exists "$BLOCKED" "resync ko crea il marker"
rm -f "$BLOCKED"

printf '\n-- connettività --\n'
rm -f "$COUNT_FILE"
STUB_FAIL_ALWAYS=1 STUB_ABOUT_RC=1 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "remote irraggiungibile -> 75"

finish
