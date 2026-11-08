#!/bin/bash
# Test di rclone_sync.sh: validazione, safety check non applicabile, lock,
# successo ed errori.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"
setup_bisync_fixture

SYNC="$TEST_TMP/sync.sh"
LOCKDIR="$TEST_TMP/conf/conf_dir_tst/lock_files"
LOG="$TEST_TMP/conf/conf_dir_tst/log_files/sync-tst_to_tst.log"

printf '\n-- validazione argomenti --\n'
"$SYNC" >/dev/null 2>&1
assert_eq 1 "$?" "nessun argomento -> 1"

"$SYNC" "tst:src" "tst" >/dev/null 2>&1
assert_eq 1 "$?" "destinazione senza ':' -> 1"

"$SYNC" "nope:" "tst:" >/dev/null 2>&1
assert_eq 1 "$?" "sorgente non configurata -> 1"

"$SYNC" "tst:" "nope:" >/dev/null 2>&1
assert_eq 1 "$?" "destinazione non configurata -> 1"

printf '\n-- run normale --\n'
rm -f "$LOG"
STUB_SLEEP=0 "$SYNC" "tst:" "tst:" >/dev/null 2>&1
assert_eq 0 "$?" "run normale -> 0"
assert_contains "$LOG" "Safety check LSOF/FIND non applicabile" \
    "safety check locale segnalato come non applicabile"
assert_contains "$LOG" "[WARN] [SYNC]" \
    "il safety check saltato è un record WARN"
assert_contains "$LOG" "Rclone sync completato (exit 0)." \
    "output nel file di log"

printf '\n-- lock --\n'
hold_fd "$LOCKDIR/remote-tst.lock" "w" 5
pid=$HOLDER_PID
sleep 0.5
LOCK_WAIT=1 "$SYNC" "tst:" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "lock 201 occupato -> 75"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

hold_fd "$LOCKDIR/sync-tst.lock" "w" 5
pid=$HOLDER_PID
sleep 0.5
LOCK_WAIT=1 "$SYNC" "tst:" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "lock 200 occupato -> 75"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

printf '\n-- errori --\n'
STUB_FAIL_ALWAYS=1 "$SYNC" "tst:" "tst:" >/dev/null 2>&1
assert_eq 1 "$?" "errore rclone -> 1"

STUB_FAIL_ALWAYS=1 STUB_ABOUT_RC=1 "$SYNC" "tst:" "tst:" >/dev/null 2>&1
assert_eq 1 "$?" "remote irraggiungibile -> 1"

finish
