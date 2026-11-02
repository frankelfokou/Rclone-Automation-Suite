#!/bin/bash

# CRONTAB EXAMPLE:

# */15 * * * * /home/frankel/.personal/rclone_google_drive_sync/test_setup_rclone_bisync.sh /home/frankel/GDrive-F4Frank GDrive-F4Frank: 

set -e
set -o pipefail

# Pulisce l'ambiente da librerie potenzialmente "inquinanti" (es. da AppImage come Tabby)
unset LD_LIBRARY_PATH

# --- Notification Function ---
send_notification() {
    local error_msg="$1"
    
    # TRUCCO PER CRON / SYSTEMD:
    # Se lo script è lanciato in background, potrebbe non sapere dove mandare la notifica.
    # Su Fedora (systemd), il bus dell'utente si trova sempre qui:
    if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi

    # Invia la notifica
    # -u normal: La notifica scompare dopo un timeout e va nel centro notifiche
    # -i dialog-error: Icona di errore standard
    notify-send -u normal \
                -i dialog-error \
                -a "Rclone Script" \
                "Rclone bisync Error: ${REMOTE_NAME:-Setup}" \
                "$error_msg" || true
}

log_message() {
    if [ "$DEBUG_MODE" -eq 1 ]; then
        echo "$1" >&2
    fi
    # In modalità normale, l'output viene implicitamente scartato perché non c'è un echo.
}

# --- Debug Mode & Conditional Logging ---
DEBUG_MODE=0

if [ "$DEBUG_MODE" == "1" ]; then
    echo "--- DEBUG MODE ENABLED: L'output verrà mostrato a schermo e non nel file di log. ---"
fi

# --- Configuration & Arguments ---
LOCAL_PATH="$1"
REMOTE_PATH="$2"

# Controllo del numero di argomenti
if [ "$#" -ne 2 ]; then
    ERR_MSG="Numero di argomenti non corretto.
Uso: $0 <dir_locale> <remote:path>"  # rclone /home/frankel/GDrive-F4Frank GDrive-F4Frank
    # Usiamo la funzione di log condizionale
    log_message "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

# Controllo formato del remote
if [[ ! "$REMOTE_PATH" == *":"* ]]; then
    ERR_MSG="Il percorso remoto '$REMOTE_PATH' non è valido. Deve contenere ':' (es. 'MyRemote:path/to/dir')."
    log_message "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

# Controlla l'esistenza del remote
REMOTE_NAME=$(echo "$REMOTE_PATH" | cut -d':' -f1)
if ! /usr/bin/rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    ERR_MSG="Il remote '$REMOTE_NAME' non è configurato in rclone."
    log_message "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

CONF_DIR="/home/frankel/.config/rclone/conf_dir_${REMOTE_NAME}"
LOCK_FILE_BISYNC="${CONF_DIR}/lock_files/bisync-${REMOTE_NAME}.lock"
LOCK_FILE_REMOTE="${CONF_DIR}/lock_files/remote-${REMOTE_NAME}.lock"
LOG_FILE="${CONF_DIR}/log_files/bisync-${REMOTE_NAME}.log"
BLOCKED_FILE="${CONF_DIR}/lock_files/bisync-${REMOTE_NAME}.blocked"

# Attesa massima sul lock remoto (secondi)
LOCK_WAIT="${LOCK_WAIT:-120}"
# Safety check lsof: attesa tra un tentativo e l'altro e numero di tentativi
LSOF_WAIT_SECONDS="${LSOF_WAIT_SECONDS:-10}"
LSOF_MAX_RETRIES="${LSOF_MAX_RETRIES:-18}"

# Controlla e crea le directory di configurazione, log e lock se non esistono.
if [ ! -d "$CONF_DIR/log_files" ] || [ ! -d "$CONF_DIR/lock_files" ]; then
    log_message "Creazione directory log/lock in '$CONF_DIR'..."
    if ! mkdir -p "$CONF_DIR/log_files" "$CONF_DIR/lock_files"; then
        # Se la creazione fallisce, invia una notifica ed esce.
        ERR_MSG="Impossibile creare le directory in '$CONF_DIR'. Controllare i permessi."
        log_message "ERRORE CRITICO: $ERR_MSG"
        send_notification "$ERR_MSG"
        exit 1
    fi
fi

# Controlla che il file di log esista
if [ ! -f "$LOG_FILE" ]; then
    if ! touch "$LOG_FILE"; then
        ERR_MSG="Impossibile creare il file di log: '$LOG_FILE'. Controllare i permessi."
        echo "ERRORE CRITICO: $ERR_MSG"
        send_notification "$ERR_MSG"
        exit 1
    fi
fi

# --- LOG REDIRECTION (solo in modalità normale) ---
if [ "$DEBUG_MODE" -eq 0 ]; then
    # In modalità normale (cron), reindirizza tutto l'output al file di log.
    exec >> "$LOG_FILE" 2>&1
