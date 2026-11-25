#!/bin/bash
#
# rclone_sync.sh — orchestrazione di `rclone sync` remoto → remoto.
# Responsabilità: validare sorgente e destinazione, invocare i lock su
# entrambi gli endpoint, eseguire sync con protezione dalle cancellazioni di
# massa e gestire gli errori.
# Le responsabilità condivise con rclone_bisync.sh sono in scripts/lib/common.sh.
#
# Uso: rclone_sync.sh <sorgente_remota> <destinazione_remota>
#
# Exit code:
#   0   successo
#   1   errore definitivo (configurazione, permessi, cancellazioni bloccate)
#   75  rinvio: rete assente, quota, lock occupato
#
# Il backup non si auto-ripara mai in massa: una cancellazione oltre la soglia
# viene bloccata, notificata una sola volta e lascia intatto il backup.

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

# Numero massimo di cancellazioni in una singola run: oltre questa soglia il
# run viene abortito e il backup resta com'è.
SYNC_MAX_DELETE="${SYNC_MAX_DELETE:-200}"

# Un backup unidirezionale non deve mai scrivere su un remote gestito in
# bidirezionale da bisync: è esattamente ciò che il 10/11 ha svuotato il vault
# (rclone sync GDrive-F4Frank: GDrive-Pro:). Elenco separato da '|'.
SYNC_PROTECTED_DESTS="${SYNC_PROTECTED_DESTS:-GDrive-F4Frank|GDrive-Pro}"
SYNC_ALLOW_PROTECTED_DEST="${SYNC_ALLOW_PROTECTED_DEST:-0}"

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
require_exclude_files

# Rete di sicurezza: la destinazione di un sync unidirezionale non può essere
# un remote sincronizzato in bidirezionale. Senza questo controllo un vecchio
# wrapper in cron potrebbe cancellare il vault.
if [ "$SYNC_ALLOW_PROTECTED_DEST" != "1" ]; then
    IFS='|' read -r -a _protected <<< "$SYNC_PROTECTED_DESTS"
    for _name in "${_protected[@]}"; do
        if [ "$DEST_REMOTE_NAME" = "$_name" ]; then
            log_critical "Destinazione rifiutata: '${DEST_REMOTE_NAME}' è gestito da bisync."
            log_critical "Un sync unidirezionale qui cancellerebbe il lato remoto. Operazione annullata."
            notify_event sync_protected CRITICAL \
                "Backup annullato: la destinazione ${DEST_REMOTE_NAME} è una coppia bidirezionale. Nessun file è stato toccato."
            exit "$EXIT_ERROR"
        fi
    done
fi

# Fuori dall'albero di destinazione: se stesse dentro, rclone lo
# risincronizzerebbe su sé stesso.
BACKUP_DIR="${DEST_REMOTE_NAME}:_rclone-backup/${REMOTE_NAME}"

build_command() {
    RCLONE_CMD=(
        "$RCLONE_BIN" sync "$SOURCE_PATH" "$DEST_PATH"
        --exclude-from "$RCLONE_EXCLUDE_FILE"
        --create-empty-src-dirs
        --fast-list
        --max-delete "$SYNC_MAX_DELETE"
        --backup-dir "$BACKUP_DIR"
        --checkers=16
        --transfers=8
        --retries 3
        --low-level-retries 20
        --retries-sleep 5s
        --drive-chunk-size=128M
        --drive-pacer-min-sleep=10ms
        --tpslimit 10
        --tpslimit-burst 10
    )

    if [ -n "$RCLONE_EXCLUDE_EXTRA" ]; then
        RCLONE_CMD+=( --exclude-from "$RCLONE_EXCLUDE_EXTRA" )
    fi

    if [ -n "${EXTRA_SYNC_FLAGS:-}" ]; then
        read -r -a extra_flags <<< "$EXTRA_SYNC_FLAGS"
        RCLONE_CMD+=( "${extra_flags[@]}" )
    fi
}

build_command

last_error_lines() { # output, quante righe
    printf '%s\n' "$1" | strip_ansi | grep -v '^$' | tail -n "${2:-3}"
}

handle_sync_failure() { # rc, output
    local rc="$1"
    local out="$2"
    local class streak

    log_error "Rclone sync fallito (exit ${rc})."
    log_text ERROR "$(last_error_lines "$out" 40)"

    class="$(classify_bisync_failure "$rc" "$out")"
    log_info "Classificazione dell'errore: ${class}."

    case "$class" in
        network|rate_limit)
            streak=$(record_failure)
            log_info "Rete o quota non disponibili: rinvio silenzioso (tentativo ${streak})."
            exit "$EXIT_TEMPFAIL"
            ;;
        auth)
            streak=$(record_failure)
            log_warn "Credenziali non valide al tentativo ${streak}: rinvio."
            if [ "$streak" -ge 6 ]; then
                notify_event sync_auth CRITICAL \
                    "${REMOTE_NAME}: le credenziali non risultano più valide per il backup su ${DEST_REMOTE_NAME}. Rinnova con:
rclone config reconnect ${REMOTE_NAME}:

