#!/bin/bash
# Test di rclone_watch_bisync.sh: debounce, gate lsof, eventi in coda,
# retry automatico con backoff, eventi transitori ignorati e cleanup.
#
# Il watcher non si sospende più per un errore di bisync: il cooldown è
# gestito da rclone_bisync.sh tramite il marker .blocked, che qui viene solo
# letto. Questi test verificano che resti vivo e che ritenti da solo.

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
    BACKOFF_START="${BACKOFF_START:-2}" \
    BACKOFF_MAX="${BACKOFF_MAX:-2}" \
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

printf '\n-- prerequisiti --\n'
# Con il marker presente il watcher resta vivo: sarà rclone_bisync.sh a
# decidere quando ritentare (cooldown), non il watcher a fermarsi.
: > "$BLOCKED"
start_watcher 1
if kill -0 "$WATCH_PID" 2>/dev/null; then
    pass "marker .blocked non ferma il watcher"
else
    fail "marker .blocked non ferma il watcher"
fi
stop_watcher
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

printf '\n-- eventi transitori ignorati --\n'
rm -f "$CALLS" "$LOG"
mkdir -p "$SRC/.obsidian"
start_watcher 1

echo '{"stato":"volatile"}' > "$SRC/.obsidian/workspace.json"
sleep 3
assert_eq 0 "$(count_lines "$CALLS")" "workspace.json non innesca una run"

echo "vero" >> "$SRC/vero.txt"
sleep 3
assert_eq 1 "$(count_lines "$CALLS")" "un file vero innesca la run"
stop_watcher

printf '\n-- retry automatico dopo un errore --\n'
rm -f "$CALLS" "$LOG" "$BLOCKED"
STUB_BISYNC_RC=1 BACKOFF_START=2 BACKOFF_MAX=2 start_watcher 1

echo "retry" >> "$SRC/retry.txt"
sleep 12

if [ "$(count_lines "$CALLS")" -ge 2 ]; then
    pass "dopo un errore il watcher ritenta da solo (senza nuovi eventi)"
else
    fail "dopo un errore il watcher ritenta da solo (senza nuovi eventi)" \
        "chiamate=$(count_lines "$CALLS")"
fi
if kill -0 "$WATCH_PID" 2>/dev/null; then
    pass "il watcher resta attivo dopo un errore"
else
    fail "il watcher resta attivo dopo un errore"
fi
stop_watcher

printf '\n-- cooldown letto dal marker --\n'
rm -f "$CALLS" "$LOG" "$BLOCKED"
# Marker con retry lontano: il watcher deve rispettarlo e restare vivo.
printf 'reason=test\nretry_after=%s\nattempts=1\n' "$(( $(date +%s) + 3600 ))" > "$BLOCKED"
STUB_BISYNC_RC=7 start_watcher 1
echo "cooldown" >> "$SRC/cooldown.txt"
sleep 5
if [ "$(count_lines "$CALLS")" -eq 1 ]; then
    pass "una sola chiamata: il cooldown viene rispettato"
else
    fail "una sola chiamata: il cooldown viene rispettato" \
        "chiamate=$(count_lines "$CALLS")"
fi
if kill -0 "$WATCH_PID" 2>/dev/null; then
    pass "il watcher attende il cooldown senza uscire"
else
    fail "il watcher attende il cooldown senza uscire"
fi
stop_watcher
rm -f "$BLOCKED"

printf '\n-- cleanup --\n'
assert_absent "$FIFO" "FIFO assente a fine test"
residuali=$(pgrep -fc "inotifywait.*${TEST_TMP}" 2>/dev/null || true)
assert_eq 0 "$residuali" "nessun inotifywait residuo"

finish