fi

# Controllo dell'esistenza della directory locale
if [ ! -d "$LOCAL_PATH" ]; then
    ERR_MSG="La directory locale '$LOCAL_PATH' non esiste."
    echo "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

# Controlla l'esistenza del file RCLONE_TEST
if [ ! -f "$LOCAL_PATH/RCLONE_TEST" ]; then
    if ! touch "$LOCAL_PATH/RCLONE_TEST"; then
        ERR_MSG="Impossibile creare '$LOCAL_PATH/RCLONE_TEST'. Controllare i permessi"
        echo "ERRORE CRITICO: $ERR_MSG"
        send_notification "$ERR_MSG"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# SAFETY CHECK: BUSY WAIT (Prima dei Lock)
# ------------------------------------------------------------------------------
# Lo mettiamo QUI, fuori dai lock.
# Motivo: Se entriamo in un loop di attesa dentro il "flock 201" (che è bloccante),
# i successivi job di cron (es. tra 15 min) si accoderebbero restando appesi in RAM.
# Facendo il controllo qui, se c'è un file aperto, lo script aspetta o esce
# senza bloccare la coda dei lock per il futuro.

WAIT_SECONDS="$LSOF_WAIT_SECONDS"
MAX_RETRIES="$LSOF_MAX_RETRIES"

echo "[$(date)] Inizio safety check LSOF per file aperti" >&2
if command -v lsof >/dev/null 2>&1; then
    retry_count=0
    
    # Ciclo finché lsof trova file aperti (exit code 0 = trovati)
    while open_files=$(lsof +D "$LOCAL_PATH" 2>/dev/null); [ -n "$open_files" ]; do
        log_message "$(echo "$open_files" | awk 'NR>1 {print " - " $9}')"
        if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
            echo "[$(date)] DEFER: file aperti dopo $((MAX_RETRIES * WAIT_SECONDS))s. Rinvio (75)." >&2
            echo "[$(date)] I seguenti file erano ancora aperti:" >&2
            echo "$open_files" >&2
            # 75 = EX_TEMPFAIL: non è un successo né un errore definitivo.
            # Il watcher/timer riproveranno appena i file saranno chiusi.
            exit 75
        fi
        
        log_message "File in uso rilevati. Attesa ${WAIT_SECONDS}s... ($((retry_count+1))/$MAX_RETRIES). File aperti:"
        # Logga solo i nomi dei file per brevità
        log_message "$(echo "$open_files" | awk 'NR>1 {print " - " $9}')"
        sleep "$WAIT_SECONDS"
        ((++retry_count))
    done
fi
echo "[$(date)] Safety check LSOF avvenuto con successo" >&2

# Il controllo "modifiche nell'ultimo minuto" (find -mmin -1) è stato rimosso:
# subito dopo un salvataggio è sempre vero e rendeva impossibile qualsiasi
# sincronizzazione innescata da un evento. La quiete della directory è
# garantita dal debounce del watcher.

# ------------------------------------------------------------------------------
# FINE SAFETY CHECK
# ------------------------------------------------------------------------------


