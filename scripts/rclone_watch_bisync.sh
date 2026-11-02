#!/bin/bash

# Watcher con debounce per sincronizzazione in tempo reale (realtime sync)
# Uso: rclone_watch_bisync.sh <local_path> <remote_path> [debounce_secondi]
# Esempio: rclone_watch_bisync.sh /home/frankel/GDrive-F4Frank GDrive-F4Frank: 15
#
# Exit code:
#   0  terminazione richiesta (systemd stop)
#   7  errore critico bisync: richiesto --resync manuale
#   75 watcher sospeso (marker BLOCKED_FILE presente)
#   1  errore imprevisto: systemd riavvia

set -u

LOCAL_PATH="${1:-}"
REMOTE_PATH="${2:-}"
DEBOUNCE="${3:-15}"

MIN_INTERVAL="${MIN_INTERVAL:-45}"
LSOF_POLL="${LSOF_POLL:-2}"
LSOF_MAX_WAIT="${LSOF_MAX_WAIT:-1800}"
BACKOFF_START="${BACKOFF_START:-10}"
BACKOFF_MAX="${BACKOFF_MAX:-300}"
BISYNC_SCRIPT="${BISYNC_SCRIPT:-/home/frankel/.bin/rclone_bisync.sh}"

if [ -z "$LOCAL_PATH" ] || [ -z "$REMOTE_PATH" ]; then
    echo "Uso: $0 <dir_locale> <remote:path> [debounce_secondi]"
    exit 1
fi

# Pulisce l'ambiente da librerie potenzialmente "inquinanti"
unset LD_LIBRARY_PATH

# --- Variabili derivate ---
REMOTE_NAME=$(echo "$REMOTE_PATH" | cut -d':' -f1)
CONF_DIR="/home/frankel/.config/rclone/conf_dir_${REMOTE_NAME}"
WATCHER_LOG="${CONF_DIR}/log_files/watcher-${REMOTE_NAME}.log"
BLOCKED_FILE="${CONF_DIR}/lock_files/bisync-${REMOTE_NAME}.blocked"

# modify: resetta il debounce anche durante scritture lunghe
# create/delete/moved_*: nuove directory, cancellazioni, rename
# attrib: permessi/attributi
EVENTI="modify,close_write,create,delete,moved_to,moved_from,attrib"

# --- Notification Function (stesso trucco DBUS degli script principali) ---
send_notification() {
    local error_msg="$1"
    if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi
    notify-send -u normal \
                -i dialog-error \
                -a "Rclone Watcher" \
                "Rclone Watcher Error: ${REMOTE_NAME}" \
                "$error_msg" || true
}

log_watcher() {
    echo "[$(date)] $1" >> "$WATCHER_LOG" 2>&1 || true
}

# Attende che non ci siano file aperti nella directory locale.
# Il polling è voluto: non si aspetta un nuovo evento inotify, così la sync
# riparte appena l'ultimo file viene chiuso.
# Ritorna 1 se il limite LSOF_MAX_WAIT viene superato.
attendi_file_chiusi() {
    command -v lsof >/dev/null 2>&1 || return 0

    local inizio=$SECONDS
    local aperti

    # Nota: ';' e non '&&'. lsof può restituire un exit code non-zero anche
    # quando stampa file aperti, quindi il test su $aperti va sempre eseguito.
    while aperti=$(lsof +D "$LOCAL_PATH" 2>/dev/null); [ -n "$aperti" ]; do
        if [ $((SECONDS - inizio)) -ge "$LSOF_MAX_WAIT" ]; then
            log_watcher "File aperti dopo ${LSOF_MAX_WAIT}s: rinvio"
            return 1
        fi
        log_watcher "File aperti: attendo ${LSOF_POLL}s"
        sleep "$LSOF_POLL"
    done

    return 0
}

# --- Prerequisito: inotifywait ---
if ! command -v inotifywait >/dev/null 2>&1; then
    ERR_MSG="inotifywait non trovato. Installare inotify-tools (sudo dnf install inotify-tools)."
    echo "$ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

# --- Verifica esistenza directory locale ---
if [ ! -d "$LOCAL_PATH" ]; then
    ERR_MSG="Directory locale '$LOCAL_PATH' non trovata."
    echo "$ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

# --- Crea file di log e directory (log e lock) se mancanti ---
mkdir -p "$CONF_DIR/log_files" "$CONF_DIR/lock_files" 2>/dev/null || true
touch "$WATCHER_LOG" 2>/dev/null || true

if [ -f "$BLOCKED_FILE" ]; then
    MSG="Watcher sospeso: presente $BLOCKED_FILE. Eseguire un --resync manuale e rimuovere il file."
    echo "$MSG" >&2
    log_watcher "$MSG"
    send_notification "$MSG"
    exit 75
fi

log_watcher "Avviato: ${LOCAL_PATH} -> ${REMOTE_PATH} (debounce=${DEBOUNCE}s, min_interval=${MIN_INTERVAL}s, eventi=${EVENTI})"

last_run_start=0
backoff="$BACKOFF_START"

# FIFO + inotifywait in background: il loop resta nella shell principale,
# quindi "exit" funziona e il processo inotifywait viene terminato dal trap.
FIFO="${CONF_DIR}/lock_files/watcher-${REMOTE_NAME}.fifo"
rm -f "$FIFO"
if ! mkfifo "$FIFO"; then
    MSG="Impossibile creare la FIFO $FIFO"
    echo "$MSG" >&2
    log_watcher "$MSG"
    send_notification "$MSG"
    exit 1
fi

inotifywait -m -r -e "$EVENTI" --format '%w%f' "$LOCAL_PATH" 2>>"$WATCHER_LOG" > "$FIFO" &
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
    if ! attendi_file_chiusi; then
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
        0)
            log_watcher "bisync completata"
            backoff="$BACKOFF_START"
            ;;
        75)
            log_watcher "bisync rinviata (75): retry tra ${backoff}s"
            sleep "$backoff"
            backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
            ;;
        7)
            log_watcher "ERRORE CRITICO (7): richiesto --resync manuale"
            send_notification "Bisync in errore critico: eseguire --resync manuale, poi rimuovere ${BLOCKED_FILE}."
            : > "$BLOCKED_FILE"
            exit 7
            ;;
        *)
            log_watcher "bisync fallita (rc=${rc}): retry tra ${backoff}s"
            sleep "$backoff"
            backoff=$(( backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2 ))
            ;;
    esac
done

log_watcher "inotifywait terminato: uscita"
exit 1
