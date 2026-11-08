# Rclone Automation Suite

Sincronizzazione bidirezionale tra due cartelle locali e i rispettivi remote Google Drive, con aggiornamento in tempo reale delle modifiche locali e riconciliazione periodica delle modifiche remote. Lo scheduler è basato su **systemd user services**.

| Coppia | Locale | Remote | Backup |
|---|---|---|---|
| F4Frank | `~/GDrive-F4Frank` | `GDrive-F4Frank:` | `Mega:GDrive-F4Frank` |
| Pro (vault Obsidian) | `~/GDrive-Pro` | `GDrive-Pro:` | `Mega:GDrive-Pro` |

## Cosa fa

- **Locale → Drive**: un watcher `inotify` per coppia applica un debounce, attende che i file siano chiusi e lancia `rclone bisync` (latenza di secondi).
- **Drive → locale**: un timer systemd per coppia esegue `rclone bisync` ogni 2 minuti (configurabile).
- **Backup remoto → remoto**: `rclone sync` giornaliero di ciascun Drive nella propria sottocartella su Mega.
- I rinvii usano `exit 75` e non vengono confusi con i successi.
- Log e notifiche condividono un formato unico: `[YYYY-MM-DD HH:MM:SS] [LIVELLO] [TAG] messaggio`, con livello `DEBUG`, `INFO`, `WARN`, `ERROR` o `CRITICAL`. Le notifiche partono da `WARN` in su e usano icona e urgenza coerenti con il livello.

## Struttura

```text
.
├── AGENTS.md                 # documentazione tecnica completa
├── README.md                 # questo file
├── setup.sh                  # installazione (richiede root)
├── unsetup.sh                # disinstallazione (richiede root)
├── config/
│   └── exclude_patterns.txt  # template delle esclusioni, installato in ~/.config/rclone
├── scripts/
│   ├── lib/common.sh         # modulo condiviso (log, lock, safety, rclone)
│   ├── rclone_bisync.sh      # orchestrazione bisync
│   ├── rclone_sync.sh        # orchestrazione sync
│   └── rclone_watch_bisync.sh  # watcher realtime
├── systemd/user/             # unità e file .env
├── tests/                    # suite di test, un file per modulo
└── android/                  # documentazione Android (non modificare)
```

`scripts/lib/common.sh` raccoglie tutto ciò che bisync e sync condividono: logging, notifiche, validazione, percorsi, lock, safety check ed esecuzione di rclone. Gli entrypoint fanno solo orchestrazione e lo caricano con `. "${SCRIPT_DIR}/lib/common.sh"`, quindi lo stesso codice gira dal repository e da `~/.bin` dopo l'installazione.

## Installazione rapida

```bash
sudo dnf install rclone inotify-tools util-linux lsof logrotate libnotify
sudo ./setup.sh

systemctl --user list-timers --all | grep rclone
systemctl --user status rclone-bisync-watcher@gdrive-f4frank.service
```

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

Le verifiche sono per modulo: `test_05_common.sh` copre i contratti di `scripts/lib/common.sh`, `test_10_bisync.sh` il bisync, `test_15_sync.sh` il sync e `test_20_watcher.sh` il watcher. I test non toccano Google Drive: usano stub di `rclone` e directory temporanee; `test_40_flags.sh` usa una coppia locale usa-e-getta con il vero `rclone`. Dettagli in [`tests/README.md`](tests/README.md).

## Documentazione

- [`AGENTS.md`](AGENTS.md): architettura, flussi, codice, scelte implementative, troubleshooting e procedure di test.
- [`config/exclude_patterns.txt`](config/exclude_patterns.txt): esclusioni comuni, installate da `setup.sh` in `~/.config/rclone/exclude_patterns.txt`.

## Disinstallazione

```bash
sudo ./unsetup.sh
```

Rimuove anche il file di esclusione installato (ripristina il `.bak` se esiste). I log e i listing di bisync restano in `~/.config/rclone/` e `~/.cache/rclone/bisync/` e vanno rimossi manualmente.
