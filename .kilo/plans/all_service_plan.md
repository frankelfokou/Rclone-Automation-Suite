# Piano di implementazione — Conversione a servizi systemd

**File piano:** `.kilo/plans/all_service_plan.md`  
**Repository:** `rclone-automation-suite`  
**Utente target:** `frankel`  
**Obiettivo:** Sostituire crontab utente e wrapper `/etc/cron.daily` con servizi systemd, con il minor numero di unità possibile.

---

## Decisioni architetturali (risolte)

| Decisione | Scelta | Motivazione |
|---|---|---|
| Ambito | Tutto il sistema (bisync + sync) | Richiesto dall'utente: "tutto il sistema giri sotto forma di servizi, il minor numero di servizi possibile" |
| Tipo unità | **User service** (`systemctl --user`) | Gli script usano path di `/home/frankel`, `notify-send`, `DBUS_SESSION_BUS_ADDRESS` |
| Avvio al boot senza login | `loginctl enable-linger frankel` | Permette ai user service di partire al boot anche senza sessione grafica attiva |
| Template vs istanze | **Unità template** `rclone-bisync@.service` e `rclone-sync@.service` | Un singolo template gestisce tutte le istanze; minor numero di file |
| Parametri per istanza | `EnvironmentFile` (`rclone-*-%i.env`) con `LOCAL_PATH`/`REMOTE_PATH` | Evita di hardcodare path in ogni unit |
| Scheduler | **Timer systemd** (`OnBootSec` + `OnUnitActiveSec` / `OnCalendar`) | Sostituisce crontab `*/10` e `@reboot` |
| Numero minimo di unità | 4 unità user: 2 service template + 2 timer | Un timer per bisync (periodico + boot), uno per sync (giornaliero) |

---

## Unità systemd da creare

Tutte in `/home/frankel/.config/systemd/user/`:

### 1. `rclone-bisync@.service` (template)
- `Type=oneshot`
- `After=network-online.target`, `Wants=network-online.target`
- `EnvironmentFile=-/home/frankel/.config/systemd/user/rclone-bisync-%i.env`
- `ExecStart=/home/frankel/.bin/rclone_bisync.sh ${LOCAL_PATH} ${REMOTE_PATH}`

### 2. `rclone-sync@.service` (template)
- Stessa struttura, richiama `rclone_sync.sh`

### 3. `rclone-bisync.timer`
- `OnBootSec=1min` (avvio al boot con ritardo per WiFi)
- `OnUnitActiveSec=10min` (sostituisce crontab `*/10`)
- `Unit=rclone-bisync@gdrive-f4frank.service`

### 4. `rclone-sync.timer`
- `OnBootSec=5min`, `OnCalendar=daily` (sostituisce wrapper `/etc/cron.daily`)
- `Unit=rclone-sync@<istanza>.service`

### 5. File di ambiente per istanza (esempio)
`rclone-bisync-gdrive-f4frank.env`:
```
LOCAL_PATH=/home/frankel/GDrive-F4Frank
REMOTE_PATH=GDrive-F4Frank:
```

---

## File da modificare (setup.sh e unsetup.sh)

### `setup.sh` — aggiungere
- Creare `/home/frankel/.config/systemd/user/`
- Copiare le 4 unità user + i file `.env`
- Eseguire `loginctl enable-listen frankel` (richiede root, già previsto)
- Ricaricare e abilitare timer/servizi come utente `frankel` (via `sudo -u frankel XDG_RUNTIME_DIR=/run/user/1000 systemctl --user ...`)
- Idempotenza: se unità già presenti e abilitate, non rieseguire
- Rimuovere/disabilitare le vecchie righe di crontab utente (opzionale)

### `unsetup.sh` — aggiungere
- Fermare e disabilitare i timer e i servizi user di `frankel`
- Rimuovere i file unità e `.env` da `~/.config/systemd/user/`
- `systemctl --user daemon-reload`

---

## Ordine di implementazione (task)

1. Creare `systemd/user/rclone-bisync@.service`
2. Creare `systemd/user/rclone-sync@.service`
3. Creare `systemd/user/rclone-bisync.timer`
4. Creare `systemd/user/rclone-sync.timer`
5. Creare file `.env` per l'istanza `gdrive-f4frank` (bisync) e per sync
6. Aggiornare `setup.sh`: installazione unità, `enable-linger`, `daemon-reload`, enable/start timer, idempotenza
7. Aggiornare `unsetup.sh`: stop/disable/rimozione unità, `daemon-reload`
8. Verifica sintassi (`bash -n`, `systemd-analyze verify` se disponibile)
9. Test funzionale: `sudo ./setup.sh`, `systemctl --user list-timers`, esecuzione servizio, poi `sudo ./unsetup.sh`

---

## Rischi e mitigazioni

| Rischio | Mitigazione |
|---|---|
| `systemctl --user` da root senza `XDG_RUNTIME_DIR` | Usare `sudo -u frankel XDG_RUNTIME_DIR=/run/user/1000 systemctl --user ...` |
| User service non parte al boot senza login | `loginctl enable-linger frankel` |
| `notify-send` fallisce al boot senza sessione grafica | Lo script imposta già `DBUS_SESSION_BUS_ADDRESS` di fallback; `|| true` sulla notifica |
| Sovrapposizione esecuzioni | I lock `flock` a due livelli già presenti negli script restano invariati |

---

## Out of scope

- Conversione di `logrotate` in servizio systemd (resta gestito dagli script)
- Wrapper `rclone_copy_*` in `utility/` (non installati da `setup.sh`)
- Test in `test/`
- Supporto utenti diversi da `frankel` (path hardcoded, come nell'esistente)

---

## Domande aperte (da risolvere in fase di implementazione)

1. Nome esatto dell'istanza sync per `rclone-sync.timer` (es. `drive-to-mega`, `drive-to-drive`) — dipende dai wrapper esistenti in `/etc/cron.daily`.
2. Se mantenere le vecchie righe di crontab utente come fallback o rimuoverle definitivamente dopo l'attivazione dei timer.
