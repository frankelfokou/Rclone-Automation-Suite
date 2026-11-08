#!/bin/bash

# Questo script richiede i permessi di root per:
# - rimuovere i wrapper da /etc/cron.daily
# - rimuovere i file di logrotate da /etc/logrotate.d/
# - eseguire loginctl disable-linger
if [ "$EUID" -ne 0 ]; then
  echo "Errore: Eseguire questo script con sudo." >&2
  exit 1
fi

TARGET_USER="frankel"
HOME_DIR="/home/$TARGET_USER"
USER_ID=$(id -u "$TARGET_USER")
XDG_RUNTIME_DIR="/run/user/$USER_ID"

BIN_FOLDER="$HOME_DIR/.bin"
AUTOSTART_FOLDER="${HOME_DIR}/.config/autostart"
SYSTEMD_USER_FOLDER="${HOME_DIR}/.config/systemd/user"

# =============================================================================
# 1. Stop e disable dei timer systemd user
# =============================================================================

echo "Stop dei timer systemd user per ${TARGET_USER}..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user stop \
    rclone-bisync@gdrive-f4frank.timer \
    rclone-bisync@gdrive-pro.timer \
    rclone-sync@f4frank-to-mega.timer \
    rclone-sync@pro-to-mega.timer \
    rclone-sync@drive-to-drive.timer \
    rclone-sync@drive-to-mega.timer 2>/dev/null || true

echo "Disable dei timer systemd user per ${TARGET_USER}..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user disable \
    rclone-bisync@gdrive-f4frank.timer \
    rclone-bisync@gdrive-pro.timer \
    rclone-sync@f4frank-to-mega.timer \
    rclone-sync@pro-to-mega.timer \
    rclone-sync@drive-to-drive.timer \
    rclone-sync@drive-to-mega.timer 2>/dev/null || true

# =============================================================================
# 2. Stop e disable watcher realtime
# =============================================================================

echo "Stop dei watcher realtime per ${TARGET_USER}..."
for instance in gdrive-f4frank gdrive-pro; do
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user stop "rclone-bisync-watcher@${instance}.service" 2>/dev/null || true
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user disable "rclone-bisync-watcher@${instance}.service" 2>/dev/null || true
done

# =============================================================================
# 3. Rimozione file di logrotate (con sudo)
# =============================================================================

LOGROTATE_DIR="/etc/logrotate.d"

echo "Rimozione file di logrotate da ${LOGROTATE_DIR}..."
for instance in bisync_gdrive-f4frank bisync_gdrive-pro watcher_gdrive-f4frank watcher_gdrive-pro \
                sync_f4frank-to-mega sync_pro-to-mega \
                sync_drive-to-drive sync_drive-to-mega; do
    logrotate_file="${LOGROTATE_DIR}/rclone_${instance}"
    if [ -f "$logrotate_file" ]; then
        rm -f "$logrotate_file" && echo "  Rimosso: $logrotate_file"
    fi
done

# Pulizia anche dei vecchi file logrotate con il naming convention precedente
# (prima che la gestione logrotate fosse spostata da setup/unsetup)
for old_file in rclone_bisync_GDrive-F4Frank rclone_sync_GDrive-F4Frank; do
    old_logrotate_file="${LOGROTATE_DIR}/${old_file}"
    if [ -f "$old_logrotate_file" ]; then
        rm -f "$old_logrotate_file" && echo "  Rimosso (vecchio naming): $old_logrotate_file"
    fi
done

# Rimuove eventuali marker di blocco lasciati dai watcher
rm -f "$HOME_DIR/.config/rclone/conf_dir_GDrive-F4Frank/lock_files/"*.blocked 2>/dev/null || true
rm -f "$HOME_DIR/.config/rclone/conf_dir_GDrive-Pro/lock_files/"*.blocked 2>/dev/null || true

# =============================================================================
# 3. Ricaricamento systemd --user dopo rimozione unità
# =============================================================================

echo "Ricaricamento systemd --user per ${TARGET_USER}..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user daemon-reload 2>/dev/null || true

