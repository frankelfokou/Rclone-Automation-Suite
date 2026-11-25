#!/bin/bash
#
# rclone_watch_bisync.sh — watcher realtime locale -> Drive.
# Responsabilità: eventi inotify, debounce, gate sui file aperti, intervallo
# minimo tra run, retry con backoff e cooldown.
# Le responsabilità condivise sono in scripts/lib/common.sh.
#
# Uso: rclone_watch_bisync.sh <local_path> <remote_path> [debounce_secondi]
#
# Exit code:
#   EXIT_OK (0)         terminazione richiesta (systemd stop)
#   EXIT_ERROR (1)      inotifywait terminato o errore imprevisto: systemd riavvia
#
# Il watcher non si sospende mai per un errore di bisync: il cooldown è
# calcolato da rclone_bisync.sh e registrato nel marker BLOCKED_FILE, che
# qui viene solo letto per sapere quando ritentare.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

LOCAL_PATH="${1:-}"
REMOTE_PATH="${2:-}"
DEBOUNCE="${3:-15}"

MIN_INTERVAL="${MIN_INTERVAL:-45}"
LSOF_POLL="${LSOF_POLL:-2}"
LSOF_MAX_WAIT="${LSOF_MAX_WAIT:-1800}"
BACKOFF_START="${BACKOFF_START:-10}"
BACKOFF_MAX="${BACKOFF_MAX:-300}"
BISYNC_SCRIPT="${BISYNC_SCRIPT:-/home/frankel/.bin/rclone_bisync.sh}"

# Percorsi transitori che non devono innescare una sincronizzazione.
# inotifywait --exclude accetta una regex POSIX estesa sul percorso completo.
WATCH_EXCLUDE="${WATCH_EXCLUDE:-(^|/)\.git/|(^|/)\.trash/|(^|/)\.obsidian/workspace(-mobile)?\.json$|(^|/)\.DS_Store$|(^|/)\..*\.sw[px]$|(^|/)\.~lock\.|~$|\.tmp$|\.part$|\.partial$|\.crdownload$|\.download$|\.!ut$}"

LOG_TAG="WATCH"

if [ -z "$LOCAL_PATH" ] || [ -z "$REMOTE_PATH" ]; then
    log_error "Uso: $0 <dir_locale> <remote:path> [debounce_secondi]"
    exit "$EXIT_ERROR"
fi

REMOTE_NAME="$(remote_name_of "$REMOTE_PATH")"
NOTIFY_TITLE="Rclone watcher ${REMOTE_NAME:-?}"
NOTIFY_APP="Rclone Watcher"

CONF_DIR="$(conf_dir_for "$REMOTE_NAME")"
LOG_FILES_DIR="$(log_dir_for "$REMOTE_NAME")"
LOCK_FILES_DIR="$(lock_dir_for "$REMOTE_NAME")"
STATE_DIR="$(state_dir_for "$REMOTE_NAME")"
WATCHER_LOG="${LOG_FILES_DIR}/watcher-${REMOTE_NAME}.log"
BLOCKED_FILE="$(blocked_file_for "$REMOTE_NAME")"
FIFO="${LOCK_FILES_DIR}/watcher-${REMOTE_NAME}.fifo"

# modify: resetta il debounce anche durante scritture lunghe
# create/delete/moved_*: nuove directory, cancellazioni, rename
# attrib: permessi/attributi
EVENTI="modify,close_write,create,delete,moved_to,moved_from,attrib"

log_watcher() { # messaggio: record INFO, solo file
    log_line "$WATCHER_LOG" "$*"
}

log_watcher_at() { # livello, messaggio: record nel file; da WARN anche sul journal
    local level="$1"
    shift
    log_line_at "$WATCHER_LOG" "$level" "$*"
    case "$level" in
        WARN|ERROR|CRITICAL) log_text "$level" "$*" ;;
    esac
}

# --- Preparazione ---
ensure_runtime_dirs
touch "$WATCHER_LOG" 2>/dev/null || true

if ! command -v inotifywait >/dev/null 2>&1; then
    MSG="inotifywait non trovato. Installare inotify-tools (sudo dnf install inotify-tools)."
    log_watcher_at ERROR "$MSG"
    notify_event watcher_dep CRITICAL "$MSG"
    exit "$EXIT_ERROR"
fi

require_local_dir "$LOCAL_PATH"

log_watcher "Avviato: ${LOCAL_PATH} -> ${REMOTE_PATH} (debounce=${DEBOUNCE}s, min_interval=${MIN_INTERVAL}s)"

last_run_start=0
backoff="$BACKOFF_START"
retry_at=0

# FIFO + inotifywait in background: il loop resta nella shell principale,
# quindi "exit" funziona e il processo inotifywait viene terminato dal trap.
rm -f "$FIFO"
if ! mkfifo "$FIFO"; then
    MSG="Impossibile creare la FIFO $FIFO."
    log_watcher_at ERROR "$MSG"
    notify_event watcher_fifo CRITICAL "$MSG"
    exit "$EXIT_ERROR"
fi

# Lo stderr di inotifywait passa dallo stesso formato degli altri record.
inotifywait -m -r -e "$EVENTI" --exclude "$WATCH_EXCLUDE" \
            --format '%w%f' "$LOCAL_PATH" 2> >(
    while IFS= read -r line; do
        log_line_at "$WATCHER_LOG" WARN "inotifywait: $line"
    done
) > "$FIFO" &
INOTIFY_PID=$!

