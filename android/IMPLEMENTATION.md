# Adattamento Script Rclone per Termux (Android)

## Panoramica

Questo documento descrive i prerequisiti e le modifiche necessarie per rendere gli script `rclone_bisync.sh` e `rclone_sync.sh` compatibili con **Termux** (ambiente terminale per Android).

---

## 1. Prerequisiti — Installazione su Termux

### 1.1 Pacchetti essenziali

```bash
pkg update && pkg upgrade -y
pkg install rclone bash util-linux findutils termux-api
```

| Pacchetto      | Ruolo                                                          |
| -------------- | -------------------------------------------------------------- |
| `rclone`     | Tool di sincronizzazione                                       |
| `bash`       | Interprete degli script                                        |
| `util-linux` | Fornisce`flock` (necessario per i lock filesystem)           |
| `findutils`  | Fornisce`find` (usato nel safety check)                      |
| `termux-api` | Fornisce`termux-notification` (sostituto di `notify-send`) |

### 1.2 Pacchetti opzionali

```bash
pkg install lsof cronie termux-services
```

| Pacchetto           | Ruolo                                                                               |
| ------------------- | ----------------------------------------------------------------------------------- |
| `lsof`            | Safety check file aperti (se non installato, va gestito con fallback)               |
| `cronie`          | Demone cron (`crond`) per esecuzione periodica dei job                            |
| `termux-services` | Service manager (runit) necessario per mantenere`crond` persistente in background |

### 1.3 Storage condiviso (opzionale)

Se vuoi sincronizzare cartelle nello storage condiviso del telefono (es. `DCIM`, `Download`):

```bash
termux-setup-storage
```

I percorsi saranno accessibili sotto `~/storage/`.

---

## 2. Modifiche comuni a entrambi gli script

### 2.1 Percorsi dei binari

Su Linux si usa il path assoluto `/usr/bin/rclone`. In Termux i binari sono in `$PREFIX/bin/`, già nel `PATH`.

| Prima (Linux)       | Dopo (Termux) |
| ------------------- | ------------- |
| `/usr/bin/rclone` | `rclone`    |

**Esempio di modifica** — tutte le occorrenze di:

```bash
/usr/bin/rclone
```

vanno sostituite con:

```bash
rclone
```

### 2.2 Notifiche — `notify-send` → `termux-notification`

Su Linux le notifiche desktop usano `notify-send` via D-Bus. In Termux si usa `termux-notification` fornito da `termux-api`.

#### Blocco da rimuovere (presente in entrambi gli script)

```bash
# TRUCCO PER CRON / SYSTEMD:
# Se lo script è lanciato in background, potrebbe non sapere dove mandare la notifica.
# Su Fedora (systemd), il bus dell'utente si trova sempre qui:
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi
```

#### Funzione `send_notification()` da sostituire

**Prima (Linux):**

```bash
send_notification() {
    local error_msg="$1"
    notify-send -u normal \
                -i dialog-error \
                -a "Rclone Script" \
                "Rclone bisync Error: ${REMOTE_NAME:-Setup}" \
                "$error_msg" || true
}
```

**Dopo (Termux):**

```bash
send_notification() {
    local error_msg="$1"
    local title="${2:-Rclone Error: ${REMOTE_NAME:-Setup}}"
    termux-notification \
        --title "$title" \
        --content "$error_msg" \
        --priority high \
        --alert-once \
        --action "android.intent.action.VIEW" || true
}
```

### 2.3 Logrotate — non disponibile in Termux

Su Linux si usa `logrotate` con configurazione in `/etc/logrotate.d/` (richiede `sudo`). In Termux:

- **Non esiste** `/etc/logrotate.d/`
- **Non esiste** `sudo`
- **Non esiste** `logrotate` di default

#### Cosa fare

**Rimuovere l'intera sezione logrotate** (dalla riga `LOG_ROTATE_FILE=...` fino alla fine del blocco `if ... else ... fi`).

In alternativa, aggiungere una **rotazione manuale** alla fine dello script:

```bash
# --- Rotazione manuale del log (sostituto di logrotate per Termux) ---
MAX_LOG_SIZE_MB=10

rotate_log_if_needed() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        local size
        size=$(du -m "$log_file" 2>/dev/null | cut -f1)
        if [ "$size" -gt "$MAX_LOG_SIZE_MB" ]; then
            mv "$log_file" "${log_file}.old"
            touch "$log_file"
            echo "[$(date)] Log ruotato: superati ${MAX_LOG_SIZE_MB}MB" >> "$log_file"
        fi
    fi
}

# Chiamata alla fine dello script, prima dell'uscita
rotate_log_if_needed "$LOG_FILE"
```

### 2.4 Percorsi assoluti → relativi con `$HOME`

Tutti i percorsi fissi `/home/frankel/...` vanno sostituiti con `$HOME/...`.

| Prima                                                                                                       | Dopo                                          |
| ----------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `/home/frankel/.config/rclone/conf_dir_${REMOTE_NAME}` | `$HOME/.config/rclone/conf_dir_${REMOTE_NAME}` |                                               |
| `/home/frankel/.config/rclone/exclude_patterns.txt`                                                       | `$HOME/.config/rclone/exclude_patterns.txt` |

---

## 3. Modifiche specifiche per `rclone_bisync.sh`

### 3.1 Safety check LSOF — comando `lsof +D`

La sintassi `lsof +D` potrebbe non essere supportata su tutti i sistemi. Inoltre `lsof` potrebbe non essere installato in Termux.

**Modifica**: avvolgere il controllo in un `if command -v lsof` già presente, ma aggiungere un fallback esplicito:

