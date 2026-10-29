#! /bin/bash

# Questo script richiede i permessi di root per copiare i file in /etc/cron.daily
if [ "$EUID" -ne 0 ]; then
  echo "Errore: Eseguire questo script con sudo." >&2
  exit 1
fi

TARGET_USER="frankel"
HOME_DIR="/home/$TARGET_USER"

BIN_FOLDER="$HOME_DIR/.bin"
AUTOSTART_FOLDER="${HOME_DIR}/.config/autostart"

# Controlla e crea la directory di configurazione se non esiste.
echo "Verifica e crea la directory $BIN_FOLDER..."
if [ ! -d "$BIN_FOLDER" ]; then
    echo "La directory di configurazione '$BIN_FOLDER' non esiste. Tentativo di creazione..."
    if ! mkdir -p "$BIN_FOLDER"; then
        echo "Impossibile creare la directory di configurazione: '$BIN_FOLDER'. Controllare i permessi."
        exit 1
    fi
fi

echo "Verifica e crea la directory $AUTOSTART_FOLDER..."
if [ ! -d "$AUTOSTART_FOLDER" ]; then
    echo "La directory di configurazione '$AUTOSTART_FOLDER' non esiste. Tentativo di creazione..."
    if ! mkdir -p "$AUTOSTART_FOLDER"; then
        echo "Impossibile creare la directory di configurazione: '$AUTOSTART_FOLDER'. Controllare i permessi."
        exit 1
    fi
fi

echo "Copia degli script rclone in $BIN_FOLDER..."
cp rclone_bisync.sh "$BIN_FOLDER/"
cp rclone_sync.sh "$BIN_FOLDER/"

echo "Copia degli script wrapper in /etc/cron.daily/..."
cp utility/wrapper_sync_drive_to_mega.sh utility/wrapper_sync_drive_to_drive.sh /etc/cron.daily/


echo "Copia del file di avvio automatico in $AUTOSTART_FOLDER..."
cp utility/login_rclone_bisync.desktop "$AUTOSTART_FOLDER/"

# --- Gestione Crontab utente ---
CRONTAB_FILE="utility/crontab.txt"
if [ ! -f "$CRONTAB_FILE" ]; then
    echo "Errore: file crontab '$CRONTAB_FILE' non trovato." >&2
    exit 1
fi

CRONTAB_BLOCK=$(cat "$CRONTAB_FILE")

# Marcatore per idempotenza: riga attiva con il comando rclone_bisync
CRONTAB_MARKER="/home/frankel/.bin/rclone_bisync.sh /home/frankel/GDrive-F4Frank GDrive-F4Frank:"

echo "Verifica crontab utente ${TARGET_USER}..."
CURRENT_CRONTAB=$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)

if echo "$CURRENT_CRONTAB" | grep -qF "$CRONTAB_MARKER"; then
    echo "Crontab già configurato per ${TARGET_USER}, nessuna modifica."
else
    {
        echo "$CURRENT_CRONTAB"
        printf '%s' "$CRONTAB_BLOCK"
    } | crontab -u "$TARGET_USER" -
    echo "Crontab aggiornato per ${TARGET_USER}."
fi

echo -e "\n--- Installazione completata con successo! ---"

