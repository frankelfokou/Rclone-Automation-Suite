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

# Controlla e crea la directory di configurazione se non esiste.
if [ ! -d "$CONF_DIR" ]; then
    log_message "La directory di configurazione '$CONF_DIR' non esiste. Tentativo di creazione..."
    if ! mkdir -p "$CONF_DIR"; then
        # Se la creazione fallisce, invia una notifica ed esce.
        ERR_MSG="Impossibile creare la directory di configurazione: '$CONF_DIR'. Controllare i permessi."
        log_message "ERRORE CRITICO: $ERR_MSG"
        send_notification "$ERR_MSG"
        exit 1
    fi
fi

# Controlla che il file di log esista
if [ ! -f "$LOG_FILE" ]; then
    log_message "Il file di log '$LOG_FILE' non esiste. tentativo di creazione..."
    if ! touch "$LOG_FILE"; then
        # Se la creazione fallisce, invia una notifica ed esce.
        ERR_MSG="Impossibile creare il file di log: '$LOG_FILE'. Controllare i permessi."
        log_message "ERRORE CRITICO: $ERR_MSG"
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

LOG_ROTATE_FILE="/etc/logrotate.d/rclone_bisync_${REMOTE_NAME}"

# --- Gestione Configurazione Logrotate ---
# Definisce il contenuto atteso per il file di configurazione di logrotate.
read -r -d '' LOGROTATE_CONTENT << EOF || true
"$LOG_FILE" {
    rotate 7
    daily
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

# Controlla se il file di configurazione di logrotate esiste.
if [ ! -f "$LOG_ROTATE_FILE" ]; then
    # Tenta di creare il file. Fallirà se non si hanno i permessi (richiede sudo).
    if ! echo "$LOGROTATE_CONTENT" | sudo tee "$LOG_ROTATE_FILE" > /dev/null 2>&1; then
        ERR_MSG="Impossibile creare '$LOG_ROTATE_FILE'. Sono necessari i permessi di root."
        echo "ATTENZIONE: $ERR_MSG"
        echo "Per abilitare la rotazione dei log, eseguire manualmente il seguente comando:"
        echo "echo \"${LOGROTATE_CONTENT}\" | sudo tee \"${LOG_ROTATE_FILE}\" > /dev/null"
        send_notification "$ERR_MSG"
    fi
else
    # Il file esiste, controlla il contenuto.
    CURRENT_CONTENT=$(cat "$LOG_ROTATE_FILE")
    if [ "$CURRENT_CONTENT" != "$LOGROTATE_CONTENT" ]; then
        # Tenta di sovrascrivere il file. Fallirà se non si hanno i permessi (richiede sudo).
        if ! echo "$LOGROTATE_CONTENT" | sudo tee "$LOG_ROTATE_FILE" > /dev/null 2>&1; then
            ERR_MSG="Impossibile aggiornare '$LOG_ROTATE_FILE'. Sono necessari i permessi di root."
            echo "ATTENZIONE: $ERR_MSG"
            echo "Per correggere la configurazione, eseguire manualmente il seguente comando:"
            echo "echo \"${LOGROTATE_CONTENT}\" | sudo tee \"${LOG_ROTATE_FILE}\" > /dev/null"
            send_notification "$ERR_MSG"
        fi
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

WAIT_SECONDS=10
MAX_RETRIES=18 # 18 * 10s = 3 minuti di attesa massima

echo "[$(date)] Inizio safety check LSOF per file aperti" >&2
if command -v lsof >/dev/null 2>&1; then
    retry_count=0
    
    # Ciclo finché lsof trova file aperti (exit code 0 = trovati)
    while lsof +D "$LOCAL_PATH" >/dev/null 2>&1; do
        if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
            echo "[$(date)] SKIP: File aperti rilevati dopo $((MAX_RETRIES * WAIT_SECONDS))s. Rinuncio per questo giro."
            # Usciamo con 0 per non allarmare cron, riproveremo tra 15 min
            exit 0
        fi
        
        log_message "File in uso rilevati. Attesa ${WAIT_SECONDS}s... ($((retry_count+1))/$MAX_RETRIES)"
        sleep "$WAIT_SECONDS"
        ((retry_count++))
    done
fi
echo "[$(date)] Safety check LSOF avvenuto con successo" >&2

# Controllo aggiuntivo per modifiche recenti (se lsof non vede tutto o se lsof non c'è)
# Aspetta se un file è stato toccato negli ultimi 60 secondi
echo "[$(date)] Inizio safety check FIND per modifiche nell'ultimo minuto" >&2
if find "$LOCAL_PATH" -type f -mmin -1 -print -quit 2>/dev/null | grep -q .; then
     echo "[$(date)] SKIP: Modifiche file rilevate nell'ultimo minuto. Lascio stabilizzare."
     exit 0
fi
echo "[$(date)] Safety check FIND avvenuto con successo" >&2

# ------------------------------------------------------------------------------
# FINE SAFETY CHECK
# ------------------------------------------------------------------------------


# --- Main Logic with Locking ---
( # Nuovo lock BLOKKANTE per il remote (FD 201)
    # Attende se un altro script sta usando lo stesso remote.

    echo "[$(date)] Tentativo di aquisizione lock generale per ${REMOTE_NAME}" >&2
    flock 201
    echo "[$(date)] Lock generale per ${REMOTE_NAME} acquisito." >&2

    ( # Lock NON-BLOKKANTE esistente per bisync (FD 200)
        # Acquire an exclusive lock on file descriptor 200.

        echo "[$(date)] Tentativo di aquisizione lock specifico per bisync per ${REMOTE_NAME}" >&2
        flock -n 200 || {
            echo "[$(date)] Script bisync già in esecuzione per ${REMOTE_NAME}. Uscita." >&2
            exit 1
        }

        echo "[$(date)] Lock bisync acquisito. Avvio rclone bisync per ${REMOTE_NAME}." >&2
        
        RCLONE_CMD=(
            /usr/bin/rclone bisync "$LOCAL_PATH" "$REMOTE_PATH"
            --check-access
            --resilient
            --recover
            --max-lock 2m
            --max-delete 20
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
        if ! RCLONE_OUTPUT=$("${RCLONE_CMD[@]}" 2>&1); then
            # --- GESTIONE PRIMO ERRORE ---
            echo "[$(date)] Rclone bisync failed" >&2
            echo "${RCLONE_OUTPUT}" >&2

            echo "[$(date)] Attempting recovery..." >&2

            # Check Remote Connectivity
            if ! /usr/bin/rclone about "${REMOTE_NAME}:" &>/dev/null; then
                ERR="Remote '${REMOTE_NAME}' is unreachable. Check internet or token."
                echo "[$(date)] CRITICAL: $ERR" >&2
                send_notification "$ERR"
                exit 1
            fi

            # Controlla l'esistenza del RCLONE_TEST sul remote e lo crea se non esiste.
            if ! /usr/bin/rclone lsf "${REMOTE_PATH}" | grep -q "^RCLONE_TEST$"; then
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

            echo "[$(date)] Connectivity OK. Attempting --resync..." >&2

            # --- TENTATIVO DI RESYNC ---
            if ! RESYNC_OUT=$("${RCLONE_CMD[@]}" --resync 2>&1); then
                # Catturiamo le ultime 3 righe dell'errore per mostrarle nella notifica
                LAST_ERR=$(echo "$RESYNC_OUT" | tail -n 3)
                
                FULL_ERR="Automatic Resync Failed!
Reason:
$LAST_ERR"
                 
                echo "[$(date)] CRITICAL: Resync failed." >&2
                echo "${RESYNC_OUT}" >&2
                send_notification "$FULL_ERR"
                exit 1
            else
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