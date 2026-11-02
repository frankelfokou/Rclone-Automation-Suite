#!/bin/bash

# Questo script richiede i permessi di root per:
# - copiare i wrapper in /etc/cron.daily (se ancora presenti)
# - eseguire loginctl enable-linger
# - scrivere i file di logrotate in /etc/logrotate.d/
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

# =============================================================================
# 1. Creazione directory necessarie
# =============================================================================

echo "Verifica e crea la directory $BIN_FOLDER..."
if [ ! -d "$BIN_FOLDER" ]; then
    mkdir -p "$BIN_FOLDER" || { echo "Impossibile creare $BIN_FOLDER"; exit 1; }
fi

echo "Verifica e crea la directory $AUTOSTART_FOLDER..."
if [ ! -d "$AUTOSTART_FOLDER" ]; then
    mkdir -p "$AUTOSTART_FOLDER" || { echo "Impossibile creare $AUTOSTART_FOLDER"; exit 1; }
fi

echo "Verifica e crea la directory $SYSTEMD_USER_FOLDER..."
if [ ! -d "$SYSTEMD_USER_FOLDER" ]; then
    mkdir -p "$SYSTEMD_USER_FOLDER" || { echo "Impossibile creare $SYSTEMD_USER_FOLDER"; exit 1; }
fi

# =============================================================================
# 1b. Directory dati rclone, file di esclusione e prerequisiti
# =============================================================================

RCLONE_CONF_DIR="$HOME_DIR/.config/rclone"

echo "Creazione directory log/lock per i remote..."
RCLONE_REMOTES=(GDrive-F4Frank)
for remote in "${RCLONE_REMOTES[@]}"; do
    mkdir -p "$RCLONE_CONF_DIR/conf_dir_${remote}/log_files" \
             "$RCLONE_CONF_DIR/conf_dir_${remote}/lock_files" || {
        echo "Impossibile creare $RCLONE_CONF_DIR/conf_dir_${remote}"
        exit 1
    }
    chown -R "$TARGET_USER:$TARGET_USER" "$RCLONE_CONF_DIR/conf_dir_${remote}"
done

EXCLUDE_FILE="$RCLONE_CONF_DIR/exclude_patterns.txt"
if [ ! -f "$EXCLUDE_FILE" ]; then
    echo "Creazione del file di esclusione $EXCLUDE_FILE..."
    cat > "$EXCLUDE_FILE" <<'EOF'
# Un pattern per riga. Le modifiche sono immediate e valgono per tutti gli script.
# Esempi:
# Google AI Studio/
# Gemini Voyager Data/
# *.tmp
# *.cache
EOF
    chown "$TARGET_USER:$TARGET_USER" "$EXCLUDE_FILE"
    chmod 644 "$EXCLUDE_FILE"
fi

command -v inotifywait >/dev/null 2>&1 || \
    echo "AVVISO: installare inotify-tools (sudo dnf install inotify-tools)."

# =============================================================================
# 2. Copia degli script rclone in ~/.bin/
# =============================================================================

echo "Copia degli script rclone in $BIN_FOLDER..."
cp scripts/rclone_bisync.sh "$BIN_FOLDER/"
cp scripts/rclone_sync.sh "$BIN_FOLDER/"
chmod +x "$BIN_FOLDER/rclone_bisync.sh" "$BIN_FOLDER/rclone_sync.sh"

# =============================================================================
# 3. Copia delle unità systemd user e dei file .env
# =============================================================================

echo "Copia delle unità systemd user in $SYSTEMD_USER_FOLDER..."
cp "$SYSTEMD_SOURCE_FOLDER/rclone-bisync@.service" "$SYSTEMD_USER_FOLDER/"
cp "$SYSTEMD_SOURCE_FOLDER/rclone-sync@.service" "$SYSTEMD_USER_FOLDER/"
cp "$SYSTEMD_SOURCE_FOLDER/rclone-bisync@.timer" "$SYSTEMD_USER_FOLDER/"
cp "$SYSTEMD_SOURCE_FOLDER/rclone-sync@.timer" "$SYSTEMD_USER_FOLDER/"

