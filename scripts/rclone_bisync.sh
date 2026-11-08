#!/bin/bash
#
# rclone_bisync.sh — orchestrazione di `rclone bisync`.
# Responsabilità: validare gli argomenti, invocare i lock, eseguire bisync,
# gestire exit code, recupero e marker di blocco.
# Le responsabilità condivise con rclone_sync.sh sono in scripts/lib/common.sh.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

LOCAL_PATH="${1:-}"
REMOTE_PATH="${2:-}"
USAGE="Uso: $0 <dir_locale> <remote:path>"

REMOTE_NAME="$(remote_name_of "$REMOTE_PATH")"
LOG_TAG="BISYNC"
NOTIFY_TITLE="Rclone bisync ${REMOTE_NAME:-?}"
NOTIFY_APP="Rclone Script"

require_args "$#" 2 "$USAGE"
require_remote_path "$REMOTE_PATH" "REMOTE_PATH" "$USAGE"
require_configured_remote "$REMOTE_NAME"

init_rclone_paths "$REMOTE_NAME" "bisync" "bisync-${REMOTE_NAME}.log"
ensure_runtime_dirs
ensure_log_file
redirect_output_to_log

require_local_dir "$LOCAL_PATH"
ensure_local_check_file "$LOCAL_PATH"

log_info "Inizio safety check LSOF per file aperti"
if ! wait_for_no_open_files "$LOCAL_PATH" "$LSOF_WAIT_SECONDS" \
        "$((LSOF_WAIT_SECONDS * LSOF_MAX_RETRIES))"; then
    exit "$EXIT_TEMPFAIL"
fi
log_info "Safety check LSOF avvenuto con successo"

# Comando di produzione. Non modificare senza test dedicati.
RCLONE_CMD=(
    "$RCLONE_BIN" bisync "$LOCAL_PATH" "$REMOTE_PATH"
    --exclude-from "$RCLONE_EXCLUDE_FILE"
    --remove-empty-dirs
    --check-access
    --resilient
    --recover
    --max-lock 2m
    --fast-list
    --fix-case
    --compare modtime
    --drive-stop-on-upload-limit
    --checkers=32
    --transfers=16
    --drive-chunk-size=128M
    --drive-pacer-min-sleep=10ms
    --drive-export-formats docx,xlsx,pptx
    --drive-import-formats docx,xlsx,pptx
    -v
)

handle_bisync_failure() {
    log_error "Rclone bisync fallito (exit ${RCLONE_RC})."
    log_text ERROR "$RCLONE_OUTPUT"
    log_info "Avvio analisi delle cause."

    if ! remote_is_reachable "$REMOTE_NAME"; then
        local msg="Remote '${REMOTE_NAME}' non raggiungibile. Controllare la connessione o il token."
        log_error "$msg"
        send_notification "$msg" ERROR
        # Errore di rete: ritentabile.
        exit "$EXIT_TEMPFAIL"
    fi

    ensure_remote_check_file "$REMOTE_PATH"
    require_local_dir "$LOCAL_PATH"
    check_local_write "$LOCAL_PATH"
    check_disk_space "$LOCAL_PATH" 1024

    if ! is_critical_rc "$RCLONE_RC"; then
        log_warn "Errore non critico (exit ${RCLONE_RC}): nessun --resync, rinvio (exit 75)."
        exit "$EXIT_TEMPFAIL"
    fi

    # Il resync va eseguito solo a directory quieta.
    if ! wait_for_no_open_files "$LOCAL_PATH" "$LSOF_WAIT_SECONDS" 0; then
        log_warn "File aperti: --resync rinviato (exit 75)."
        exit "$EXIT_TEMPFAIL"
    fi

    log_info "Errore critico (exit 7): tentativo di --resync."
    RESYNC_RC=0
    RESYNC_OUT="$("${RCLONE_CMD[@]}" --resync 2>&1)" || RESYNC_RC=$?

    if [ "$RESYNC_RC" -ne 0 ]; then
        local last_err full_err
        last_err=$(printf '%s\n' "$RESYNC_OUT" | tail -n 3)
        full_err="Resync automatico fallito.
Ultime righe di rclone:
${last_err}"

        log_critical "Resync automatico fallito (exit ${RESYNC_RC})."
        log_text ERROR "$RESYNC_OUT"
        send_notification "$full_err" CRITICAL
        mark_blocked "$BLOCKED_FILE"
        log_critical "Watcher sospeso fino a intervento manuale (${BLOCKED_FILE})."
        exit "$EXIT_CRITICAL"
    fi

    clear_blocked "$BLOCKED_FILE"
    log_info "Resync completato: marker di blocco rimosso."
    log_text INFO "$RESYNC_OUT"
}

(
    log_info "Tentativo di acquisizione lock generale per ${REMOTE_NAME}"
    if ! acquire_remote_lock; then
        log_warn "Rinvio (exit 75): lock generale occupato per ${REMOTE_NAME} (attesa ${LOCK_WAIT}s)."
        exit "$EXIT_TEMPFAIL"
    fi

    (
        log_info "Tentativo di acquisizione lock specifico per bisync per ${REMOTE_NAME}"
        if ! acquire_operation_lock; then
            log_warn "Rinvio (exit 75): bisync già in esecuzione per ${REMOTE_NAME}."
            exit "$EXIT_TEMPFAIL"
        fi

        log_info "Lock bisync acquisito. Avvio rclone bisync per ${REMOTE_NAME}."

        run_rclone "${RCLONE_CMD[@]}"
        if [ "$RCLONE_RC" -ne 0 ]; then
            handle_bisync_failure
        else
            log_info "Rclone bisync completato (exit 0)."
            log_text INFO "$RCLONE_OUTPUT"
        fi
    ) 200>"$LOCK_FILE_OPERATION"
) 201>"$LOCK_FILE_REMOTE"
