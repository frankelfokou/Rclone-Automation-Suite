#!/bin/bash
#
# setup.sh — installazione del sistema di sincronizzazione rclone.
#
# Richiede root per: loginctl enable-linger, rimozione dei wrapper legacy in
# /etc/cron.daily e dei file logrotate di sistema, creazione dei file posseduti
# dall'utente. Tutto ciò che riguarda la rotazione dei log è a livello utente
# (rclone-logrotate.timer), perché logrotate di sistema non riesce ad accedere
# alla home (ACL other::--- e SELinux) e fallisce ogni notte.
#
# È idempotente: può essere rieseguito dopo ogni aggiornamento del repository.

set -u

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
SYSTEMD_SOURCE_FOLDER="systemd/user"
RCLONE_CONF_DIR="$HOME_DIR/.config/rclone"
LOGROTATE_CONF="${RCLONE_CONF_DIR}/logrotate.conf"
LOGROTATE_STATE_DIR="${HOME_DIR}/.local/state"

as_user() {
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$@"
}

# =============================================================================
# 1. Directory necessarie
# =============================================================================

echo "Verifica e crea le directory di installazione..."
for dir in "$BIN_FOLDER" "$AUTOSTART_FOLDER" "$SYSTEMD_USER_FOLDER" \
           "$RCLONE_CONF_DIR" "$LOGROTATE_STATE_DIR"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || { echo "Impossibile creare $dir"; exit 1; }
    fi
done

RCLONE_REMOTES=(GDrive-F4Frank GDrive-Pro)
for remote in "${RCLONE_REMOTES[@]}"; do
    mkdir -p "$RCLONE_CONF_DIR/conf_dir_${remote}/log_files" \
             "$RCLONE_CONF_DIR/conf_dir_${remote}/lock_files" \
             "$RCLONE_CONF_DIR/conf_dir_${remote}/state" || {
        echo "Impossibile creare $RCLONE_CONF_DIR/conf_dir_${remote}"
        exit 1
    }
    chown -R "$TARGET_USER:$TARGET_USER" "$RCLONE_CONF_DIR/conf_dir_${remote}"
done

# =============================================================================
# 2. File di esclusione
# =============================================================================

install_exclude_file() { # sorgente, destinazione
    local src="$1"
    local dst="$2"

    if [ ! -f "$src" ]; then
        echo "Errore: file di esclusione '$src' non trovato nel repository." >&2
        exit 1
    fi

    if [ ! -f "$dst" ]; then
        echo "Installazione del file di esclusione $dst..."
        cp "$src" "$dst" || { echo "Impossibile creare $dst" >&2; exit 1; }
    elif ! cmp -s "$src" "$dst"; then
        echo "Allineamento di $dst al template (copia precedente in ${dst}.bak)..."
        cp "$dst" "${dst}.bak"
        cp "$src" "$dst"
    else
        echo "File di esclusione $dst già aggiornato."
    fi

    chown "$TARGET_USER:$TARGET_USER" "$dst"
    chmod 644 "$dst"
}

install_exclude_file "config/exclude_patterns.txt" "$RCLONE_CONF_DIR/exclude_patterns.txt"
install_exclude_file "config/exclude_obsidian.txt" "$RCLONE_CONF_DIR/exclude_obsidian.txt"

command -v inotifywait >/dev/null 2>&1 || \
    echo "AVVISO: installare inotify-tools (sudo dnf install inotify-tools)."

# =============================================================================
# 3. Script in ~/.bin/ (con il modulo condiviso)
# =============================================================================

echo "Copia degli script rclone in $BIN_FOLDER..."
cp scripts/rclone_bisync.sh "$BIN_FOLDER/"
cp scripts/rclone_sync.sh "$BIN_FOLDER/"
cp scripts/rclone_watch_bisync.sh "$BIN_FOLDER/"
chmod +x "$BIN_FOLDER/rclone_bisync.sh" "$BIN_FOLDER/rclone_sync.sh" \
         "$BIN_FOLDER/rclone_watch_bisync.sh"

mkdir -p "$BIN_FOLDER/lib"
cp scripts/lib/common.sh "$BIN_FOLDER/lib/common.sh"
chmod 644 "$BIN_FOLDER/lib/common.sh"

chown -R "$TARGET_USER:$TARGET_USER" "$BIN_FOLDER/rclone_bisync.sh" \
    "$BIN_FOLDER/rclone_sync.sh" "$BIN_FOLDER/rclone_watch_bisync.sh" \
    "$BIN_FOLDER/lib"

