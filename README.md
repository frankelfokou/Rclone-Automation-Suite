# Rclone Automation Suite

Sincronizzazione bidirezionale tra una cartella locale e Google Drive, con
aggiornamento in tempo reale delle modifiche locali e riconciliazione periodica
delle modifiche remote. Lo scheduler è basato su **systemd user services**.

## Cosa fa

- **Locale → Drive**: un watcher `inotify` applica un debounce, attende che i file
  siano chiusi e lancia `rclone bisync` (latenza di secondi).
- **Drive → locale**: un timer systemd esegue `rclone bisync` ogni 2 minuti
  (configurabile).
- **Backup remoto → remoto**: `rclone sync` giornaliero verso altri remote.
- I rinvii usano `exit 75` e non vengono confusi con i successi.

## Struttura

```text
.
├── AGENTS.md                 # documentazione tecnica completa
├── README.md                 # questo file
├── setup.sh                  # installazione (richiede root)
├── unsetup.sh                # disinstallazione (richiede root)
├── docs/                     # piano di implementazione
├── legacy/                   # artefatti della vecchia configurazione cron
├── scripts/                  # script di sincronizzazione e watcher
├── systemd/user/             # unità e file .env
├── tests/                    # suite di test
└── android/                  # documentazione Android (non modificare)
```

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

I test non toccano Google Drive: usano stub di `rclone` e directory temporanee.
`test_40_flags.sh` usa una coppia locale usa-e-getta con il vero `rclone`.
Dettagli in [`tests/README.md`](tests/README.md).

## Documentazione

- [`AGENTS.md`](AGENTS.md): architettura, flussi, codice, scelte implementative,
  troubleshooting e procedure di test.
- [`docs/all_service_plan.md`](docs/all_service_plan.md): piano di implementazione
  e cronologia delle decisioni.

## Disinstallazione

```bash
sudo ./unsetup.sh
```

I log e i listing di bisync restano in `~/.config/rclone/` e
`~/.cache/rclone/bisync/` e vanno rimossi manualmente.
