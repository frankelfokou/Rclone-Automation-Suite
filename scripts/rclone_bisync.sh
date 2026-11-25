#!/bin/bash
#
# rclone_bisync.sh — orchestrazione di `rclone bisync`.
# Responsabilità: validare gli argomenti, invocare i lock, applicare i guard
# sugli invarianti, eseguire bisync, classificare gli errori e riparare da solo
# i casi noti (danno sul remote, cancellazioni volute, errori ritentabili).
# Le responsabilità condivise sono in scripts/lib/common.sh.
#
# Uso: rclone_bisync.sh <dir_locale> <remote:path> [--resync] [--force] [--dry-run]
#
# Exit code:
#   0   successo (anche dopo una riparazione automatica)
#   1   errore d'uso o condizione non recuperabile (permessi, disco)
#   7   blocco temporaneo: nuovo tentativo automatico secondo il cooldown
#   75  rinvio: rete assente, lock occupato, file aperti, cooldown in corso

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

USAGE="Uso: $0 <dir_locale> <remote:path> [--resync] [--force] [--dry-run]"

FORCE_RESYNC=0
FORCE_MODE=0
DRY_RUN=0
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        --resync)  FORCE_RESYNC=1 ;;
        --force)   FORCE_MODE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) printf '%s\n' "$USAGE"; exit "$EXIT_OK" ;;
        -*)        log_error "Opzione sconosciuta: $arg"; exit "$EXIT_ERROR" ;;
        *)         POSITIONAL+=("$arg") ;;
    esac
done

require_args "${#POSITIONAL[@]}" 2 "$USAGE"

LOCAL_PATH="${POSITIONAL[0]}"
REMOTE_PATH="${POSITIONAL[1]}"

REMOTE_NAME="$(remote_name_of "$REMOTE_PATH")"
LOG_TAG="BISYNC"
NOTIFY_TITLE="Rclone bisync ${REMOTE_NAME:-?}"
NOTIFY_APP="Rclone Script"

require_remote_path "$REMOTE_PATH" "REMOTE_PATH" "$USAGE"
require_configured_remote "$REMOTE_NAME"

init_rclone_paths "$REMOTE_NAME" "bisync" "bisync-${REMOTE_NAME}.log"
ensure_runtime_dirs
ensure_log_file
redirect_output_to_log

require_local_dir "$LOCAL_PATH"
ensure_local_check_file "$LOCAL_PATH"
require_exclude_files
check_local_write "$LOCAL_PATH"
check_disk_space "$LOCAL_PATH"

# --- Comando di produzione -------------------------------------------------
# Non modificare senza test dedicati (AGENTS.md §9.6 per i nuovi flag).
build_command() {
    RCLONE_CMD=(
        "$RCLONE_BIN" bisync "$LOCAL_PATH" "$REMOTE_PATH"
        --exclude-from "$RCLONE_EXCLUDE_FILE"
        --check-access
        --resilient
        --recover
        --max-lock 2m
        --fast-list
        --fix-case
        --compare modtime
        --conflict-resolve newer
        --conflict-suffix conflict
        --tpslimit 10
        --tpslimit-burst 10
        --checkers=16
        --transfers=8
        --retries 3
        --low-level-retries 20
        --retries-sleep 5s
        --drive-chunk-size=128M
        --drive-pacer-min-sleep=10ms
        --drive-export-formats docx,xlsx,pptx
        --drive-import-formats docx,xlsx,pptx
    )

    if [ -n "$RCLONE_EXCLUDE_EXTRA" ]; then
        RCLONE_CMD+=( --exclude-from "$RCLONE_EXCLUDE_EXTRA" )
    fi

    if [ -n "${EXTRA_BISYNC_FLAGS:-}" ]; then
        read -r -a extra_flags <<< "$EXTRA_BISYNC_FLAGS"
        RCLONE_CMD+=( "${extra_flags[@]}" )
    fi
}

build_command