cleanup() {
    # Evita la ricorsione: il trap EXIT non deve richiamare cleanup.
    trap - EXIT INT TERM
    kill "$INOTIFY_PID" 2>/dev/null || true
    wait "$INOTIFY_PID" 2>/dev/null || true
    rm -f "$FIFO"
}
# Su TERM/INT si esce davvero: senza l'exit esplicito il ciclo continuerebbe
# a girare (in backoff non c'è alcuna read che si sblocchi).
trap cleanup EXIT
trap 'exit 0' INT TERM

# Apre il lato lettura della FIFO (si sblocca quando il writer è aperto).
exec 3< "$FIFO"

# Ritardo del prossimo tentativo dopo un errore.
schedule_retry() { # secondi, motivo
    local delay="$1"
    local reason="$2"
    retry_at=$(( $(date +%s) + delay ))
    log_watcher_at WARN "bisync rinviata (${reason}): nuovo tentativo automatico tra ${delay}s."
}

# Ripristina l'intervallo di retry minimo dopo un successo.
reset_backoff() {
    backoff="$BACKOFF_START"
    retry_at=0
}

while true; do
    if [ "$retry_at" -gt 0 ]; then
        remaining=$(( retry_at - $(date +%s) ))
        if [ "$remaining" -gt 0 ]; then
            # Durante il backoff gli eventi vengono accorpati: il run parte
            # comunque alla scadenza, senza martellare il remote.
            if IFS= read -r -t "$remaining" -u 3 changed_path; then
                log_watcher "Evento durante il backoff accorpato: ${changed_path}"
            else
                # rc > 128 = timeout (normale); rc <= 128 = EOF, cioè
                # inotifywait è terminato: inutile restare in attesa.
                read_rc=$?
                if [ "$read_rc" -le 128 ]; then
                    log_watcher_at WARN "FIFO chiusa durante il backoff: uscita."
                    break
                fi
            fi
            continue
        fi
        log_watcher "Backoff scaduto: nuovo tentativo automatico."
    else
        if ! IFS= read -r -u 3 changed_path; then
            break
        fi
        log_watcher "Evento: ${changed_path}"

        # Debounce: assorbe il burst e si resetta a ogni nuovo evento.
        while IFS= read -r -t "$DEBOUNCE" -u 3 _; do
            :
        done
        changed_path="(burst di eventi)"

        if ! kill -0 "$INOTIFY_PID" 2>/dev/null; then
            log_watcher_at WARN "inotifywait terminato: uscita (systemd riavvia il watcher)."
            break
        fi
    fi

    # Gate file aperti: polling, non attesa di un nuovo evento.
    if ! wait_for_no_open_files "$LOCAL_PATH" "$LSOF_POLL" "$LSOF_MAX_WAIT" "$WATCHER_LOG"; then
        log_watcher_at WARN "File aperti oltre ${LSOF_MAX_WAIT}s: run rinviata."
        schedule_retry "$backoff" "file ancora aperti"
        backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
        continue
    fi

    # Intervallo minimo tra due run.
    elapsed=$(( $(date +%s) - last_run_start ))
    if [ "$elapsed" -lt "$MIN_INTERVAL" ]; then
        sleep $(( MIN_INTERVAL - elapsed ))
    fi

    log_watcher "Avvio bisync (evento: ${changed_path})"
    last_run_start=$(date +%s)

    "$BISYNC_SCRIPT" "$LOCAL_PATH" "$REMOTE_PATH"
    rc=$?

    case "$rc" in
        0)
            log_watcher "bisync completata (exit 0)."
            reset_backoff
            ;;
        75)
            # Cooldown deciso da rclone_bisync.sh: rispettarlo senza toccare
            # il backoff, così non si consumano tentativi inutili.
            if is_blocked "$BLOCKED_FILE" && ! blocked_is_due "$BLOCKED_FILE"; then
                retry_at="$(blocked_field "$BLOCKED_FILE" retry_after)"
                # Marker corrotto o legacy: valore non numerico -> ignora.
                case "$retry_at" in ''|*[!0-9]*) retry_at=0 ;; esac
                when="$(date -d "@${retry_at}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$retry_at")"
                log_watcher "bisync in cooldown fino a ${when}."
            else
                schedule_retry "$backoff" "rinvio"
                backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
            fi
            ;;
        7)
            # rclone_bisync.sh ha già scritto il marker con il cooldown:
            # il watcher resta vivo e ritenta alla scadenza.
            retry_at="$(blocked_field "$BLOCKED_FILE" retry_after)"
            case "$retry_at" in ''|*[!0-9]*) retry_at=$(( $(date +%s) + BACKOFF_MAX )) ;; esac
            when="$(date -d "@${retry_at}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$retry_at")"
            log_watcher_at CRITICAL "Bisync in errore critico (exit 7): riparazione automatica in corso, nuovo tentativo alle ${when}."
            ;;
        *)
            log_watcher_at WARN "bisync fallita (exit ${rc}): nuovo tentativo automatico tra ${backoff}s."
            notify_event watcher_error ERROR \
                "${REMOTE_NAME}: il watcher non riesce a completare la sincronizzazione (exit ${rc}). Il sistema continua a riprovare da solo; dettagli in ${WATCHER_LOG}."
            schedule_retry "$backoff" "errore ${rc}"
            backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
            ;;
    esac
done

log_watcher_at WARN "inotifywait terminato: uscita (systemd riavvia il watcher)."
exit "$EXIT_ERROR"
