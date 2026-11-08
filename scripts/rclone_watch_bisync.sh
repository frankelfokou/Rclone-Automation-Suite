#!/bin/bash
#
# rclone_watch_bisync.sh — watcher realtime locale -> Drive.
# Responsabilità: eventi inotify, debounce, gate sui file aperti, intervallo
# minimo tra run, backoff e sospensione su errore critico.
# Le responsabilità condivise sono in scripts/lib/common.sh.
#
# Uso: rclone_watch_bisync.sh <local_path> <remote_path> [debounce_secondi]
#
# Exit code:
#   EXIT_OK (0)         terminazione richiesta (systemd stop)
#   EXIT_CRITICAL (7)   errore critico bisync: richiesto --resync manuale
#   EXIT_TEMPFAIL (75)  watcher sospeso (marker BLOCKED_FILE presente)
#   EXIT_ERROR (1)      errore imprevisto: systemd riavvia

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
    send_notification "$MSG" ERROR
    exit "$EXIT_ERROR"
fi

require_local_dir "$LOCAL_PATH"

if is_blocked "$BLOCKED_FILE"; then
    MSG="Watcher sospeso: presente $BLOCKED_FILE. Eseguire un --resync manuale e rimuovere il file."
    log_watcher_at CRITICAL "$MSG"
    send_notification "$MSG" CRITICAL
    exit "$EXIT_TEMPFAIL"
fi

log_watcher "Avviato: ${LOCAL_PATH} -> ${REMOTE_PATH} (debounce=${DEBOUNCE}s, min_interval=${MIN_INTERVAL}s, eventi=${EVENTI})"

last_run_start=0
backoff="$BACKOFF_START"

# FIFO + inotifywait in background: il loop resta nella shell principale,
# quindi "exit" funziona e il processo inotifywait viene terminato dal trap.
rm -f "$FIFO"
if ! mkfifo "$FIFO"; then
    MSG="Impossibile creare la FIFO $FIFO."
    log_watcher_at ERROR "$MSG"
    send_notification "$MSG" ERROR
    exit "$EXIT_ERROR"
fi

# Lo stderr di inotifywait passa dallo stesso formato degli altri record.
inotifywait -m -r -e "$EVENTI" --format '%w%f' "$LOCAL_PATH" 2> >(
    while IFS= read -r line; do
        log_line_at "$WATCHER_LOG" WARN "inotifywait: $line"
    done
) > "$FIFO" &
INOTIFY_PID=$!

cleanup() {
    kill "$INOTIFY_PID" 2>/dev/null || true
    wait "$INOTIFY_PID" 2>/dev/null || true
    rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

# Apre il lato lettura della FIFO (si sblocca quando il writer è aperto).
exec 3< "$FIFO"

while IFS= read -r -u 3 changed_path; do
    log_watcher "Evento: ${changed_path}"

    # Debounce: assorbe il burst e si resetta a ogni nuovo evento.
    while IFS= read -r -t "$DEBOUNCE" -u 3 _; do
        :
    done

    # Gate file aperti: polling, non attesa di un nuovo evento.
    if ! wait_for_no_open_files "$LOCAL_PATH" "$LSOF_POLL" "$LSOF_MAX_WAIT" "$WATCHER_LOG"; then
        log_watcher_at WARN "File aperti oltre ${LSOF_MAX_WAIT}s: run rinviata."
        backoff="$BACKOFF_START"
        continue
    fi

    # Intervallo minimo tra due run.
    now=$(date +%s)
    elapsed=$((now - last_run_start))
    if [ "$elapsed" -lt "$MIN_INTERVAL" ]; then
        sleep $((MIN_INTERVAL - elapsed))
    fi

    log_watcher "Avvio bisync (evento: ${changed_path})"
    last_run_start=$(date +%s)

    "$BISYNC_SCRIPT" "$LOCAL_PATH" "$REMOTE_PATH"
    rc=$?

    case "$rc" in
        "$EXIT_OK")
            log_watcher "bisync completata (exit 0)."
            backoff="$BACKOFF_START"
            ;;
        "$EXIT_TEMPFAIL")
            log_watcher "bisync rinviata (exit 75): retry tra ${backoff}s."
            sleep "$backoff"
            backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
            ;;
        "$EXIT_CRITICAL")
            log_watcher_at CRITICAL "Bisync in errore critico (exit 7): richiesto --resync manuale, watcher sospeso."
            send_notification "Bisync in errore critico: eseguire --resync manuale, poi rimuovere ${BLOCKED_FILE}." CRITICAL
            mark_blocked "$BLOCKED_FILE"
            exit "$EXIT_CRITICAL"
            ;;
        *)
            log_watcher_at WARN "bisync fallita (exit ${rc}): retry tra ${backoff}s."
            sleep "$backoff"
            backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
            ;;
    esac
done

log_watcher_at WARN "inotifywait terminato: uscita."
exit "$EXIT_ERROR"