run_bisync() { # modalità: normal | resync [path1|path2] | force
    local mode="$1"
    local resync_mode="${2:-path1}"
    local -a cmd=( "${RCLONE_CMD[@]}" )

    case "$mode" in
        resync) cmd+=( --resync --resync-mode "$resync_mode" ) ;;
        force)  cmd+=( --force ) ;;
    esac

    [ "$DRY_RUN" -eq 1 ] && cmd+=( --dry-run )

    run_rclone "${cmd[@]}"
}

last_error_lines() { # output, quante righe
    printf '%s\n' "$1" | strip_ansi | grep -v '^$' | tail -n "${2:-3}"
}

# --- Successo --------------------------------------------------------------

on_success() { # output
    local out="$1"
    local was_blocked=0

    is_blocked "$BLOCKED_FILE" && was_blocked=1

    record_success
    state_set filters_hash "$CURRENT_FILTERS_HASH"
    state_del needs_resync
    clear_blocked "$BLOCKED_FILE"

    if [ "$was_blocked" -eq 1 ]; then
        notify_event resumed WARN \
            "${REMOTE_NAME}: sincronizzazione ripresa automaticamente dopo un blocco. Nessuna azione richiesta."
    fi

    notify_clear streak
    notify_clear damage
    notify_clear guard
    notify_clear blocked

    log_info "Rclone bisync completato (exit 0)."
    log_summary "$out"

    if [ "$LOG_FULL_ON_SUCCESS" = "1" ] || [ "$DEBUG_MODE" -eq 1 ]; then
        log_text INFO "$out"
    fi
}

# --- Blocco temporaneo -----------------------------------------------------

block_with_cooldown() { # motivo
    local reason="$1"
    local attempts retry_after minutes

    attempts=$(( $(blocked_attempts "$BLOCKED_FILE") + 1 ))
    blocked_set "$BLOCKED_FILE" "$reason" "$attempts"
    retry_after="$(blocked_field "$BLOCKED_FILE" retry_after)"
    minutes=$(( (retry_after - $(date +%s)) / 60 ))
    [ "$minutes" -lt 1 ] && minutes=1

    log_critical "Blocco temporaneo (tentativo ${attempts}, motivo: ${reason}). Nuovo tentativo automatico tra ${minutes} minuti."

    # La notifica di ripresa deve poter partire anche se il testo è identico
    # a quello di un blocco precedente.
    notify_clear resumed

    notify_event blocked CRITICAL \
        "${REMOTE_NAME}: sincronizzazione sospesa (motivo: ${reason}). Nuovo tentativo automatico tra ${minutes} minuti. Non serve alcuna azione: il sistema riprova da solo."

    exit "$EXIT_CRITICAL"
}

notify_streak() { # streak, output
    local streak="$1"
    local out="$2"

    [ "$streak" -ge 3 ] || return 0

    notify_event streak ERROR \
        "${REMOTE_NAME}: ${streak} sincronizzazioni consecutive fallite. Ultimo errore:
$(last_error_lines "$out" 3)

Il sistema continua a riprovare da solo. Se il problema persiste, controlla:
journalctl --user -u rclone-bisync@$(printf '%s' "$REMOTE_NAME" | tr '[:upper:]' '[:lower:]')"
}

# --- Riparazione automatica ------------------------------------------------

attempt_recovery() { # modalità, motivo, messaggio di esito, [resync_mode]
    local mode="$1"
    local reason="$2"
    local success_message="$3"
    local resync_mode="${4:-path1}"

    log_warn "Tentativo di riparazione automatica (${mode}, ${resync_mode})."
    run_bisync "$mode" "$resync_mode"

    if [ "$RCLONE_RC" -eq 0 ]; then
        log_info "Riparazione riuscita (${mode})."
        on_success "$RCLONE_OUTPUT"
        notify_event "$reason" WARN "$success_message"
        exit "$EXIT_OK"
    fi

    log_error "Riparazione fallita (exit ${RCLONE_RC})."
    log_text ERROR "$(last_error_lines "$RCLONE_OUTPUT" 10)"
    block_with_cooldown "$reason"
}