# =============================================================================
# 4. Unità systemd user, .env e logrotate utente
# =============================================================================

echo "Copia delle unità systemd user in $SYSTEMD_USER_FOLDER..."
for unit in \
    rclone-bisync@.service \
    rclone-bisync@.timer \
    rclone-bisync-watcher@.service \
    rclone-sync@.service \
    rclone-sync@.timer \
    rclone-logrotate.service \
    rclone-logrotate.timer
do
    cp "$SYSTEMD_SOURCE_FOLDER/$unit" "$SYSTEMD_USER_FOLDER/" || exit 1
    chown "$TARGET_USER:$TARGET_USER" "$SYSTEMD_USER_FOLDER/$unit"
    chmod 644 "$SYSTEMD_USER_FOLDER/$unit"
done

echo "Copia dei file .env per le istanze..."
for env_file in "$SYSTEMD_SOURCE_FOLDER"/rclone-*.env; do
    cp "$env_file" "$SYSTEMD_USER_FOLDER/" || exit 1
    chown "$TARGET_USER:$TARGET_USER" "$SYSTEMD_USER_FOLDER/$(basename "$env_file")"
    chmod 644 "$SYSTEMD_USER_FOLDER/$(basename "$env_file")"
done

echo "Disattivazione delle istanze non più previste (F4Frank -> GDrive-Pro)..."
as_user systemctl --user disable --now \
    rclone-sync@drive-to-drive.timer rclone-sync@drive-to-mega.timer 2>/dev/null || true
rm -f "$SYSTEMD_USER_FOLDER/rclone-sync-drive-to-drive.env" \
      "$SYSTEMD_USER_FOLDER/rclone-sync-drive-to-mega.env"

# =============================================================================
# 5. Linger (avvio al boot senza login)
# =============================================================================

echo "Abilitazione linger per l'utente ${TARGET_USER}..."
loginctl enable-linger "$TARGET_USER" || {
    echo "AVVISO: impossibile abilitare linger per ${TARGET_USER}. I timer potrebbero non partire al boot senza login."
}

# =============================================================================
# 6. Pulizia dei residui che hanno causato la cancellazione del vault
# =============================================================================
# I wrapper in /etc/cron.daily lanciavano ogni notte
#   rclone sync GDrive-F4Frank: GDrive-Pro:   (cancellava il vault)
#   rclone sync GDrive-F4Frank: Mega:         (cancellava i backup)
# Sono sostituiti dai timer rclone-sync@*.timer: vanno rimossi.

echo "Rimozione dei wrapper legacy da /etc/cron.daily/..."
for wrapper in wrapper_sync_drive_to_drive.sh wrapper_sync_drive_to_mega.sh; do
    if [ -f "/etc/cron.daily/$wrapper" ]; then
        rm -f "/etc/cron.daily/$wrapper" && echo "  Rimosso: /etc/cron.daily/$wrapper"
    fi
done

# =============================================================================
# 7. Rotazione dei log a livello utente
# =============================================================================
# Le definizioni in /etc/logrotate.d non funzionano (ACL other::--- sulla home,
# SELinux) e alcune erano duplicate con naming diverso. Si rimuovono tutte e si
# usa un logrotate utente, eseguito da rclone-logrotate.timer.

echo "Rimozione delle definizioni logrotate di sistema per rclone..."
rm -f /etc/logrotate.d/rclone_* 2>/dev/null || true

# Istanze: TIPO NOME_INSTANCE PERCORSO_LOG
# I percorsi devono coincidere con quelli usati dagli script.
declare -a LOGROTATE_INSTANCES=(
    "bisync gdrive-f4frank $RCLONE_CONF_DIR/conf_dir_GDrive-F4Frank/log_files/bisync-GDrive-F4Frank.log"
    "bisync gdrive-pro $RCLONE_CONF_DIR/conf_dir_GDrive-Pro/log_files/bisync-GDrive-Pro.log"
    "watcher gdrive-f4frank $RCLONE_CONF_DIR/conf_dir_GDrive-F4Frank/log_files/watcher-GDrive-F4Frank.log"
    "watcher gdrive-pro $RCLONE_CONF_DIR/conf_dir_GDrive-Pro/log_files/watcher-GDrive-Pro.log"
    "sync f4frank-to-mega $RCLONE_CONF_DIR/conf_dir_GDrive-F4Frank/log_files/sync-GDrive-F4Frank_to_Mega.log"
    "sync pro-to-mega $RCLONE_CONF_DIR/conf_dir_GDrive-Pro/log_files/sync-GDrive-Pro_to_Mega.log"
)

