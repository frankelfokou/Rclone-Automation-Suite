# Rclone Automation Suite

Sincronizzazione bidirezionale tra due cartelle locali e i rispettivi remote Google Drive, con aggiornamento in tempo reale delle modifiche locali, riconciliazione periodica delle modifiche remote e **riparazione automatica** degli errori. Lo scheduler è basato su **systemd user services**.

| Coppia | Locale | Remote | Backup |
|---|---|---|---|
| F4Frank | `~/GDrive-F4Frank` | `GDrive-F4Frank:` | `Mega:GDrive-F4Frank` |
| Pro (vault Obsidian) | `~/GDrive-Pro` | `GDrive-Pro:` | `Mega:GDrive-Pro` |

## Cosa fa

- **Locale → Drive**: un watcher `inotify` per coppia applica un debounce, attende che i file siano chiusi e lancia `rclone bisync` (latenza di secondi). Gli eventi transitori (`workspace.json`, `.trash/`, file temporanei) non innescano nulla.
- **Drive → locale**: un timer systemd per coppia esegue `rclone bisync` ogni 5 minuti (configurabile).
- **Backup remoto → remoto**: `rclone sync` giornaliero di ciascun Drive nella propria sottocartella su Mega, con `--max-delete` (le cancellazioni di massa sono bloccate) e `--backup-dir` (i file rimossi restano in `Mega:_rclone-backup/`).
- I rinvii usano `exit 75` e non vengono confusi con i successi.
- Log e notifiche condividono un formato unico: `[YYYY-MM-DD HH:MM:SS] [LIVELLO] [TAG] messaggio`, con livello `DEBUG`, `INFO`, `WARN`, `ERROR` o `CRITICAL`. Le notifiche partono da `WARN` in su, sono deduplicate e in assenza di rete non arrivano affatto.

## Auto-riparazione

- **Classificazione degli errori**: rete, quota, credenziali, cancellazioni di massa, errore critico. Ogni classe ha un'azione precisa; nessun errore viene più trattato come "rinvio per sempre".
- **Analisi del danno**: se un lato ha perso molti file, il sistema confronta i conteggi con i listing precedenti e ripristina il lato mancante. Una cancellazione di massa non viene **mai** propagata automaticamente.
- **Cooldown invece di blocco**: dopo un errore critico il run successivo avviene dopo 15 minuti, poi 1 ora, 6 ore, 24 ore. Nessun intervento manuale.
- **Invarianti delle coppie**: in Pro esiste solo `Obsidian/`; il vault non deve mai comparire in F4Frank. Ciò che non rispetta l'invariante viene spostato (vince il file più recente) o eliminato.
- **Quarantena**: nulla viene cancellato subito; le voci rimosse restano 7 giorni in `~/.local/share/rclone-quarantine/`.

## Struttura

```text
.
├── AGENTS.md                 # documentazione tecnica completa
├── README.md                 # questo file
├── setup.sh                  # installazione (richiede root)
├── unsetup.sh                # disinstallazione (richiede root)
├── config/
│   ├── exclude_patterns.txt  # esclusioni comuni
│   └── exclude_obsidian.txt  # esclusioni del vault (stato volatile)
├── scripts/
│   ├── lib/common.sh         # modulo condiviso (log, lock, guard, riparazione)
│   ├── rclone_bisync.sh      # orchestrazione bisync con auto-riparazione
│   ├── rclone_sync.sh        # backup remoto -> remoto protetto
│   └── rclone_watch_bisync.sh  # watcher realtime con retry
├── systemd/user/             # unità, timer, logrotate utente e file .env
├── tests/                    # suite di test, un file per modulo
└── android/                  # documentazione Android (non modificare)
```

`scripts/lib/common.sh` raccoglie tutto ciò che bisync e sync condividono: logging, notifiche con deduplica, validazione, percorsi, lock, safety check, classificazione degli errori, analisi del danno, guard degli invarianti, quarantena e stato persistente. Gli entrypoint fanno solo orchestrazione e lo caricano con `. "${SCRIPT_DIR}/lib/common.sh"`, quindi lo stesso codice gira dal repository e da `~/.bin` dopo l'installazione.

## Installazione rapida

```bash
sudo dnf install rclone inotify-tools util-linux lsof logrotate libnotify
sudo ./setup.sh

systemctl --user list-timers --all | grep rclone
systemctl --user status rclone-bisync-watcher@gdrive-f4frank.service
```

`setup.sh` rimuove anche i wrapper legacy in `/etc/cron.daily` e le definizioni logrotate di sistema duplicate: erano la causa delle cancellazioni notturne del vault e dei backup.

Dopo una modifica agli script:

```bash
sudo ./setup.sh
systemctl --user daemon-reload
systemctl --user restart rclone-bisync-watcher@gdrive-f4frank.service
```

## Test

```bash
./tests/run_all.sh
```

Le verifiche sono per modulo: `test_05_common.sh` copre i contratti di `scripts/lib/common.sh`, `test_10_bisync.sh` il bisync, `test_15_sync.sh` il sync, `test_20_watcher.sh` il watcher, `test_25_healing.sh` classificazione, cooldown, guard e quarantena. I test non toccano Google Drive: usano stub di `rclone` e directory temporanee; `test_40_flags.sh` usa una coppia locale usa-e-getta con il vero `rclone`. Dettagli in [`tests/README.md`](tests/README.md).

## Documentazione

- [`AGENTS.md`](AGENTS.md): architettura, flussi, codice, auto-riparazione, scelte implementative, troubleshooting e procedure di test.
- [`config/exclude_patterns.txt`](config/exclude_patterns.txt): esclusioni comuni, installate da `setup.sh` in `~/.config/rclone/exclude_patterns.txt`.
- [`config/exclude_obsidian.txt`](config/exclude_obsidian.txt): esclusioni del vault, installate in `~/.config/rclone/exclude_obsidian.txt`.

## Disinstallazione

```bash
sudo ./unsetup.sh
```

Rimuove anche i file di esclusione installati (ripristina il `.bak` se esiste) e la configurazione logrotate utente. I log, i listing di bisync e la quarantena restano in `~/.config/rclone/`, `~/.cache/rclone/bisync/` e `~/.local/share/rclone-quarantine/` e vanno rimossi manualmente.
