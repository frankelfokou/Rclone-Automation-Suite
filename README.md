# `rclone` Synchronization Scripts Guide

This guide explains how a suite of shell scripts designed to automate, manage, and robustly handle file synchronization with `rclone` works.

---

### General Overview

The suite provides solutions for various synchronization scenarios:

1.  **Bidirectional Synchronization (`bisync`)**: Keeps a local and a remote directory perfectly aligned. Ideal for daily work on files that need to be available both locally and in the cloud.
2.  **Unidirectional Synchronization (`sync`)**: Primarily used for backups from one cloud to another (remote -> remote).
3.  **Unidirectional Copy (`copy`)**: Utility scripts for manual copy operations (remote -> local or remote -> remote) that respect the global locking system.

All main scripts share advanced features such as:
*   **Lock Management**: To prevent multiple executions and conflicts.
*   **Desktop Notifications**: To report critical errors.
*   **Logging and Log Rotation**: To track operations and manage disk space.
*   **Automatic Recovery**: In case of errors, diagnostic and recovery attempts are performed.

---

### Project Structure

The scripts are organized into directories based on their function:

*   **`/` (root)**: Contains the main scripts ready for production use (`rclone_bisync.sh`, `rclone_sync.sh`).
*   **`/test`**: Contains variants of the main scripts with debug mode enabled (`test_setup_*`) and simplified scripts for testing basic commands (`test_command_*`).
*   **`/utility`**: Contains scripts for manual operations (`rclone_copy_*`) and wrappers for execution via system cron (`wrapper_*`).

---

### 1. `rclone_bisync.sh`

**Role**: Main script for bidirectional synchronization (`local <-> remote`). It is designed to be run at regular intervals via `cron`.

**Key Features**:
*   **Bidirectional Synchronization**: Uses `rclone bisync`.
*   **Automatic Recovery**: On failure, it performs connectivity, permissions, and space checks, then attempts a `--resync`.
*   **Safety Check**: Before acting, it checks for open (`lsof`) or recently modified (`find`) files in the local directory, waiting or skipping the cycle to avoid conflicts.
*   **Locking**: Uses `flock` to create two lock levels: one specific for `bisync` (non-blocking) and a general one for the remote (blocking), ensuring that different operations on the same remote do not overlap.
*   **Logging and Notifications**: Logs every operation and sends desktop notifications in case of errors.
*   **Automatic Setup**: Creates configuration directories, log files, and the configuration for `logrotate`.

**Usage (Crontab)**:
Run `crontab -e` and add:
```bash
# Runs synchronization every 15 minutes
*/15 * * * * /full/path/to/rclone_bisync.sh /home/user/GDrive MyRemote:

# Runs synchronization at system startup
@reboot sleep 60 && /full/path/to/rclone_bisync.sh /home/user/GDrive MyRemote:
```

---

### 2. `rclone_sync.sh`

**Ruolo**: Esegue una sincronizzazione **unidirezionale** da un percorso remoto a un altro (`remoto -> remoto`). Ideale per backup tra servizi cloud.

**Funzionalità chiave**:
*   **Sincronizzazione Unidirezionale**: Usa `rclone sync`.
*   **Gestione Errori**: Controlla la connettività e invia notifiche in caso di fallimento.
*   **Locking**: Condivide lo stesso sistema di lock del `bisync.sh` per evitare conflitti sullo stesso remote di origine.
*   **Logging e Setup**: Simile a `bisync.sh`, gestisce log, rotazione e configurazioni iniziali.

**Utilizzo**:
Può essere eseguito manualmente o tramite cron.
```bash
/percorso/completo/rclone_sync.sh SourceRemote:backup DestRemote:backup
```

---

### 3. Script di Setup e Debug (`/test`)

Questi script sono pensati per la configurazione iniziale e la risoluzione dei problemi.

*   `test_setup_rclone_bisync.sh`
*   `test_setup_rclone_sync.sh`

**Ruolo**: Sono varianti degli script principali con la modalità `DEBUG_MODE=1` attivata di default. Vanno eseguiti **manualmente una volta** per ogni nuovo task di sincronizzazione.

**Scopo**:
1.  **Verificare la configurazione**: Mostrano tutto l'output a terminale.
2.  **Creare le strutture necessarie**: Creano le directory in `~/.config/rclone/`, i file di lock e di log.
3.  **Impostare `logrotate`**: Tentano di scrivere il file di configurazione per la rotazione dei log, avvisando se sono necessari permessi di root.

**Utilizzo**:
```bash
# Per un nuovo task di bisync
./test/test_setup_rclone_bisync.sh /home/utente/Documenti MyRemote:Documenti

# Per un nuovo task di sync
./test/test_setup_rclone_sync.sh SourceRemote:cartella DestRemote:cartella
```

---

### 4. Script di Utility e Wrapper (`/utility`)

#### `rclone_copy_remote_to_local.sh` e `rclone_copy_remote_to_remote.sh`

**Ruolo**: Script semplici per eseguire operazioni di copia (`rclone copy`) una tantum. A differenza di un `rclone copy` manuale, questi script **rispettano il sistema di lock**, attendendo se un'altra operazione (come `bisync`) è in corso sullo stesso remote.

**Utilizzo**:
```bash
# Copia dal cloud a una cartella locale
./utility/rclone_copy_remote_to_local.sh MyRemote:file.zip /home/utente/download/

# Copia tra due cloud
./utility/rclone_copy_remote_to_remote.sh MyRemote:file.zip OtherRemote:backup/
```

#### `wrapper_sync_drive_to_drive.sh` e `wrapper_sync_drive_to_mega.sh`

**Ruolo**: Sono script "wrapper" progettati per essere eseguiti da un `cron` di sistema (es. in `/etc/cron.daily`), che normalmente gira come utente `root`.

**Scopo**: Eseguono lo script `rclone_sync.sh` come utente specifico (`frankel` nell'esempio), impostando le variabili d'ambiente (`DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`) necessarie per permettere allo script di inviare **notifiche desktop** alla sessione grafica dell'utente corretto.

**Utilizzo**:
Posizionare lo script in una directory come `/etc/cron.daily/` per l'esecuzione giornaliera.

---

### 5. Script di Test Semplici (`/test`)

*   `test_command_rclone_bisync.sh`
*   `test_command_rclone_sync.sh`

**Ruolo**: Contengono esclusivamente il comando `rclone` con i flag preconfigurati, senza alcuna logica di lock, logging o gestione degli errori.

**Scopo**: Utili per testare rapidamente il comportamento del solo comando `rclone` in isolamento.

**Utilizzo**:
```bash
./test/test_command_rclone_bisync.sh /home/utente/Documenti MyRemote:Documenti
```