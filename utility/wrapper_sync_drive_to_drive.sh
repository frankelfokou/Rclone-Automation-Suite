#!/bin/bash

# POSIZIONE: /etc/cron.daily/
# TEST: sudo run-parts /etc/cron.daily

# --- CONFIGURAZIONE ---
TARGET_USER="frankel"
SCRIPT_PATH="/home/frankel/.personal/rclone_google_drive_sync/rclone_sync.sh"
SCRIPT_ARGS="GDrive-F4Frank: GDrive-Pro:"
# ----------------------

# Ottiene l'ID numerico dell'utente (es. 1000)
USER_ID=$(id -u "$TARGET_USER")

# Definisce le variabili necessarie per le notifiche
# XDG_RUNTIME_DIR è fondamentale su Fedora/Systemd per trovare il socket delle notifiche
EXPORT_XDG="export XDG_RUNTIME_DIR=/run/user/${USER_ID}"

# Definisce il Display (quasi sempre :0 su configurazioni a singolo utente)
EXPORT_DISPLAY="export DISPLAY=:0"

# Definisce il DBus Address (per sicurezza lo forziamo anche qui, oltre che nel tuo script)
EXPORT_DBUS="export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_ID}/bus"

# Controlla se lo script esiste
if [ -f "$SCRIPT_PATH" ]; then
    
    # ESEGUE IL COMANDO
    # runuser -l: simula un login pulito dell'utente
    # -c "...": esegue una stringa di comandi.
    # Prima di lanciare lo script, esportiamo le variabili grafiche.
    
    /sbin/runuser -l "$TARGET_USER" -c "$EXPORT_XDG; $EXPORT_DISPLAY; $EXPORT_DBUS; $SCRIPT_PATH $SCRIPT_ARGS"
    
fi