#!/bin/bash
# Test unitari del modulo condiviso scripts/lib/common.sh.
# Verifica i contratti: exit code, validazione, percorsi, log, lock helper,
# safety check, esecuzione rclone e marker di blocco.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"
setup_bisync_fixture

# Il fixture esporta RCLONE_BIN/RCLONE_CONFIG_DIR/NOTIFY_ENABLED; il modulo
# va caricato dopo per ereditarli.
# shellcheck source=../scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

printf '\n-- costanti --\n'
assert_eq 0 "$EXIT_OK" "EXIT_OK=0"
assert_eq 1 "$EXIT_ERROR" "EXIT_ERROR=1"
assert_eq 7 "$EXIT_CRITICAL" "EXIT_CRITICAL=7"
assert_eq 75 "$EXIT_TEMPFAIL" "EXIT_TEMPFAIL=75"

printf '\n-- validazione path --\n'
if is_remote_path "tst:"; then pass "riconosce un remote"; else fail "riconosce un remote"; fi
if is_remote_path "/tmp"; then fail "un path locale non è un remote"; else pass "un path locale non è un remote"; fi
assert_eq "tst" "$(remote_name_of "tst:cartella")" "remote_name_of estrae il nome"

( require_args 0 2 "uso" ) >/dev/null 2>&1
assert_eq 1 "$?" "require_args con conteggio errato -> 1"

( require_args 2 2 "uso" ) >/dev/null 2>&1
assert_eq 0 "$?" "require_args con conteggio corretto -> 0"

( require_remote_path "/tmp" "PATH" "uso" ) >/dev/null 2>&1
assert_eq 1 "$?" "require_remote_path senza ':' -> 1"

( require_remote_path "tst:" "PATH" "uso" ) >/dev/null 2>&1
assert_eq 0 "$?" "require_remote_path valido -> 0"

( require_configured_remote tst ) >/dev/null 2>&1
assert_eq 0 "$?" "remote configurato -> 0"

( require_configured_remote nope ) >/dev/null 2>&1
assert_eq 1 "$?" "remote non configurato -> 1"

printf '\n-- percorsi e preparazione --\n'
init_rclone_paths "tst" "bisync" "bisync-tst.log"
assert_eq "$TEST_TMP/conf/conf_dir_tst" "$CONF_DIR" "CONF_DIR"
assert_eq "$TEST_TMP/conf/conf_dir_tst/log_files" "$LOG_FILES_DIR" "LOG_FILES_DIR"
assert_eq "$TEST_TMP/conf/conf_dir_tst/lock_files" "$LOCK_FILES_DIR" "LOCK_FILES_DIR"
assert_eq "$LOCK_FILES_DIR/remote-tst.lock" "$LOCK_FILE_REMOTE" "LOCK_FILE_REMOTE"
assert_eq "$LOCK_FILES_DIR/bisync-tst.lock" "$LOCK_FILE_OPERATION" "LOCK_FILE_OPERATION"
assert_eq "$LOCK_FILES_DIR/bisync-tst.blocked" "$BLOCKED_FILE" "BLOCKED_FILE"
assert_eq "$LOG_FILES_DIR/bisync-tst.log" "$LOG_FILE" "LOG_FILE"

ensure_runtime_dirs
assert_exists "$LOG_FILES_DIR" "ensure_runtime_dirs crea log_files"
assert_exists "$LOCK_FILES_DIR" "ensure_runtime_dirs crea lock_files"

ensure_log_file
assert_exists "$LOG_FILE" "ensure_log_file crea il log"

log_line "$LOG_FILE" "riga-di-test"
assert_contains "$LOG_FILE" "riga-di-test" "log_line scrive sul file"

printf '\n-- esecuzione rclone --\n'
run_rclone echo hello
assert_eq 0 "$RCLONE_RC" "run_rclone: exit 0"
assert_eq "hello" "$RCLONE_OUTPUT" "run_rclone: stdout catturato"

run_rclone sh -c 'echo errore >&2; exit 3'
assert_eq 3 "$RCLONE_RC" "run_rclone: exit code catturato"
assert_eq "errore" "$RCLONE_OUTPUT" "run_rclone: stderr catturato"

if is_critical_rc 7; then pass "is_critical_rc(7)"; else fail "is_critical_rc(7)"; fi
if is_critical_rc 1; then fail "is_critical_rc(1)"; else pass "is_critical_rc(1)"; fi

printf '\n-- marker di blocco --\n'
mark_blocked "$BLOCKED_FILE"
if is_blocked "$BLOCKED_FILE"; then pass "mark_blocked/is_blocked"; else fail "mark_blocked/is_blocked"; fi
clear_blocked "$BLOCKED_FILE"
if is_blocked "$BLOCKED_FILE"; then fail "clear_blocked"; else pass "clear_blocked"; fi

printf '\n-- safety check lsof --\n'
wait_for_no_open_files "$TEST_TMP/src" 1 0
assert_eq 0 "$?" "directory senza file aperti -> 0"