# =============================================================================
# 4. Rimozione unità systemd e file .env
# =============================================================================

echo "Rimozione delle unità systemd user da ${SYSTEMD_USER_FOLDER}..."
rm -f "${SYSTEMD_USER_FOLDER}/rclone-bisync@.service"
rm -f "${SYSTEMD_USER_FOLDER}/rclone-sync@.service"
rm -f "${SYSTEMD_USER_FOLDER}/rclone-bisync@.timer"
rm -f "${SYSTEMD_USER_FOLDER}/rclone-sync@.timer"
rm -f "${SYSTEMD_USER_FOLDER}/rclone-bisync-watcher@.service"
rm -f "${SYSTEMD_USER_FOLDER}/rclone-bisync-*.env"
rm -f "${SYSTEMD_USER_FOLDER}/rclone-sync-*.env"

# =============================================================================
# 5. Disabilitazione linger (opzionale)
# =============================================================================

echo "Disabilitazione linger per ${TARGET_USER} (opzionale)..."
loginctl disable-linger "$TARGET_USER" 2>/dev/null || true

# =============================================================================
# 6. Rimozione script rclone da ~/.bin/
# =============================================================================

echo "Rimozione degli script rclone e watcher da $BIN_FOLDER..."
rm -f "$BIN_FOLDER/rclone_bisync.sh"
rm -f "$BIN_FOLDER/rclone_sync.sh"
rm -f "$BIN_FOLDER/rclone_watch_bisync.sh"
rm -f "$BIN_FOLDER/lib/common.sh"
rmdir "$BIN_FOLDER/lib" 2>/dev/null || true

# =============================================================================
# 6b. Rimozione del file di esclusione installato da setup.sh
# =============================================================================

echo "Rimozione del file di esclusione da $HOME_DIR/.config/rclone..."
EXCLUDE_FILE="$HOME_DIR/.config/rclone/exclude_patterns.txt"
if [ -f "${EXCLUDE_FILE}.bak" ]; then
    mv -f "${EXCLUDE_FILE}.bak" "$EXCLUDE_FILE"
    echo "  Ripristinata la versione precedente da ${EXCLUDE_FILE}.bak"
elif [ -f "$EXCLUDE_FILE" ]; then
    rm -f "$EXCLUDE_FILE"
    echo "  Rimosso: $EXCLUDE_FILE"
fi

# =============================================================================
# 7. Rimozione wrapper da /etc/cron.daily/
# =============================================================================

echo "Rimozione degli wrapper da /etc/cron.daily/..."
rm -f /etc/cron.daily/wrapper_sync_drive_to_mega.sh
rm -f /etc/cron.daily/wrapper_sync_drive_to_drive.sh

# =============================================================================
# 8. Rimozione file di avvio automatico
# =============================================================================

echo "Rimozione del file di avvio automatico da $AUTOSTART_FOLDER..."
rm -f "$AUTOSTART_FOLDER/login_rclone_bisync.desktop"

# =============================================================================
# 9. Rimozione crontab utente (se presenti righe rclone)
# =============================================================================

echo "Verifica crontab utente ${TARGET_USER}..."
LEGACY_CRON_MARKERS=(".bin/rclone_bisync.sh" ".bin/rclone_sync.sh")
if crontab -u "$TARGET_USER" -l 2>/dev/null | grep -q .; then
    REMOVE_PATTERNS_FILE=$(mktemp)
    printf '%s\n' "${LEGACY_CRON_MARKERS[@]}" > "$REMOVE_PATTERNS_FILE"
    crontab -u "$TARGET_USER" -l 2>/dev/null | grep -v -F -f "$REMOVE_PATTERNS_FILE" | crontab -u "$TARGET_USER" -
    rm -f "$REMOVE_PATTERNS_FILE"
    echo "Crontab aggiornato per ${TARGET_USER} (righe rclone rimosse)."
else
    echo "Nessun crontab presente per ${TARGET_USER}."
fi

echo -e "\n--- Disinstallazione completata con successo! ---"
