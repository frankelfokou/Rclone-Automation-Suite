#!/bin/bash

set -e
set -o pipefail

SOURCE_PATH="$1" 
DEST_PATH="$2"  

# Controllo del numero di argomenti
if [ "$#" -ne 2 ]; then
    ERR_MSG="Numero di argomenti non corretto.
Uso: $0 <sorgente_locale> <destinazione_remota>"
    log_message "Errore: $ERR_MSG"
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


/usr/bin/rclone sync "$SOURCE_PATH" "$DEST_PATH" \
--create-empty-src-dirs \
--fast-list \
--drive-stop-on-upload-limit \
--checkers=32 \
--transfers=16 \
--drive-chunk-size=128M \
--drive-pacer-min-sleep=10ms \
-v