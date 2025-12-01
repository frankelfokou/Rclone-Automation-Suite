# `rclone` Synchronization Scripts Guide

Questa guida illustra il funzionamento di una suite di script shell progettata per automatizzare, gestire e rendere robusta la sincronizzazione di file con `rclone`.

---

### General Overview

La suite fornisce soluzioni per diversi scenari di sincronizzazione:

1.  **Bidirectional Synchronization (`bisync`)**: Keeps a local and a remote directory perfectly aligned. Ideal for daily work on files that need to be available both locally and in the cloud.
2.  **Unidirectional Synchronization (`sync`)**: Utilizzata principalmente per backup da un cloud a un altro (remoto -> remoto).
3.  **Unidirectional Copy (`copy`)**: Script di utilità per operazioni di copia manuale (remoto -> locale o remoto -> remoto) che rispettano il sistema di lock globale.

### Funzionalità Principali

Tutti gli script principali condividono funzionalità avanzate:

*   **Gestione dei Lock**: Per prevenire esecuzioni multiple e conflitti, utilizzando un sistema a doppio `flock`.
*   **Notifiche Desktop**: Per segnalare errori critici direttamente nell'ambiente grafico dell'utente.
*   **Logging e Rotazione dei Log**: Per tracciare le operazioni e gestire lo spazio su disco tramite `logrotate`.
*   **Recupero Automatico**: In caso di errori, vengono eseguiti tentativi di diagnostica e recupero (es. `--resync` per `bisync`).
*   **Safety Checks**: Il `bisync` controlla la presenza di file aperti o modificati di recente per evitare conflitti.

### Prerequisiti

Assicurati che i seguenti pacchetti siano installati sul tuo sistema:
*   `rclone`: L'utility principale per la sincronizzazione.
*   `util-linux`: Fornisce il comando `flock` per la gestione dei lock.
*   `lsof`: (Consigliato) Usato da `bisync` per verificare se ci sono file aperti prima di una sincronizzazione.
*   `logrotate`: Per la gestione e rotazione automatica dei file di log.
*   `libnotify`: Fornisce `notify-send` per le notifiche desktop.

### Installazione e Configurazione

1.  **Eseguire lo script di setup**: Lo script `setup.sh` copia i file eseguibili nelle directory di sistema. Deve essere eseguito con `sudo`.
    ```bash
    sudo ./setup.sh
    ```
    **Nota**: Lo script per default è configurato per l'utente `frankel`. Modifica la variabile `TARGET_USER` in `setup.sh` e negli script `utility/wrapper_*` se il tuo nome utente è diverso.

2.  **Configurazione Iniziale per ogni Task**: Per ogni **nuova** operazione di sincronizzazione che vuoi creare (es. un nuovo `bisync` per una nuova cartella), esegui **una volta** lo script di `test_setup_*` corrispondente. Questo crea la struttura di directory (`~/.config/rclone/conf_dir_*`), i file di log e imposta `logrotate`.
    ```bash
    # Esempio per un nuovo task di bisync
    ./test/test_setup_rclone_bisync.sh /home/utente/Documenti MyRemote:Documenti
    ```

---

### Project Structure

The scripts are organized into directories based on their function:

*   **`/` (root)**: Contiene gli script principali pronti per l'uso in produzione (`rclone_bisync.sh`, `rclone_sync.sh`).
*   **`/test`**: Contiene varianti degli script principali con modalità debug abilitata (`test_setup_*`) e script semplificati per testare i comandi base (`test_command_*`).
*   **`/utility`**: Contiene script per operazioni manuali (`rclone_copy_*`), wrapper per l'esecuzione tramite cron di sistema (`wrapper_*`) e file di configurazione di esempio.

---

### Script in Dettaglio

#### `rclone_bisync.sh`

**Ruolo**: Script principale per la sincronizzazione bidirezionale (`locale <-> remoto`). È progettato per essere eseguito a intervalli regolari tramite `cron` dell'utente.

**Funzionalità chiave**:
*   **Sincronizzazione Bidirezionale**: Usa `rclone bisync`.
*   **Recupero Automatico**: In caso di fallimento, esegue controlli di connettività, permessi e spazio, quindi tenta un `--resync`.
*   **Safety Check**: Prima di agire, controlla i file aperti (`lsof`) o modificati di recente (`find`) nella directory locale, attendendo o saltando il ciclo per evitare conflitti.
*   **Locking**: Utilizza il sistema di lock a due livelli per garantire l'integrità delle operazioni.

#### `rclone_sync.sh`

**Ruolo**: Esegue una sincronizzazione **unidirezionale** da un percorso remoto a un altro (`remoto -> remoto`). Ideale per backup tra servizi cloud.

**Funzionalità chiave**:
*   **Sincronizzazione Unidirezionale**: Usa `rclone sync`.
*   **Gestione Errori**: Controlla la connettività e invia notifiche in caso di fallimento.
*   **Locking**: Condivide lo stesso sistema di lock del `bisync.sh` per evitare conflitti sullo stesso remote.

#### Script di Utility (`rclone_copy_*`)

**Ruolo**: Script semplici per eseguire operazioni di copia (`rclone copy`) una tantum. A differenza di un `rclone copy` manuale, questi script **rispettano il sistema di lock**, attendendo se un'altra operazione (come `bisync`) è in corso sullo stesso remote.

**Utilizzo**:
```bash
# Copia dal cloud a una cartella locale
./utility/rclone_copy_remote_to_local.sh MyRemote:file.zip /home/user/download/

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