#!/bin/bash

# CRONTAB EXAMPLE:
# */15 * * * * /path/to/script.sh GDrive-F4Frank RemoteName:CartellaRemota

set -e
set -o pipefail

# Pulisce l'ambiente da librerie potenzialmente "inquinanti"
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
                "Rclone Sync Error: ${SOURCE_PATH} -> ${DEST_PATH}" \
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
SOURCE_PATH="$1"
DEST_PATH="$2"

# Controllo del numero di argomenti
if [ "$#" -ne 2 ]; then
    ERR_MSG="Numero di argomenti non corretto.
Uso: $0 <sorgente_locale> <destinazione_remota>"
    log_message "Errore: $ERR_MSG"
    # Chiamata dopo aver definito SOURCE_PATH e DEST_PATH
    send_notification "$ERR_MSG"
    exit 1
fi

################## SOURCE ##################

# Controllo formato del remote
if [[ ! "$SOURCE_PATH" == *":"* ]]; then
    ERR_MSG="Il percorso remoto '$SOURCE_PATH' non sembra valido (manca ':')."
    log_message "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

# Controlla l'esistenza del remote
REMOTE_NAME=$(echo "$SOURCE_PATH" | cut -d':' -f1)
if ! /usr/bin/rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    ERR_MSG="Il remote '$REMOTE_NAME' non è configurato in rclone."
    log_message "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

############################################

################## DEST ####################

# Controllo formato del remote
if [[ ! "$DEST_PATH" == *":"* ]]; then
    ERR_MSG="Il percorso remoto '$DEST_PATH' non sembra valido (manca ':')."
    log_message "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

# Controlla l'esistenza del remote
DEST_REMOTE_NAME=$(echo "$DEST_PATH" | cut -d':' -f1)
if ! /usr/bin/rclone listremotes | grep -q "^${DEST_REMOTE_NAME}:"; then
    ERR_MSG="Il remote '$DEST_REMOTE_NAME' non è configurato in rclone."
    log_message "Errore: $ERR_MSG"
    send_notification "$ERR_MSG"
    exit 1
fi

#############################################

CONF_DIR="/home/frankel/.config/rclone/conf_dir_${REMOTE_NAME}"
LOCK_FILE_SYNC="${CONF_DIR}/lock_files/sync-${REMOTE_NAME}.lock" 
LOCK_FILE_REMOTE="${CONF_DIR}/lock_files/remote-${REMOTE_NAME}.lock"
LOG_FILE="${CONF_DIR}/log_files/sync-${REMOTE_NAME}_to_${DEST_REMOTE_NAME}.log"

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

# --- LOG REDIRECTION ---
if [ "$DEBUG_MODE" -eq 0 ]; then
    # In modalità normale (cron), reindirizza tutto l'output al file di log.
    exec >> "$LOG_FILE" 2>&1
fi


LOG_ROTATE_FILE="/etc/logrotate.d/rclone_sync_${REMOTE_NAME}"

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

# --- Main Logic with Locking ---
( # Nuovo lock BLOKKANTE per il remote (FD 201)
    # Attende se un altro script sta usando lo stesso remote.

    echo "[$(date)] Tentativo di aquisizione lock generale per ${REMOTE_NAME}" >&2
    flock 201
    echo "[$(date)] Lock generale per ${REMOTE_NAME} acquisito." >&2

    ( # Lock NON-BLOKKANTE esistente per bisync (FD 200)
        # Acquire an exclusive lock on file descriptor 200.

        echo "[$(date)] Tentativo di aquisizione lock specifico per sync per ${REMOTE_NAME}" >&2
        flock -n 200 || {
            echo "[$(date)] Script sync già in esecuzione per ${REMOTE_NAME}. Uscita." >&2
            exit 1
        }

        echo "[$(date)] Lock sync acquisito. Avvio rclone sync per ${REMOTE_NAME}." >&2
        
        RCLONE_CMD=(
            /usr/bin/rclone sync "$SOURCE_PATH" "$DEST_PATH"
            --create-empty-src-dirs     
            --fast-list
            --drive-stop-on-upload-limit
            --checkers=32
            --transfers=16
            --drive-chunk-size=128M
            --drive-pacer-min-sleep=10ms
            -v
        )

        # --- Esecuzione ---
        if ! RCLONE_OUTPUT=$("${RCLONE_CMD[@]}" 2>&1); then
            # --- GESTIONE ERRORE ---
            echo "[$(date)] Rclone sync fallito." >&2
            echo "${RCLONE_OUTPUT}" >&2

            echo "[$(date)] Analisi cause..." >&2

            # 1. Check Connettività
            if ! /usr/bin/rclone about "${REMOTE_NAME}:" &>/dev/null; then
                ERR="Remote '${REMOTE_NAME}' non raggiungibile. Controllare internet/token."
                echo "[$(date)] CRITICAL: $ERR" >&2
                send_notification "$ERR"
                exit 1
            fi

            # Se siamo qui, è un errore generico non risolto
            LAST_ERR=$(echo "$RCLONE_OUTPUT" | tail -n 3)
            FULL_ERR="Rclone Sync Failed!
Dettagli:
$LAST_ERR"
            send_notification "$FULL_ERR"
            exit 1

        else
            # --- Successo ---
            echo "[$(date)] Rclone sync completato con successo." >&2
            echo "${RCLONE_OUTPUT}" >&2
        fi
    ) 200>"${LOCK_FILE_SYNC}"

) 201>"${LOCK_FILE_REMOTE}"