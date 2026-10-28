# `rclone` Synchronization Scripts Guide

This guide illustrates the functionality of a suite of shell scripts designed to automate, manage, and robustly handle file synchronization with `rclone`.

---

### General Overview

The suite provides solutions for different synchronization scenarios:

1.  **Bidirectional Synchronization (`bisync`)**: Keeps a local and a remote directory perfectly aligned. Ideal for daily work on files that need to be available both locally and in the cloud.
2.  **Unidirectional Synchronization (`sync`)**: Primarily used for backups from one cloud to another (remote -> remote).
3.  **Utility Scripts**: Includes wrappers for system-wide cron jobs and manual copy operations that respect the global locking system.

### Funzionalità Principali

Tutti gli script principali condividono funzionalità avanzate:

*   **Gestione dei Lock**: Per prevenire esecuzioni multiple e conflitti, utilizzando un sistema a doppio `flock`.
*   **Notifiche Desktop**: Per segnalare errori critici direttamente nell'ambiente grafico dell'utente.
*   **Logging e Rotazione dei Log**: To track operations and manage disk space via `logrotate`.
*   **Recupero Automatico**: In caso di errori, vengono eseguiti tentativi di diagnostica e recupero (es. `--resync` per `bisync`).
*   **Safety Checks**: The `bisync` script checks for open or recently modified files to prevent conflicts.
*   **Esclusione di Cartelle Remote**: Tutti gli script supportano l'esclusione di cartelle remote tramite un file di pattern centralizzato, evitando di sincronizzare directory non desiderate (es. cache, backup, cartelle generate automaticamente).

### Prerequisiti

Assicurati che i seguenti pacchetti siano installati sul tuo sistema:
*   `rclone`: L'utility principale per la sincronizzazione.
*   `util-linux`: Fornisce il comando `flock` per la gestione dei lock.
*   `lsof`: (Consigliato) Usato da `bisync` per verificare se ci sono file aperti prima di una sincronizzazione.
*   `logrotate`: Per la gestione e rotazione automatica dei file di log.
*   `libnotify`: Fornisce `notify-send` per le notifiche desktop.

### Installazione e Configurazione

1.  **Eseguire lo script di setup**: Lo script `setup.sh` copia i file eseguibili nelle directory di sistema. Deve essere eseguito con `sudo`.
    **Nota**: The script is configured by default for the user `frankel`. Modify the `TARGET_USER` variable in `setup.sh` if your username is different.
    ```bash
    sudo ./setup.sh
    ```

2.  **Configurazione Iniziale per ogni Task**: Per ogni **nuova** operazione di sincronizzazione che vuoi creare (es. un nuovo `bisync` per una nuova cartella), esegui **una volta** lo script di `test_setup_*` corrispondente. Questo crea la struttura di directory (`~/.config/rclone/conf_dir_*`), i file di log e imposta `logrotate`.
    ```bash
    # Esempio per un nuovo task di bisync
    ./rclone_bisync.sh /home/utente/Documenti MyRemote:Documenti
    ```

---

### Project Structure

The scripts are organized into directories based on their function:

*   **`/` (root)**: Contiene gli script principali pronti per l'uso in produzione (`rclone_bisync.sh`, `rclone_sync.sh`).
*   **`/utility`**: Contains wrapper scripts for system cron execution (`wrapper_*`) and an example `.desktop` file for autostart.
*   **`/test`**: Contains test scripts for dry-run simulations of `bisync` and `sync` operations.
*   **`~/.config/rclone/`** (utente): Contiene il file `exclude_patterns.txt` per le esclusioni centralizzate.

---

### Script in Dettaglio

#### `rclone_bisync.sh`

**Role**: Main script for bidirectional synchronization (`local <-> remote`). It is designed to be run at regular intervals via the user's `cron`.

**Funzionalità chiave**:
*   **Sincronizzazione Bidirezionale**: Usa `rclone bisync`.
*   **Recupero Automatico**: In caso di fallimento, esegue controlli di connettività, permessi e spazio, quindi tenta un `--resync`.
*   **Safety Check**: Prima di agire, controlla i file aperti (`lsof`) o modificati di recente (`find`) nella directory locale, attendendo o saltando il ciclo per evitare conflitti.
*   **Locking**: Utilizza il sistema di lock a due livelli per garantire l'integrità delle operazioni.
*   **Esclusioni Centralizzate**: Supporta il file `~/.config/rclone/exclude_patterns.txt` per ignorare cartelle remote specifiche.