echo "Copia dei file .env per le istanze in $SYSTEMD_USER_FOLDER..."
cp "$SYSTEMD_SOURCE_FOLDER/rclone-bisync-gdrive-f4frank.env" "$SYSTEMD_USER_FOLDER/"
cp "$SYSTEMD_SOURCE_FOLDER/rclone-sync-drive-to-drive.env" "$SYSTEMD_USER_FOLDER/"
cp "$SYSTEMD_SOURCE_FOLDER/rclone-sync-drive-to-mega.env" "$SYSTEMD_USER_FOLDER/"

# =============================================================================
# 4. Abilitazione linger per l'utente (avvio al boot senza login)
# =============================================================================

echo "Abilitazione linger per l'utente ${TARGET_USER}..."
loginctl enable-linger "$TARGET_USER" || {
    echo "AVVISO: impossibile abilitare linger per ${TARGET_USER}. I timer potrebbero non partire al boot senza login."
}

# =============================================================================
# 5. Gestione logrotate (con sudo, richiesta da root)
# =============================================================================
# I file in /etc/logrotate.d/ dicono a logrotate di sistema come ruotare i log
# prodotti dagli script. Gestiti centralmente qui perché richiedono root.

LOGROTATE_DIR="/etc/logrotate.d"

# Definizione delle instanze: TIPO NOME_INSTANCE LOG_FILE
# TIPO: bisync | sync
# Il percorso del log deve coincidere con quello usato negli script bash.
declare -a LOGROTATE_INSTANCES=(
    "bisync gdrive-f4frank /home/frankel/.config/rclone/conf_dir_GDrive-F4Frank/log_files/bisync-GDrive-F4Frank.log"
    "sync drive-to-drive /home/frankel/.config/rclone/conf_dir_GDrive-F4Frank/log_files/sync-GDrive-F4Frank_to_GDrive-Pro.log"
    "sync drive-to-mega /home/frankel/.config/rclone/conf_dir_GDrive-F4Frank/log_files/sync-GDrive-F4Frank_to_Mega.log"
    "watcher gdrive-f4frank /home/frankel/.config/rclone/conf_dir_GDrive-F4Frank/log_files/watcher-GDrive-F4Frank.log"
)

for entry in "${LOGROTATE_INSTANCES[@]}"; do
    read -r log_type instance_name log_path <<< "$entry"

    logrotate_file="${LOGROTATE_DIR}/rclone_${log_type}_${instance_name}"

    read -r -d '' logrotate_content << EOF || true
"${log_path}" {
    rotate 7
    daily
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

    echo "Verifica logrotate per ${log_type}/${instance_name} -> ${logrotate_file}..."

    if [ ! -f "$logrotate_file" ]; then
        echo "$logrotate_content" | sudo tee "$logrotate_file" > /dev/null 2>&1 || {
            echo "AVVISO: impossibile creare ${logrotate_file}. Servono i permessi di root."
        }
    else
        current_content=$(cat "$logrotate_file" 2>/dev/null || true)
        if [ "$current_content" != "$logrotate_content" ]; then
            echo "$logrotate_content" | sudo tee "$logrotate_file" > /dev/null 2>&1 || {
                echo "AVVISO: impossibile aggiornare ${logrotate_file}. Servono i permessi di root."
            }
        else
            echo "  File già aggiornato, nessuna modifica necessaria."
        fi
    fi
done

# =============================================================================
# 6. Ricaricamento systemd --user e abilitazione timer
# =============================================================================

echo "Ricaricamento systemd --user per ${TARGET_USER}..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user daemon-reload || {
    echo "Errore: impossibile eseguire systemctl --user daemon-reload come ${TARGET_USER}."
    exit 1
}

