#!/bin/bash

set -e
set -o pipefail


SRC_REMOTE_PATH=$1
DEST_REMOTE_PATH=$2

# Controllo del numero di argomenti
if [ "$#" -ne 2 ]; then
    echo "Errore: Numero di argomenti non corretto."
    echo "Uso: $0 <remote:percorso> <directory_locale>"
    echo "Esempio: $0 GDrive-F4Frank: GDrive-Pro:"
    exit 1
fi

# Controllo dell'esistenza del remote in rclone
DEST_REMOTE_NAME=$(echo "$DEST_REMOTE_PATH" | cut -d':' -f1)
if ! /usr/bin/rclone listremotes | grep -q "^${DEST_REMOTE_NAME}:"; then
    echo "Errore: Il remote '$DEST_REMOTE_NAME' non è configurato in rclone."
    exit 1
fi

# Controllo dell'esistenza del remote in rclone
REMOTE_NAME=$(echo "$SRC_REMOTE_PATH" | cut -d':' -f1)
if ! /usr/bin/rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    echo "Errore: Il remote '$REMOTE_NAME' non è configurato in rclone."
    exit 1
fi

CONF_DIR="/home/frankel/.config/rclone/conf_dir_${REMOTE_NAME}"
LOCK_FILE_COPY="${CONF_DIR}/lock_files/copy-${REMOTE_NAME}.lock"
LOCK_FILE_REMOTE="${CONF_DIR}/lock_files/remote-${REMOTE_NAME}.lock"

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


( # Lock BLOKKANTE generale per il remote (FD 201)
    # Attende se un altro script (es. bisync) sta usando lo stesso remote.
    echo "[$(date)] Tentativo di aquisizione lock generale per ${REMOTE_NAME}" >&2
    flock 201
    echo "[$(date)] Lock generale per ${REMOTE_NAME} acquisito da copy_locale." >&2

    ( # Lock NON-BLOKKANTE specifico per questo script (FD 200)
        echo "[$(date)] Tentativo di aquisizione lock specifico per copy per ${REMOTE_NAME}" >&2
        flock -n 200 || {
            echo "[$(date)] Script copy già in esecuzione per ${REMOTE_NAME}. Uscita." >&2
            exit 1
        }
        echo "[$(date)] Lock specifico per copy acquisito. Avvio rclone sync." >&2
        
        /usr/bin/rclone copy "$SRC_REMOTE_PATH" "$DEST_REMOTE_PATH" \
        --max-delete 20 \
        --fast-list \
        --drive-stop-on-upload-limit  \
        --checkers=32 \
        --transfers=16 \
        --drive-chunk-size=128M \
        --drive-pacer-min-sleep=10ms \
        -v

        echo "Sincronizzazione completata."

    ) 200>"${LOCK_FILE_COPY}"

) 201>"${LOCK_FILE_REMOTE}"

echo "[$(date)] Operazione copy_locale terminata e lock rilasciati." >&2
