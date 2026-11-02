#!/bin/bash
# Test di utility/rclone_watch_bisync.sh: debounce, gate lsof, eventi in coda,
# backoff, blocco critico e cleanup.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"
setup_bisync_fixture

WATCH="$TEST_TMP/watch.sh"
SRC="$TEST_TMP/src"
CALLS="$TEST_TMP/logs/calls.log"
LOG="$TEST_TMP/conf/conf_dir_tst/log_files/watcher-tst.log"
FIFO="$TEST_TMP/conf/conf_dir_tst/lock_files/watcher-tst.fifo"
BLOCKED="$TEST_TMP/conf/conf_dir_tst/lock_files/bisync-tst.blocked"
WATCH_PID=""

start_watcher() { # $1 = debounce
    BISYNC_SCRIPT="$TEST_TMP/stub_bisync.sh" \
    MIN_INTERVAL="${MIN_INTERVAL:-0}" \
    LSOF_POLL=0.2 \
    LSOF_MAX_WAIT=30 \
    STUB_BISYNC_SLEEP="${STUB_BISYNC_SLEEP:-0}" \
    STUB_BISYNC_RC="${STUB_BISYNC_RC:-0}" \
    "$WATCH" "$SRC" "tst:" "$1" >> "$TEST_TMP/logs/watch.out" 2>&1 &
    WATCH_PID=$!
    BG_PIDS+=("$WATCH_PID")
    sleep 1
}

stop_watcher() {
    if [ -n "$WATCH_PID" ]; then
        kill -TERM "$WATCH_PID" 2>/dev/null || true
        wait "$WATCH_PID" 2>/dev/null || true
        WATCH_PID=""
    fi
}

printf '\n-- prerequisiti e blocco --\n'
: > "$BLOCKED"
"$WATCH" "$SRC" "tst:" 1 >/dev/null 2>&1
assert_eq 75 "$?" "marker bloccato -> 75"
rm -f "$BLOCKED"

"$WATCH" "$TEST_TMP/nope" "tst:" 1 >/dev/null 2>&1
assert_eq 1 "$?" "directory locale mancante -> 1"

printf '\n-- gate file aperti --\n'
rm -f "$CALLS" "$LOG"
start_watcher 1

touch "$SRC/hold.txt"
bash -c 'exec 9<"'"$SRC"'/hold.txt"; sleep 4' &
HOLDER=$!
BG_PIDS+=("$HOLDER")

sleep 2
assert_eq 0 "$(count_lines "$CALLS")" "nessuna chiamata con file aperto"

wait "$HOLDER" 2>/dev/null
sleep 3
assert_eq 1 "$(count_lines "$CALLS")" "una chiamata appena il file è chiuso"

stop_watcher
assert_absent "$FIFO" "FIFO rimossa dopo lo stop"

printf '\n-- evento durante la run --\n'
rm -f "$CALLS" "$LOG"
STUB_BISYNC_SLEEP=3 start_watcher 1

echo "a" >> "$SRC/f1.txt"
sleep 2
echo "b" >> "$SRC/f2.txt"   # evento mentre la prima run è in corso
sleep 6

if [ "$(count_lines "$CALLS")" -ge 2 ]; then
    pass "evento durante la run -> seconda run"
else
    fail "evento durante la run -> seconda run" \
        "chiamate=$(count_lines "$CALLS")"
fi
stop_watcher

printf '\n-- debounce --\n'
rm -f "$CALLS" "$LOG"
STUB_BISYNC_SLEEP=0 start_watcher 1

for i in 1 2 3 4 5; do
    echo "burst-$i" >> "$SRC/burst.txt"
    sleep 0.2
done
sleep 4
assert_eq 1 "$(count_lines "$CALLS")" "5 scritture ravvicinate -> una sola run"
stop_watcher

printf '\n-- errore critico --\n'
rm -f "$CALLS" "$LOG" "$BLOCKED"
STUB_BISYNC_RC=7 start_watcher 1

echo "critico" >> "$SRC/critical.txt"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 1
done

wait "$WATCH_PID" 2>/dev/null
rc=$?
WATCH_PID=""
assert_eq 7 "$rc" "exit 7 propagato dal watcher"
assert_exists "$BLOCKED" "marker creato su errore critico"
rm -f "$BLOCKED"

printf '\n-- cleanup --\n'
assert_absent "$FIFO" "FIFO assente a fine test"
residuali=$(pgrep -fc "inotifywait.*${TEST_TMP}" 2>/dev/null || true)
assert_eq 0 "$residuali" "nessun inotifywait residuo"

finish
