#!/bin/bash

set -e
set -o pipefail

REMOTE_PATH="$2"
LOCAL_PATH="$1"

# 1. Controllo del numero di argomenti
if [ "$#" -ne 2 ]; then
    echo "Errore: Numero di argomenti non corretto."
    echo "Uso: $0  <directory_locale> <remote:percorso>" 
    echo "Esempio: $0 /home/frankel/GDrive-F4Frank GDrive-F4Frank:"
    exit 1
fi

# 2. Controllo dell'esistenza della directory locale
if [ ! -d "$LOCAL_PATH" ]; then
    echo "Errore: La directory locale '$LOCAL_PATH' non esiste."
    exit 1
fi

# 3. Controllo dell'esistenza del remote in rclone
REMOTE_NAME=$(echo "$REMOTE_PATH" | cut -d':' -f1)
if ! /usr/bin/rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    echo "Errore: Il remote '$REMOTE_NAME' non è configurato in rclone."
    exit 1
fi

/usr/bin/rclone bisync "${LOCAL_PATH}" "${REMOTE_PATH}" --resync \
--check-access \
--remove-empty-dirs \
--resilient \
--recover \
--max-lock 2m \
--max-delete 20 \
--fast-list \
--fix-case \
--compare modtime \
--drive-stop-on-upload-limit  \
--checkers=32 \
--transfers=16 \
--drive-chunk-size=128M \
--drive-pacer-min-sleep=10ms \
--drive-export-formats docx,xlsx,pptx \
--drive-import-formats docx,xlsx,pptx \
-v