# Abilita e avvia i timer. L'idempotenza è gestita da systemd stesso:
# enable --now su un timer già abilitato non produce errori.
echo "Abilitazione e avvio dei timer systemd user per ${TARGET_USER}..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable --now rclone-bisync@gdrive-f4frank.timer || {
    echo "Errore: impossibile abilitare rclone-bisync@gdrive-f4frank.timer."
    exit 1
}
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable --now rclone-sync@drive-to-drive.timer || {
    echo "Errore: impossibile abilitare rclone-sync@drive-to-drive.timer."
    exit 1
}
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable --now rclone-sync@drive-to-mega.timer || {
    echo "Errore: impossibile abilitare rclone-sync@drive-to-mega.timer."
    exit 1
}

# =============================================================================
# 6b. Marker RCLONE_TEST per --check-access
# =============================================================================
# bisync --check-access richiede il file su entrambi i lati. Se manca sul
# remote il primo run fallisce: lo creiamo qui una volta sola.

BISYNC_LOCAL="$HOME_DIR/GDrive-F4Frank"
BISYNC_REMOTE="GDrive-F4Frank:"

if [ -d "$BISYNC_LOCAL" ] && [ ! -f "$BISYNC_LOCAL/RCLONE_TEST" ]; then
    sudo -u "$TARGET_USER" touch "$BISYNC_LOCAL/RCLONE_TEST" || true
fi

if ! sudo -u "$TARGET_USER" /usr/bin/rclone lsf "$BISYNC_REMOTE" 2>/dev/null | grep -qx 'RCLONE_TEST'; then
    sudo -u "$TARGET_USER" /usr/bin/rclone touch "${BISYNC_REMOTE}RCLONE_TEST" || {
        echo "AVVISO: impossibile creare RCLONE_TEST sul remote."
    }
fi

# =============================================================================
# 7. Copia watcher realtime e servizio systemd
# =============================================================================

echo "Copia dello script watcher realtime in $BIN_FOLDER..."
cp scripts/rclone_watch_bisync.sh "$BIN_FOLDER/"
chmod +x "$BIN_FOLDER/rclone_watch_bisync.sh"

echo "Copia del servizio watcher systemd user in $SYSTEMD_USER_FOLDER..."
cp "$SYSTEMD_SOURCE_FOLDER/rclone-bisync-watcher@.service" "$SYSTEMD_USER_FOLDER/"

echo "Abilitazione e avvio del watcher realtime per ${TARGET_USER}..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user daemon-reload || {
    echo "Errore: impossibile eseguire daemon-reload come ${TARGET_USER}."
    exit 1
}
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable --now rclone-bisync-watcher@gdrive-f4frank.service || {
    echo "Errore: impossibile abilitare rclone-bisync-watcher@gdrive-f4frank.service."
    exit 1
}

# =============================================================================
# 8. Rimozione del crontab utente gestito in precedenza (sostituito da systemd)
# =============================================================================

echo "Rimozione delle vecchie righe di crontab utente (sostituite dai timer systemd)..."
CRONTAB_FILE="legacy/crontab.txt"
if [ -f "$CRONTAB_FILE" ] && crontab -u "$TARGET_USER" -l 2>/dev/null | grep -q .; then
    REMOVE_PATTERNS_FILE=$(mktemp)
    grep -v '^[[:space:]]*#' "$CRONTAB_FILE" | grep -v '^[[:space:]]*$' > "$REMOVE_PATTERNS_FILE"
    crontab -u "$TARGET_USER" -l 2>/dev/null | grep -v -F -f "$REMOVE_PATTERNS_FILE" | crontab -u "$TARGET_USER" -
    rm -f "$REMOVE_PATTERNS_FILE"
    echo "Crontab utente aggiornato (righe rclone rimosse)."
fi

echo -e "\n--- Installazione completata con successo! ---"
echo "Timer attivi:"
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user list-timers --all --no-pager 2>/dev/null | grep rclone || true