#### `rclone_sync.sh`

**Role**: Performs a **unidirectional** synchronization from one remote path to another (`remote -> remote`). Ideal for backups between cloud services.

**Funzionalità chiave**:
*   **Sincronizzazione Unidirezionale**: Usa `rclone sync`.
*   **Gestione Errori**: Controlla la connettività e invia notifiche in caso di fallimento.
*   **Locking**: Condivide lo stesso sistema di lock del `bisync.sh` per evitare conflitti sullo stesso remote.
*   **Esclusioni Centralizzate**: Supporta il file `~/.config/rclone/exclude_patterns.txt` per ignorare cartelle remote specifiche.

#### Script di Utility (`rclone_copy_*`)
*(Note: These scripts are described for context but are not included in the base project files).*
Simple scripts for one-time `rclone copy` operations. Unlike a manual `rclone copy`, these scripts **respect the locking system**, waiting if another operation (like `bisync`) is in progress on the same remote.

#### `wrapper_sync_drive_to_drive.sh` e `wrapper_sync_drive_to_mega.sh`

**Role**: These are "wrapper" scripts designed to be executed by a system `cron` (e.g., in `/etc/cron.daily`), which normally runs as the `root` user.

**Purpose**: They execute the `rclone_sync.sh` script as a specific user (`frankel` in the example), setting the necessary environment variables (`DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`) to allow the script to send **desktop notifications** to the correct user's graphical session.

**Usage**: The `setup.sh` script places them in `/etc/cron.daily/` for daily execution.

#### `login_rclone_bisync.desktop`
**Role**: An autostart file that runs a specific `rclone_bisync.sh` command upon user login.
**Purpose**: Ensures that synchronization for a critical directory (e.g., Documents) is attempted as soon as the user logs into their graphical session.
**Usage**: The `setup.sh` script copies this file to `~/.config/autostart/`. You should edit the `Exec` line within this file to match the path and remote you wish to sync on login.

---

### Sistema di Esclusione Cartelle Remote

Tutti gli script della suite supportano l'esclusione di cartelle remote tramite un file di pattern centralizzato.

#### Come funziona

Il file `~/.config/rclone/exclude_patterns.txt` contiene un pattern per riga. Ogni script include automaticamente l'opzione `--exclude-from` che punta a questo file.

#### Formato dei pattern

```
# Escludere una cartella nella root del remote (usa / finale)
Google AI Studio/
Gemini Voyager Data/
Gemini Gems/

# Escludere per percorso specifico
Documenti/Old/
Download/Temp/

# Escludere per estensione
*.tmp
*.cache
```

#### Aggiungere o rimuovere esclusioni

Basta modificare il file `~/.config/rclone/exclude_patterns.txt` con un editor di testo. Le modifiche sono **immediate** e valgono per **tutti gli script** — non serve toccare i singoli script.

#### Verificare le esclusioni

Puoi simulare una sincronizzazione con `--dry-run` per vedere cosa verrebbe saltato:

```bash
# Per bisync
/usr/bin/rclone bisync /home/utente/Locale Remote: --dry-run --exclude-from ~/.config/rclone/exclude_patterns.txt -v

# Per sync
/usr/bin/rclone sync Remote1: Remote2: --dry-run --exclude-from ~/.config/rclone/exclude_patterns.txt -v
```

#### Script coinvolti

| Script | Comando rclone |
|--------|---------------|
| `rclone_bisync.sh` | `rclone bisync` |
| `rclone_sync.sh` | `rclone sync` |
| `utility/rclone_copy_remote_to_local.sh` | `rclone copy` |
| `utility/rclone_copy_remote_to_remote.sh` | `rclone copy` |
| `test/test_command_rclone_bisynch.sh` | `rclone bisync` (test) |
| `test/test_command_rclone_sync.sh` | `rclone sync` (test) |