# Politica: una cancellazione di massa non viene mai propagata in automatico.
# Il resync copia solo ciò che manca (non cancella), quindi in ogni caso
# ripristina i file mancanti senza distruggere nulla.
handle_too_many_deletes() { # output
    local out="$1"
    local analysis

    analysis="$(bisync_damage_analysis "$LOCAL_PATH" "$REMOTE_PATH" "$REMOTE_NAME")"
    log_warn "Cancellazioni bloccate da rclone: analisi del danno = ${analysis}."

    case "$analysis" in
        remote_damaged)
            attempt_recovery resync "damage" \
                "${REMOTE_NAME}: il remote aveva perso file mentre il locale era intatto. File ripristinati automaticamente dal locale. Nessuna azione richiesta." \
                path1
            ;;
        local_shrunk|both_shrunk)
            attempt_recovery resync "damage" \
                "${REMOTE_NAME}: molti file risultavano cancellati e la cancellazione di massa è stata bloccata per sicurezza. I file mancanti sono stati ripristinati dal remote. Se la cancellazione era voluta, esegui manualmente: rclone_bisync.sh ${LOCAL_PATH} ${REMOTE_PATH} --force" \
                path2
            ;;
        *)
            log_critical "Impossibile stabilire quale lato sia danneggiato: non propagare nulla."
            log_text ERROR "$(last_error_lines "$out" 10)"
            notify_event damage CRITICAL \
                "${REMOTE_NAME}: cancellazione di massa bloccata e origine non determinabile. Nessun file è stato rimosso. Il sistema ritenta da solo; log: ${LOG_FILE}"
            block_with_cooldown "too_many_deletes_unknown"
            ;;
    esac
}

# --- Gestione del fallimento ----------------------------------------------

handle_bisync_failure() { # rc, output
    local rc="$1"
    local out="$2"
    local class streak

    log_error "Rclone bisync fallito (exit ${rc})."
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
                notify_event auth CRITICAL \
                    "${REMOTE_NAME}: le credenziali Google non risultano più valide. Rinnova con:
rclone config reconnect ${REMOTE_NAME}:

Il sistema continua a riprovare da solo ogni 24 ore."
            fi
            exit "$EXIT_TEMPFAIL"
            ;;
        retryable)
            streak=$(record_failure)
            log_warn "Errore ritentabile senza --resync: rinvio (exit 75)."
            notify_streak "$streak" "$out"
            exit "$EXIT_TEMPFAIL"
            ;;
        too_many_deletes)
            handle_too_many_deletes "$out"
            ;;
        critical)
            attempt_recovery resync "critical" \
                "${REMOTE_NAME}: errore critico riparato con un resync automatico. Nessuna azione richiesta."
            ;;
        *)
            streak=$(record_failure)
            log_warn "Errore non classificato: rinvio (exit 75)."
            notify_streak "$streak" "$out"
            exit "$EXIT_TEMPFAIL"
            ;;
    esac
}

# --- Preparazione ----------------------------------------------------------

CURRENT_FILTERS_HASH="$(filters_signature "$RCLONE_EXCLUDE_FILE" ${RCLONE_EXCLUDE_EXTRA:+"$RCLONE_EXCLUDE_EXTRA"})"
SAVED_FILTERS_HASH="$(state_get filters_hash)"
RESYNC=0

if [ "$FORCE_RESYNC" -eq 1 ]; then
    RESYNC=1
    log_info "Resync richiesto da riga di comando."
elif [ -z "$SAVED_FILTERS_HASH" ]; then
    # Nessuna firma salvata: se la coppia ha già dei listing adotta la firma
    # corrente senza resync, altrimenti è davvero il primo run.
    if bisync_prev_counts "$REMOTE_NAME" >/dev/null 2>&1; then
        log_info "Adozione della firma dei filtri corrente (coppia già inizializzata)."
        state_set filters_hash "$CURRENT_FILTERS_HASH"
    else
        RESYNC=1
        log_info "Primo avvio della coppia: resync iniziale."
    fi
