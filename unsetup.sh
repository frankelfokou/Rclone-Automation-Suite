#!/bin/bash

# Questo script richiede i permessi di root per rimuovere i file da /etc/cron.daily
if [ "$EUID" -ne 0 ]; then
  echo "Errore: Eseguire questo script con sudo." >&2
  exit 1
fi

TARGET_USER="frankel"
HOME_DIR="/home/$TARGET_USER"

BIN_FOLDER="$HOME_DIR/.bin"
AUTOSTART_FOLDER="${HOME_DIR}/.config/autostart"

echo "Rimozione degli script rclone da $BIN_FOLDER..."
rm -f "$BIN_FOLDER/rclone_bisync.sh"
rm -f "$BIN_FOLDER/rclone_sync.sh"

echo "Rimozione degli wrapper da /etc/cron.daily/..."
rm -f /etc/cron.daily/wrapper_sync_drive_to_mega.sh
rm -f /etc/cron.daily/wrapper_sync_drive_to_drive.sh

echo "Rimozione del file di avvio automatico da $AUTOSTART_FOLDER..."
rm -f "$AUTOSTART_FOLDER/login_rclone_bisync.desktop"

# --- Rimozione Crontab utente ---
CRONTAB_FILE="utility/crontab.txt"

echo "Rimozione crontab utente ${TARGET_USER}..."
if crontab -u "$TARGET_USER" -l 2>/dev/null | grep -q .; then
    REMOVE_PATTERNS_FILE=$(mktemp)
    # Estrai solo le righe attive (non vuote, non commenti) da crontab.txt
    grep -v '^[[:space:]]*#' "$CRONTAB_FILE" | grep -v '^[[:space:]]*$' > "$REMOVE_PATTERNS_FILE"
    crontab -u "$TARGET_USER" -l 2>/dev/null | grep -v -F -f "$REMOVE_PATTERNS_FILE" | crontab -u "$TARGET_USER" -
    rm -f "$REMOVE_PATTERNS_FILE"
    echo "Crontab aggiornato per ${TARGET_USER} (righe rclone rimosse)."
else
    echo "Nessun crontab presente per ${TARGET_USER}."
fi

echo -e "\n--- Disinstallazione completata con successo! ---"