# --- Main Logic with Locking ---
( # Lock per il remote (FD 201) con attesa limitata.

    echo "[$(date)] Tentativo di acquisizione lock generale per ${REMOTE_NAME}" >&2
    if ! flock -w "$LOCK_WAIT" 201; then
        echo "[$(date)] DEFER: lock generale per ${REMOTE_NAME} occupato (attesa ${LOCK_WAIT}s)." >&2
        exit 75
    fi

    ( # Lock non bloccante specifico per bisync (FD 200)

        echo "[$(date)] Tentativo di acquisizione lock specifico per bisync per ${REMOTE_NAME}" >&2
        flock -n 200 || {
            echo "[$(date)] DEFER: bisync già in esecuzione per ${REMOTE_NAME}." >&2
            exit 75
        }

        echo "[$(date)] Lock bisync acquisito. Avvio rclone bisync per ${REMOTE_NAME}." >&2
        
        RCLONE_CMD=(
            /usr/bin/rclone bisync "$LOCAL_PATH" "$REMOTE_PATH"
            --exclude-from /home/frankel/.config/rclone/exclude_patterns.txt
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

        # --- Execute and Handle Errors ---
        RCLONE_RC=0
        RCLONE_OUTPUT=$("${RCLONE_CMD[@]}" 2>&1) || RCLONE_RC=$?
        if [ "$RCLONE_RC" -ne 0 ]; then
            # --- GESTIONE PRIMO ERRORE ---
            echo "[$(date)] Rclone bisync failed (exit ${RCLONE_RC})" >&2
            echo "${RCLONE_OUTPUT}" >&2

            echo "[$(date)] Attempting recovery..." >&2

            # Check Remote Connectivity
            if ! /usr/bin/rclone about "${REMOTE_NAME}:" &>/dev/null; then
                ERR="Remote '${REMOTE_NAME}' is unreachable. Check internet or token."
                echo "[$(date)] CRITICAL: $ERR" >&2
                send_notification "$ERR"
                # Errore di rete: ritentabile, non è un fallimento definitivo.
                exit 75
            fi

            # Controlla l'esistenza del RCLONE_TEST sul remote e lo crea se non esiste.
            # Il listing viene catturato prima del grep: con pipefail un SIGPIPE
            # di "grep -q" farebbe sembrare fallita la pipeline.
            REMOTE_LISTING=$(/usr/bin/rclone lsf "${REMOTE_PATH}" 2>/dev/null || true)
            if ! printf '%s\n' "$REMOTE_LISTING" | grep -qx 'RCLONE_TEST'; then
                if ! /usr/bin/rclone touch "${REMOTE_PATH}/RCLONE_TEST"; then
                    ERR="Failed to create 'RCLONE_TEST' on remote '${REMOTE_PATH}'. Check remote permissions."
                    echo "[$(date)] CRITICAL: $ERR" >&2
                    send_notification "$ERR"
                    exit 1
                fi
            fi

            # Check Local Permissions / Existence
            if [ ! -d "$LOCAL_PATH" ]; then
                 ERR="Local directory '${LOCAL_PATH}' is missing!"
                 echo "[$(date)] CRITICAL: $ERR" >&2
                 send_notification "$ERR"
                 exit 1
            fi

            # Test Write (create lock/test file locally)
            if ! touch "${LOCAL_PATH}/RCLONE_TEST_WRITE" 2>/dev/null; then
                 ERR="Cannot write to local folder '${LOCAL_PATH}'. Permission denied."
                 echo "[$(date)] CRITICAL: $ERR" >&2
                 send_notification "$ERR"
                 exit 1
            else
                 rm "${LOCAL_PATH}/RCLONE_TEST_WRITE" || true
            fi

            # Check Local Disk Space (soglia: 1GB libero)
            # df -BM usa blocchi da 1 Megabyte. awk controlla se lo spazio disponibile ($4) è < 1024 MB.
            if ! df -BM "$LOCAL_PATH" | awk 'NR==2 {if ($4 < 1024) exit 1}'; then
                AVAILABLE_SPACE=$(df -h "$LOCAL_PATH" | awk 'NR==2 {print $4}' || echo "N/A")
                ERR="Low local disk space in '${LOCAL_PATH}' partition (Available: ${AVAILABLE_SPACE})."
                echo "[$(date)] CRITICAL: $ERR" >&2
                send_notification "$ERR"
                exit 1
            fi

            # --- RESYNC SOLO SU ERRORE CRITICO E A DIRECTORY QUIETA ---
            if [ "$RCLONE_RC" -ne 7 ]; then
                echo "[$(date)] Errore non critico (exit ${RCLONE_RC}): nessun --resync, rinvio." >&2
                exit 75
            fi

            if command -v lsof >/dev/null 2>&1; then
                if [ -n "$(lsof +D "$LOCAL_PATH" 2>/dev/null)" ]; then
                    echo "[$(date)] DEFER: file aperti, --resync rinviato." >&2
                    exit 75
                fi
            fi

            echo "[$(date)] Errore critico (exit 7). Tentativo di --resync..." >&2

            # --- TENTATIVO DI RESYNC ---
            RESYNC_RC=0
            RESYNC_OUT=$("${RCLONE_CMD[@]}" --resync 2>&1) || RESYNC_RC=$?
            if [ "$RESYNC_RC" -ne 0 ]; then
                # Catturiamo le ultime 3 righe dell'errore per mostrarle nella notifica
                LAST_ERR=$(echo "$RESYNC_OUT" | tail -n 3)
                
                FULL_ERR="Automatic Resync Failed!
Reason:
$LAST_ERR"
                 
                echo "[$(date)] CRITICAL: Resync failed." >&2
                echo "${RESYNC_OUT}" >&2
                send_notification "$FULL_ERR"
                : > "$BLOCKED_FILE"
                echo "[$(date)] CRITICAL: watcher sospeso fino a intervento manuale (${BLOCKED_FILE})." >&2
                exit 7
            else
                rm -f "$BLOCKED_FILE"
                echo "[$(date)] --resync was successful." >&2
                echo "${RESYNC_OUT}" >&2
                # Opzionale: Notifica di successo dopo un recupero difficile
                # notify-send -u normal "Rclone Fixed" "Sync recovered successfully via --resync"
            fi
        else
            # --- Success Logic ---
            echo "[$(date)] Rclone bisync finished." >&2
            echo "${RCLONE_OUTPUT}" >&2
        fi
    ) 200>"${LOCK_FILE_BISYNC}"

) 201>"${LOCK_FILE_REMOTE}"