Il backup continua a riprovare da solo."
            fi
            exit "$EXIT_TEMPFAIL"
            ;;
        too_many_deletes)
            log_critical "Cancellazioni bloccate: il backup non è stato toccato."
            notify_event sync_maxdelete CRITICAL \
                "${REMOTE_NAME} -> ${DEST_REMOTE_NAME}: il backup avrebbe rimosso più di ${SYNC_MAX_DELETE} file e la cancellazione è stata bloccata. Il backup è intatto; nessun file verrà cancellato in massa. Verifica la sorgente: se la cancellazione è voluta, imposta SYNC_MAX_DELETE nel file .env dell'istanza."
            exit "$EXIT_ERROR"
            ;;
        *)
            streak=$(record_failure)
            notify_event sync_error ERROR \
                "${REMOTE_NAME} -> ${DEST_REMOTE_NAME}: il backup non è riuscito (exit ${rc}). Ultime righe:
$(last_error_lines "$out" 3)

Il sistema riprova automaticamente. Log: ${LOG_FILE}"
            log_warn "Errore non classificato: rinvio (tentativo ${streak})."
            exit "$EXIT_TEMPFAIL"
            ;;
    esac
}

on_success() { # output
    record_success
    notify_clear sync_error
    notify_clear sync_auth
    notify_clear sync_maxdelete
    log_info "Rclone sync completato (exit 0)."
    log_summary "$1"
    if [ "$LOG_FULL_ON_SUCCESS" = "1" ] || [ "$DEBUG_MODE" -eq 1 ]; then
        log_text INFO "$1"
    fi
}

# --- Lock su entrambi gli endpoint -----------------------------------------
# L'ordine è alfabetico sul nome del remote, così due backup in direzioni
# opposte non possono incastrarsi (deadlock).
if [ "$REMOTE_NAME" = "$DEST_REMOTE_NAME" ]; then
    # Stesso remote (es. test o sync interno): un solo lock, altrimenti il
    # secondo flock sullo stesso file bloccherebbe sé stesso.
    LOCK_FIRST_NAME="$REMOTE_NAME"
    LOCK_SECOND_NAME=""
elif [[ "$REMOTE_NAME" < "$DEST_REMOTE_NAME" ]]; then
    LOCK_FIRST_NAME="$REMOTE_NAME"
    LOCK_SECOND_NAME="$DEST_REMOTE_NAME"
else
    LOCK_FIRST_NAME="$DEST_REMOTE_NAME"
    LOCK_SECOND_NAME="$REMOTE_NAME"
fi
LOCK_FIRST="$(lock_dir_for "$LOCK_FIRST_NAME")/remote-${LOCK_FIRST_NAME}.lock"
if [ -n "$LOCK_SECOND_NAME" ]; then
    LOCK_SECOND="$(lock_dir_for "$LOCK_SECOND_NAME")/remote-${LOCK_SECOND_NAME}.lock"
else
    LOCK_SECOND=""
fi

mkdir -p "$(dirname "$LOCK_FIRST")" 2>/dev/null || true
[ -n "$LOCK_SECOND" ] && mkdir -p "$(dirname "$LOCK_SECOND")" 2>/dev/null || true

# Corpo della sincronizzazione: lock specifico (FD 200) + esecuzione.
sync_body() {
    log_info "Tentativo di acquisizione lock specifico per sync per ${REMOTE_NAME}."
    if ! acquire_operation_lock; then
        log_warn "Rinvio (exit 75): sync già in esecuzione per ${REMOTE_NAME}."
        exit "$EXIT_TEMPFAIL"
    fi

    log_info "Lock sync acquisito. Avvio rclone sync ${REMOTE_NAME} -> ${DEST_REMOTE_NAME}."
    log_debug "Comando: ${RCLONE_CMD[*]}"

    run_rclone "${RCLONE_CMD[@]}"
    if [ "$RCLONE_RC" -ne 0 ]; then
        handle_sync_failure "$RCLONE_RC" "$RCLONE_OUTPUT"
    else
        on_success "$RCLONE_OUTPUT"
    fi
}

(
    exec 201>"$LOCK_FIRST"
    log_info "Tentativo di acquisizione lock generale per ${LOCK_FIRST_NAME}."
    if ! acquire_remote_lock; then
        log_warn "Rinvio (exit 75): lock generale occupato per ${LOCK_FIRST_NAME} (attesa ${LOCK_WAIT}s)."
        exit "$EXIT_TEMPFAIL"
    fi

    if [ -n "$LOCK_SECOND" ]; then
        (
            exec 202>"$LOCK_SECOND"
            log_info "Tentativo di acquisizione lock generale per ${LOCK_SECOND_NAME}."
            if ! flock -w "$LOCK_WAIT" 202; then
                log_warn "Rinvio (exit 75): lock generale occupato per ${LOCK_SECOND_NAME} (attesa ${LOCK_WAIT}s)."
                exit "$EXIT_TEMPFAIL"
            fi
            sync_body 200>"$LOCK_FILE_OPERATION"
        )
    else
        sync_body 200>"$LOCK_FILE_OPERATION"
    fi
)