touch "$TEST_TMP/src/held.txt"
hold_fd "$TEST_TMP/src/held.txt" "r" 3
holder=$HOLDER_PID
wait_for_no_open_files "$TEST_TMP/src" 1 1 >/dev/null 2>&1
assert_eq 1 "$?" "file aperto oltre max_wait -> 1"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

printf '\n-- remote e controlli locali --\n'
if remote_has_check_file "tst:"; then pass "remote_has_check_file"; else fail "remote_has_check_file"; fi
( ensure_remote_check_file "tst:" ) >/dev/null 2>&1
assert_eq 0 "$?" "ensure_remote_check_file -> 0"

if remote_is_reachable tst; then pass "remote_is_reachable"; else fail "remote_is_reachable"; fi

( check_local_write "$TEST_TMP/src" ) >/dev/null 2>&1
assert_eq 0 "$?" "check_local_write -> 0"

( check_disk_space "$TEST_TMP/src" 1 ) >/dev/null 2>&1
assert_eq 0 "$?" "check_disk_space -> 0"

printf '\n-- formato dei log --\n'
LOG_TAG="TST"
STDERR_FILE="$TEST_TMP/logs/stderr.log"

log_info "messaggio" 2> "$STDERR_FILE"
assert_eq 1 "$(grep -cE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[INFO\] \[TST\] messaggio$' "$STDERR_FILE")" \
    "log_info usa il formato standard"

log_warn "attenzione" 2> "$STDERR_FILE"
assert_contains "$STDERR_FILE" "[WARN] [TST] attenzione" "log_warn usa il livello WARN"

log_error "guasto" 2> "$STDERR_FILE"
assert_contains "$STDERR_FILE" "[ERROR] [TST] guasto" "log_error usa il livello ERROR"

log_critical "bloccato" 2> "$STDERR_FILE"
assert_contains "$STDERR_FILE" "[CRITICAL] [TST] bloccato" "log_critical usa il livello CRITICAL"

log_text WARN "prima
seconda" 2> "$STDERR_FILE"
assert_eq 2 "$(grep -c '\[WARN\] \[TST\]' "$STDERR_FILE")" \
    "un messaggio multiriga produce un record per riga"

( DEBUG_MODE=0; log_debug "spento" ) 2> "$STDERR_FILE"
assert_eq 0 "$(count_lines "$STDERR_FILE")" "log_debug tace con DEBUG_MODE=0"

( DEBUG_MODE=1; log_debug "acceso" ) 2> "$STDERR_FILE"
assert_contains "$STDERR_FILE" "[DEBUG] [TST] acceso" "log_debug scrive con DEBUG_MODE=1"

FORMAT_LOG="$TEST_TMP/logs/format.log"
: > "$FORMAT_LOG"
log_line "$FORMAT_LOG" "riga"
log_line_at "$FORMAT_LOG" ERROR "errore"
assert_contains "$FORMAT_LOG" "[INFO] [TST] riga" "log_line scrive un record INFO"
assert_contains "$FORMAT_LOG" "[ERROR] [TST] errore" "log_line_at accetta il livello"

printf '\n-- formato delle notifiche --\n'
cat > "$TEST_TMP/bin/notify-send" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "$TEST_TMP/logs/notify.log"
EOS
chmod +x "$TEST_TMP/bin/notify-send"
NOTIFY_LOG="$TEST_TMP/logs/notify.log"

: > "$NOTIFY_LOG"
(
    NOTIFY_ENABLED=1
    NOTIFY_BIN="$TEST_TMP/bin/notify-send"
    NOTIFY_TITLE="Rclone test"
    NOTIFY_APP="Rclone Script"
    send_notification "guasto" ERROR
)
assert_contains "$NOTIFY_LOG" "-u normal" "urgenza normal per ERROR"
assert_contains "$NOTIFY_LOG" "-i dialog-error" "icona dialog-error per ERROR"
assert_contains "$NOTIFY_LOG" "-a Rclone Script" "nome applicazione"
assert_contains "$NOTIFY_LOG" "Rclone test [ERROR]" "riepilogo con titolo e livello"

: > "$NOTIFY_LOG"
(
    NOTIFY_ENABLED=1
    NOTIFY_BIN="$TEST_TMP/bin/notify-send"
    NOTIFY_TITLE="Rclone test"
    send_notification "grave" CRITICAL
)
assert_contains "$NOTIFY_LOG" "-u critical" "urgenza critical per CRITICAL"

: > "$NOTIFY_LOG"
(
    NOTIFY_ENABLED=1
    NOTIFY_BIN="$TEST_TMP/bin/notify-send"
    NOTIFY_MIN_LEVEL=ERROR
    send_notification "solo avviso" WARN
)
assert_eq 0 "$(count_lines "$NOTIFY_LOG")" "sotto NOTIFY_MIN_LEVEL non invia"

: > "$NOTIFY_LOG"
(
    NOTIFY_ENABLED=0
    NOTIFY_BIN="$TEST_TMP/bin/notify-send"
    send_notification "disabilitata" CRITICAL
)
assert_eq 0 "$(count_lines "$NOTIFY_LOG")" "NOTIFY_ENABLED=0 non invia"

send_notification "test"
assert_eq 0 "$?" "send_notification non fallisce"

finish
