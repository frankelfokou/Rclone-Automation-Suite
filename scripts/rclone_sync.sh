#!/bin/bash
#
# rclone_sync.sh — orchestrazione di `rclone sync` remoto → remoto.
# Responsabilità: validare sorgente e destinazione, invocare i lock, eseguire
# sync e gestire gli errori.
# Le responsabilità condivise con rclone_bisync.sh sono in scripts/lib/common.sh.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

SOURCE_PATH="${1:-}"
DEST_PATH="${2:-}"
USAGE="Uso: $0 <sorgente_remota> <destinazione_remota>"

REMOTE_NAME="$(remote_name_of "$SOURCE_PATH")"
DEST_REMOTE_NAME="$(remote_name_of "$DEST_PATH")"
LOG_TAG="SYNC"
NOTIFY_TITLE="Rclone sync ${REMOTE_NAME:-?} -> ${DEST_REMOTE_NAME:-?}"
NOTIFY_APP="Rclone Script"

require_args "$#" 2 "$USAGE"
require_remote_path "$SOURCE_PATH" "SOURCE_PATH" "$USAGE"
require_remote_path "$DEST_PATH" "DEST_PATH" "$USAGE"
require_configured_remote "$REMOTE_NAME"
require_configured_remote "$DEST_REMOTE_NAME"

init_rclone_paths "$REMOTE_NAME" "sync" \
    "sync-${REMOTE_NAME}_to_${DEST_REMOTE_NAME}.log"
ensure_runtime_dirs
ensure_log_file
redirect_output_to_log

# La safety check locale è applicabile solo se SOURCE è una directory locale.
# Con la validazione attuale SOURCE deve contenere ':', quindi il ramo è di
# fatto non raggiungibile; resta per compatibilità futura.
if [[ "$SOURCE_PATH" != *:* ]] && [ -d "$SOURCE_PATH" ]; then
    log_info "Inizio safety check LSOF per file aperti"
    if ! wait_for_no_open_files "$SOURCE_PATH" "$LSOF_WAIT_SECONDS" \
            "$((LSOF_WAIT_SECONDS * LSOF_MAX_RETRIES))"; then
        exit "$EXIT_TEMPFAIL"
    fi
    log_info "Safety check LSOF avvenuto con successo"
else
    log_warn "Safety check LSOF/FIND non applicabile: SOURCE è un remote o una directory non locale."
fi

RCLONE_CMD=(
    "$RCLONE_BIN" sync "$SOURCE_PATH" "$DEST_PATH"
    --exclude-from "$RCLONE_EXCLUDE_FILE"
    --create-empty-src-dirs
    --fast-list
    --drive-stop-on-upload-limit
    --checkers=32
    --transfers=16
    --drive-chunk-size=128M
    --drive-pacer-min-sleep=10ms
    -v
)

handle_sync_failure() {
    local msg last_err full_err

    log_error "Rclone sync fallito (exit ${RCLONE_RC})."
    log_text ERROR "$RCLONE_OUTPUT"
    log_info "Avvio analisi delle cause."

    if ! remote_is_reachable "$REMOTE_NAME"; then
        msg="Remote '${REMOTE_NAME}' non raggiungibile. Controllare la connessione o il token."
        log_error "$msg"
        send_notification "$msg" ERROR
        exit "$EXIT_ERROR"
    fi

    last_err=$(printf '%s\n' "$RCLONE_OUTPUT" | tail -n 3)
    full_err="Rclone sync fallito.
Ultime righe di rclone:
${last_err}"
    send_notification "$full_err" ERROR
    exit "$EXIT_ERROR"
}

(
    log_info "Tentativo di acquisizione lock generale per ${REMOTE_NAME}"
    if ! acquire_remote_lock; then
        log_warn "Rinvio (exit 75): lock generale occupato per ${REMOTE_NAME} (attesa ${LOCK_WAIT}s)."
        exit "$EXIT_TEMPFAIL"
    fi

    (
        log_info "Tentativo di acquisizione lock specifico per sync per ${REMOTE_NAME}"
        if ! acquire_operation_lock; then
            log_warn "Rinvio (exit 75): sync già in esecuzione per ${REMOTE_NAME}."
            exit "$EXIT_TEMPFAIL"
        fi

        log_info "Lock sync acquisito. Avvio rclone sync per ${REMOTE_NAME}."

        run_rclone "${RCLONE_CMD[@]}"
        if [ "$RCLONE_RC" -ne 0 ]; then
            handle_sync_failure
        else
            log_info "Rclone sync completato (exit 0)."
            log_text INFO "$RCLONE_OUTPUT"
        fi
    ) 200>"$LOCK_FILE_OPERATION"
) 201>"$LOCK_FILE_REMOTE"