echo "Generazione di $LOGROTATE_CONF..."
{
    echo "# Generato da setup.sh — non modificare a mano."
    echo "# Eseguito da rclone-logrotate.timer (logrotate a livello utente)."
    echo
    for entry in "${LOGROTATE_INSTANCES[@]}"; do
        read -r log_type instance_name log_path <<< "$entry"
        cat << EOF
"$log_path" {
    rotate 7
    daily
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
    done
} > "$LOGROTATE_CONF"

chown "$TARGET_USER:$TARGET_USER" "$LOGROTATE_CONF"
chmod 644 "$LOGROTATE_CONF"

# =============================================================================
# 8. Ricaricamento systemd e attivazione
# =============================================================================

echo "Ricaricamento systemd --user per ${TARGET_USER}..."
as_user systemctl --user daemon-reload || {
    echo "Errore: impossibile eseguire systemctl --user daemon-reload come ${TARGET_USER}."
    exit 1
}

echo "Abilitazione e avvio dei timer systemd user..."
TIMERS=(
    rclone-bisync@gdrive-f4frank.timer
    rclone-bisync@gdrive-pro.timer
    rclone-sync@f4frank-to-mega.timer
    rclone-sync@pro-to-mega.timer
    rclone-logrotate.timer
)
for timer in "${TIMERS[@]}"; do
    as_user systemctl --user enable --now "$timer" || {
        echo "Errore: impossibile abilitare ${timer}."
        exit 1
    }
done

# =============================================================================
# 9. Marker RCLONE_TEST per --check-access
# =============================================================================

BISYNC_PAIRS=(
    "$HOME_DIR/GDrive-F4Frank GDrive-F4Frank:"
    "$HOME_DIR/GDrive-Pro GDrive-Pro:"
)

for entry in "${BISYNC_PAIRS[@]}"; do
    read -r local_path remote_path <<< "$entry"

    if [ ! -d "$local_path" ]; then
        echo "AVVISO: $local_path non esiste, RCLONE_TEST locale saltato."
        continue
    fi

    if [ ! -f "$local_path/RCLONE_TEST" ]; then
        as_user touch "$local_path/RCLONE_TEST" || true
    fi

    if ! as_user /usr/bin/rclone lsf "$remote_path" 2>/dev/null | grep -qx 'RCLONE_TEST'; then
        as_user /usr/bin/rclone touch "${remote_path}RCLONE_TEST" || {
            echo "AVVISO: impossibile creare RCLONE_TEST su ${remote_path}"
        }
    fi
done

# =============================================================================
# 10. Watcher realtime
# =============================================================================

echo "Abilitazione e avvio del watcher realtime..."
WATCHERS=(gdrive-f4frank gdrive-pro)
for instance in "${WATCHERS[@]}"; do
    as_user systemctl --user enable --now "rclone-bisync-watcher@${instance}.service" || {
        echo "Errore: impossibile abilitare rclone-bisync-watcher@${instance}.service."
        exit 1
    }
done

# =============================================================================
# 11. Crontab utente: rimozione delle vecchie righe rclone
# =============================================================================

echo "Rimozione delle vecchie righe di crontab utente (sostituite dai timer systemd)..."
LEGACY_CRON_MARKERS=(".bin/rclone_bisync.sh" ".bin/rclone_sync.sh")
if crontab -u "$TARGET_USER" -l 2>/dev/null | grep -q .; then
    REMOVE_PATTERNS_FILE=$(mktemp)
    printf '%s\n' "${LEGACY_CRON_MARKERS[@]}" > "$REMOVE_PATTERNS_FILE"
    crontab -u "$TARGET_USER" -l 2>/dev/null | grep -v -F -f "$REMOVE_PATTERNS_FILE" | crontab -u "$TARGET_USER" -
    rm -f "$REMOVE_PATTERNS_FILE"
    echo "Crontab utente aggiornato (righe rclone rimosse)."
fi

echo -e "\n--- Installazione completata con successo! ---"
echo "Timer attivi:"
as_user systemctl --user list-timers --all --no-pager 2>/dev/null | grep rclone || true
echo
echo "Watcher:"
as_user systemctl --user status --no-pager --lines=0 \
    rclone-bisync-watcher@gdrive-f4frank.service \
    rclone-bisync-watcher@gdrive-pro.service 2>/dev/null | grep -E '^\s*(●|Active)' || true