```bash
if command -v lsof >/dev/null 2>&1; then
    # ... logica esistente con lsof ...
else
    echo "[$(date)] WARNING: lsof non disponibile. Salto il controllo file aperti." >&2
fi
```

### 3.2 Safety check FIND — opzione `-mmin`

Il comando `find ... -mmin -1` è POSIX e funziona in Termux. **Nessuna modifica necessaria.**

---

## 4. Modifiche specifiche per `rclone_sync.sh`

### 4.1 Nomi dei lock file

Lo script `rclone_sync.sh` usa `sync-${REMOTE_NAME}.lock` come lock file specifico. Questo nome è già distinto da `bisync-${REMOTE_NAME}.lock` usato dall'altro script. **Nessuna modifica necessaria.**

### 4.2 Safety check LSOF/FIND (aggiunto)

Il safety check LSOF/FIND è stato **aggiunto** da `rclone_bisync.sh` a `rclone_sync.sh`, con un adattamento importante: poiché `rclone_sync.sh` accetta due path remoti (entrambi con `:`), il controllo `lsof +D` viene eseguito **solo se SOURCE_PATH è una directory locale** (nessun `:` nel path). Se SOURCE è un remote, il safety check viene saltato con un messaggio informativo.

---

## 5. Lock files — compatibilità

I lock file usano `flock` (da `util-linux`) che funziona perfettamente in Termux dopo l'installazione del pacchetto.

**Nessuna modifica necessaria** alla logica di locking.

---

## 6. Cron / esecuzione periodica

Su Linux si usa `crontab` con lo scheduler di sistema. In Termux ci sono due opzioni:

### Opzione A: `cronie` + `termux-services`

```bash
pkg install cronie termux-services
sv-enable crond
crontab -e
```

Esempio di crontab:

```
*/15 * * * * $HOME/.personal/rclone-automation-suite/rclone_bisync.sh $HOME/GDrive-F4Frank GDrive-F4Frank:
```

### Opzione B: Termux:Boot (senza cron)

1. Installa l'app **Termux:Boot** da F-Droid
2. Crea `~/.termux/boot/start-sync.sh`:

```bash
#!/data/data/com.termux/files/usr/bin/bash
while true; do
    $HOME/.personal/rclone-automation-suite/rclone_bisync.sh $HOME/GDrive-F4Frank GDrive-F4Frank:
    sleep 900  # 15 minuti
done
```

---

### 6.1 Mantenere Termux attivo con `termux-wake-lock`

Su Android, anche con `crond` attivo, il sistema può sospendere Termux quando lo schermo è spento. Per evitarlo:

```bash
# Acquisisce il wake lock all'avvio di Termux
termux-wake-lock rclone-cron

# Per rilasciarlo (quando vuoi fermare tutto):
# termux-wake-unlock rclone-cron
```

#### Dove metterlo

**Opzione 1 — In uno script Termux:Boot** (se usi anche Termux:Boot):

Crea `~/.termux/boot/start-cron.sh`:

```bash
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock rclone-cron
# Avvia crond se usi termux-services
# (sv-enable crond lo fa già automaticamente all'avvio)
```

**Opzione 2 — In un file `.bashrc`** (si attiva quando apri Termux):

Aggiungi in `~/.bashrc`:

```bash
# Acquisisce wake lock all'apertura di Termux (se non già attivo)
if ! termux-wake-lock rclone-cron 2>/dev/null; then
    termux-wake-lock rclone-cron
fi
```

**Opzione 3 — Direttamente nello script rclone** (si attiva a ogni esecuzione):

Aggiungi in cima a `rclone_bisync.sh` e `rclone_sync.sh`, dopo `unset LD_LIBRARY_PATH`:

```bash
# Acquisisce wake lock per evitare sospensione durante la sync
if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock rclone-sync 2>/dev/null || true
fi
```

> **Nota**: `termux-wake-lock` richiede il pacchetto `termux-api` (già nei prerequisiti essenziali).

#### Limitazioni

- Se **swipi via Termux** dalle app recenti, il wake lock viene perso
- Su alcuni OEM (Xiaomi, Huawei, OnePlus) le ottimizzazioni batteria aggressive possono ignorare il wake lock
- **Soluzione complementare**: vai in *Impostazioni → App → Termux → Batteria → Non ottimizzare*

| Modifica                                   | `rclone_bisync.sh` | `rclone_sync.sh` |
| ------------------------------------------ | -------------------- | ------------------ |
| `/usr/bin/rclone` → `rclone`          | ✅                   | ✅                 |
| `notify-send` → `termux-notification` | ✅                   | ✅                 |
| Rimuovere blocco DBUS                      | ✅                   | ✅                 |
| Rimuovere sezione logrotate                | ✅                   | ✅                 |
| `/home/frankel/...` → `$HOME/...`     | ✅                   | ✅                 |
| Fallback `lsof` se non installato | ✅ | ✅ (aggiunto) |
| Safety check LSOF/FIND             | ✅ | ✅ (aggiunto) |
| Rotazione manuale log (opzionale)          | ✅                   | ✅                 |

---

## 8. Verifica finale

Dopo aver applicato le modifiche, esegui uno script in modalità debug per verificare:

```bash
cd $HOME/.personal/rclone-automation-suite/android
chmod +x rclone_bisync_termux.sh
DEBUG_MODE=1 ./rclone_bisync_termux.sh $HOME/test-local GDrive-Test:test-remote
```

Controlla che:

- Le notifiche arrivino correttamente
- I lock file vengano creati in `$HOME/.config/rclone/conf_dir_*/lock_files/`
- I log vengano scritti in `$HOME/.config/rclone/conf_dir_*/log_files/`
- Il safety check con `lsof` (se installato) funzioni
- La rotazione manuale dei log (se implementata) funzioni
