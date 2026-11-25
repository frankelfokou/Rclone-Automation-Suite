#!/bin/bash
# Test dell'auto-riparazione: classificazione degli errori, cooldown,
# firma dei filtri, analisi del danno, invarianti delle coppie, quarantena,
# deduplicazione delle notifiche e assenza di auto-innesco del watcher.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"
setup_bisync_fixture

# shellcheck source=../scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

init_rclone_paths "tst" "bisync" "bisync-tst.log"
ensure_runtime_dirs
STATE_DIR="$TEST_TMP/conf/conf_dir_tst/state"
mkdir -p "$STATE_DIR"

BISYNC="$TEST_TMP/bisync.sh"
SRC="$TEST_TMP/src"
BLOCKED="$TEST_TMP/conf/conf_dir_tst/lock_files/bisync-tst.blocked"
COUNT="$TEST_TMP/logs/count"

printf '\n-- classificazione degli errori --\n'
assert_eq "too_many_deletes" \
    "$(classify_bisync_failure 1 "Safety abort: too many deletes (>50%, 981 of 1210) on Path2")" \
    "too many deletes riconosciuto"
assert_eq "retryable" \
    "$(classify_bisync_failure 7 "Bisync critical error: directory not empty - retryable without --resync")" \
    "errore ritentabile senza resync"
assert_eq "auth" \
    "$(classify_bisync_failure 1 "oauth2: cannot fetch token: 401 Unauthorized")" \
    "token scaduto riconosciuto"
assert_eq "rate_limit" \
    "$(classify_bisync_failure 1 "googleapi: Error 403: User rate limit exceeded")" \
    "rate limit riconosciuto"
assert_eq "network" \
    "$(classify_bisync_failure 1 "dial tcp 142.250.1.1:443: i/o timeout")" \
    "errore di rete riconosciuto"
assert_eq "critical" \
    "$(classify_bisync_failure 7 "messaggio sconosciuto")" \
    "exit 7 senza firma noto -> critical"
assert_eq "other" \
    "$(classify_bisync_failure 1 "permission denied")" \
    "errore generico -> other"

printf '\n-- cooldown del blocco --\n'
for case in "1 900" "2 3600" "3 21600" "4 86400"; do
    read -r attempt expected <<< "$case"
    blocked_set "$BLOCKED_FILE" "test" "$attempt"
    retry_after="$(blocked_field "$BLOCKED_FILE" retry_after)"
    delay=$(( retry_after - $(date +%s) ))
    if [ "$delay" -ge $(( expected - 5 )) ] && [ "$delay" -le $(( expected + 5 )) ]; then
        pass "tentativo ${attempt}: attesa ${expected}s"
    else
        fail "tentativo ${attempt}: attesa ${expected}s" "ottenuto ${delay}s"
    fi
done
if blocked_is_due "$BLOCKED_FILE"; then
    fail "blocco futuro non è ancora scaduto"
else
    pass "blocco futuro non è ancora scaduto"
fi
printf 'reason=test\nretry_after=%s\nattempts=2\n' "$(( $(date +%s) - 1 ))" > "$BLOCKED_FILE"
if blocked_is_due "$BLOCKED_FILE"; then
    pass "blocco scaduto: nuovo tentativo ammesso"
else
    fail "blocco scaduto: nuovo tentativo ammesso"
fi
rm -f "$BLOCKED_FILE"

printf '\n-- cooldown rispettato da rclone_bisync.sh --\n'
rm -f "$COUNT" "$BLOCKED"
printf 'reason=test\nretry_after=%s\nattempts=1\n' "$(( $(date +%s) + 3600 ))" > "$BLOCKED"
STUB_SLEEP=0 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "bisync in cooldown -> rinvio 75"
assert_eq 0 "$(count_lines "$COUNT")" "nessuna chiamata a rclone durante il cooldown"
rm -f "$BLOCKED"

printf '\n-- firma dei filtri --\n'
FILTER_FILE="$TEST_TMP/conf/exclude_patterns.txt"
printf '.git/\n' > "$FILTER_FILE"
sig1="$(filters_signature "$FILTER_FILE")"
sig_same="$(filters_signature "$FILTER_FILE")"
printf '.git/\n*.tmp\n' > "$FILTER_FILE"
sig2="$(filters_signature "$FILTER_FILE")"
assert_eq "$sig1" "$sig_same" "firma stabile a parità di contenuto"
if [ "$sig1" != "$sig2" ]; then
    pass "firma diversa quando cambiano le esclusioni"
else
    fail "firma diversa quando cambiano le esclusioni"
fi

printf '\n-- analisi del danno --\n'
export BISYNC_CACHE_DIR="$TEST_TMP/cache"
mkdir -p "$BISYNC_CACHE_DIR"
seq 1 101 > "$BISYNC_CACHE_DIR/fake_tst_.path1.lst"
seq 1 101 > "$BISYNC_CACHE_DIR/fake_tst_.path2.lst"
# Lo stub gira in un processo separato: le variabili vanno esportate.
export STUB_SIZE_LOCAL STUB_SIZE_REMOTE

STUB_SIZE_LOCAL=100 STUB_SIZE_REMOTE=10
assert_eq "remote_damaged" \
    "$(bisync_damage_analysis "$SRC" "tst:" tst)" \
    "remote svuotato con locale intatto"