elif [ "$SAVED_FILTERS_HASH" != "$CURRENT_FILTERS_HASH" ]; then
    RESYNC=1
    log_warn "I file di esclusione sono cambiati: resync necessario per riallineare i listing."
fi

if [ -f "${STATE_DIR}/needs_resync" ]; then
    RESYNC=1
    log_warn "Guard ha modificato la struttura della coppia: resync necessario."
fi

if is_blocked "$BLOCKED_FILE"; then
    if blocked_is_due "$BLOCKED_FILE"; then
        RESYNC=1
        log_warn "Cooldown scaduto: nuovo tentativo di riparazione automatica."
    else
        retry_after="$(blocked_field "$BLOCKED_FILE" retry_after)"
        when="$(date -d "@${retry_after}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$retry_after")"
        log_info "Bloccato fino a ${when}: rinvio senza tentativi."
        exit "$EXIT_TEMPFAIL"
    fi
fi

# Il marker sul remote serve a --check-access: se manca e la rete è assente
# non è un errore definitivo, è un rinvio silenzioso (nessuna notifica).
if ! remote_is_reachable "$REMOTE_NAME"; then
    log_info "Remote '${REMOTE_NAME}' non raggiungibile: rinvio (exit 75)."
    exit "$EXIT_TEMPFAIL"
fi
ensure_remote_check_file "$REMOTE_PATH"

log_info "Inizio safety check LSOF per file aperti."
if ! wait_for_no_open_files "$LOCAL_PATH" "$LSOF_WAIT_SECONDS" \
        "$((LSOF_WAIT_SECONDS * LSOF_MAX_RETRIES))"; then
    exit "$EXIT_TEMPFAIL"
fi
log_info "Safety check LSOF completato."

# --- Esecuzione ------------------------------------------------------------

(
    log_info "Tentativo di acquisizione lock generale per ${REMOTE_NAME}."
    if ! acquire_remote_lock; then
        log_warn "Rinvio (exit 75): lock generale occupato per ${REMOTE_NAME} (attesa ${LOCK_WAIT}s)."
        exit "$EXIT_TEMPFAIL"
    fi

    (
        log_info "Tentativo di acquisizione lock specifico per bisync per ${REMOTE_NAME}."
        if ! acquire_operation_lock; then
            log_warn "Rinvio (exit 75): bisync già in esecuzione per ${REMOTE_NAME}."
            exit "$EXIT_TEMPFAIL"
        fi

        log_info "Lock bisync acquisito."

        # Invarianti della coppia: applicati prima della sync, sotto lock.
        guard_enforce "$LOCAL_PATH" "$REMOTE_PATH"
        if [ "$GUARD_CHANGED" -eq 1 ]; then
            RESYNC=1
            state_set needs_resync "1"
            notify_event guard WARN \
                "${REMOTE_NAME}: struttura riallineata automaticamente (${GUARD_SUMMARY}). I file rimossi restano in quarantena per ${QUARANTINE_DAYS} giorni."
        fi
        guard_quarantine_prune

        if [ "$RESYNC" -eq 1 ]; then
            log_info "Avvio rclone bisync in modalità resync (Path1 = locale)."
            run_bisync resync
        elif [ "$FORCE_MODE" -eq 1 ]; then
            log_info "Avvio rclone bisync con --force (richiesto da riga di comando)."
            run_bisync force
        else
            log_info "Avvio rclone bisync per ${REMOTE_NAME}."
            run_bisync normal
        fi

        if [ "$RCLONE_RC" -ne 0 ]; then
            handle_bisync_failure "$RCLONE_RC" "$RCLONE_OUTPUT"
        else
            on_success "$RCLONE_OUTPUT"
        fi
    ) 200>"$LOCK_FILE_OPERATION"
) 201>"$LOCK_FILE_REMOTE"