STUB_SIZE_LOCAL=10 STUB_SIZE_REMOTE=100
assert_eq "local_shrunk" \
    "$(bisync_damage_analysis "$SRC" "tst:" tst)" \
    "locale svuotato con remote intatto"

STUB_SIZE_LOCAL=10 STUB_SIZE_REMOTE=10
assert_eq "both_shrunk" \
    "$(bisync_damage_analysis "$SRC" "tst:" tst)" \
    "entrambi i lati ridotti"

STUB_SIZE_LOCAL=100 STUB_SIZE_REMOTE=100
assert_eq "unknown" \
    "$(bisync_damage_analysis "$SRC" "tst:" tst)" \
    "nessuna riduzione: nulla da decidere"

printf '\n-- merge con newest wins --\n'
MERGE_SRC="$TEST_TMP/merge-src"
MERGE_DST="$TEST_TMP/merge-dst"
mkdir -p "$MERGE_SRC" "$MERGE_DST"
printf 'vecchio\n' > "$MERGE_DST/f.txt"
printf 'nuovo\n' > "$MERGE_SRC/f.txt"
touch -d '2020-01-01 10:00:00' "$MERGE_DST/f.txt"
touch -d '2026-01-01 10:00:00' "$MERGE_SRC/f.txt"
printf 'solo-sorgente\n' > "$MERGE_SRC/only.txt"
if guard_merge_into "$MERGE_SRC" "$MERGE_DST"; then
    pass "guard_merge_into completa la copia"
else
    fail "guard_merge_into completa la copia"
fi
assert_eq "nuovo" "$(cat "$MERGE_DST/f.txt")" "vince il file più recente"
assert_exists "$MERGE_DST/only.txt" "i file mancanti vengono copiati"

printf '\n-- invariante: voce vietata rimossa e messa in quarantena --\n'
export QUARANTINE_ROOT="$TEST_TMP/quarantine"
export STUB_TOP_LEVEL="Obsidian/"
export STUB_PURGE_LOG="$TEST_TMP/logs/purge.log"
GUARD_ALLOWED_TOP_LEVEL=""
GUARD_FORBIDDEN_TOP_LEVEL="Obsidian"
GUARD_MIGRATE_TARGET="$TEST_TMP/target"

mkdir -p "$SRC/Obsidian"
printf 'nota\n' > "$SRC/Obsidian/nota.md"

guard_enforce "$SRC" "tst:"
assert_eq 1 "$GUARD_CHANGED" "guard segnala la modifica"
assert_absent "$SRC/Obsidian" "la voce vietata sparisce dalla radice"
assert_contains "$STUB_PURGE_LOG" "Obsidian" "la voce vietata viene rimossa dal remote"
quarantined=$(find "$QUARANTINE_ROOT" -name nota.md 2>/dev/null | head -n 1)
if [ -n "$quarantined" ]; then
    pass "il contenuto è recuperabile dalla quarantena"
else
    fail "il contenuto è recuperabile dalla quarantena"
fi

printf '\n-- invariante: voce non ammessa non viene toccata senza allow-list --\n'
mkdir -p "$SRC/00-Documenti"
printf 'doc\n' > "$SRC/00-Documenti/doc.txt"
STUB_TOP_LEVEL=""
GUARD_FORBIDDEN_TOP_LEVEL="Obsidian"
guard_enforce "$SRC" "tst:"
assert_exists "$SRC/00-Documenti/doc.txt" \
    "senza allow-list le altre cartelle restano dove sono"

printf '\n-- notifiche deduplicate --\n'
cat > "$TEST_TMP/bin/notify-send" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_TMP/logs/notify.log"
EOS
chmod +x "$TEST_TMP/bin/notify-send"
NOTIFY_LOG="$TEST_TMP/logs/notify.log"
: > "$NOTIFY_LOG"
NOTIFY_ENABLED=1
NOTIFY_BIN="$TEST_TMP/bin/notify-send"
NOTIFY_TITLE="Rclone test"
NOTIFY_MIN_LEVEL="WARN"

notify_event prova ERROR "stesso messaggio"
assert_eq 1 "$(count_lines "$NOTIFY_LOG")" "prima occorrenza notificata"
notify_event prova ERROR "stesso messaggio"
assert_eq 1 "$(count_lines "$NOTIFY_LOG")" "stessa occorrenza non ripetuta"
notify_event prova ERROR "messaggio diverso"
assert_eq 2 "$(count_lines "$NOTIFY_LOG")" "messaggio diverso notificato"
notify_clear prova
notify_event prova ERROR "stesso messaggio"
assert_eq 3 "$(count_lines "$NOTIFY_LOG")" "dopo notify_clear si notifica di nuovo"

printf '\n-- check_local_write non tocca l albero sincronizzato --\n'
before=$(find "$SRC" -type f | wc -l)
( check_local_write "$SRC" ) >/dev/null 2>&1
assert_eq 0 "$?" "check_local_write -> 0"
after=$(find "$SRC" -type f | wc -l)
assert_eq "$before" "$after" "nessun file creato nell'albero locale"

printf '\n-- rete assente: rinvio silenzioso --\n'
rm -f "$COUNT" "$BLOCKED" "$NOTIFY_LOG"
: > "$NOTIFY_LOG"
STUB_ABOUT_RC=1 "$BISYNC" "$SRC" "tst:" >/dev/null 2>&1
assert_eq 75 "$?" "remote irraggiungibile -> 75"
assert_eq 0 "$(count_lines "$NOTIFY_LOG")" "nessuna notifica quando manca la rete"

finish
