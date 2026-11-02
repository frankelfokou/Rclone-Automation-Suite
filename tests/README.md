# Suite di test

Test automatici per la suite `rclone-automation-suite`. Non toccano Google Drive:
usano stub di `rclone` e alberi temporanei. L'unica eccezione è
`test_40_flags.sh`, che usa una coppia locale usa-e-getta con il vero `rclone`.

## Esecuzione

```bash
./tests/run_all.sh            # tutti i test
./tests/run_all.sh bisync     # solo i test con "bisync" nel nome
./tests/run_all.sh --keep     # mantiene le directory temporanee
```

Il runner termina con codice `0` se tutti i test passano, `1` altrimenti.
Ogni test stampa `ok`, `FAIL` o `skip` per singola verifica.

## Requisiti

- `bash`, `sed`, `grep`, `flock` (util-linux), `lsof`, `inotifywait`
  (inotify-tools);
- `rclone` solo per `test_40_flags.sh` (se manca, il test viene saltato);
- `systemd-analyze` facoltativo, usato da `test_00_static.sh`.

## Copertura

| File | Cosa verifica |
|---|---|
| `test_00_static.sh` | presenza file, `bash -n`, contenuto delle unità systemd, file `.env`, riferimenti a `scripts/`, `legacy/`, `docs/`, `tests/`, assenza di `utility/`, `systemd-analyze verify` |
| `test_10_bisync.sh` | validazione argomenti, remote non configurato, directory mancante, lock 201/200, file aperti, run normale, exit 1, exit 7 con resync ok/ko, connettività, log |
| `test_20_watcher.sh` | marker bloccato, directory mancante, gate `lsof`, ripresa alla chiusura, evento durante la run, debounce, exit 7, cleanup di FIFO e `inotifywait` |
| `test_30_setup_contract.sh` | contratto di `setup.sh`/`unsetup.sh`: directory, exclude, `RCLONE_TEST`, logrotate watcher, unità, linger, script |
| `test_40_flags.sh` | `--conflict-resolve newer`, `--resync-mode newer` e fallback con mtime uguali su coppia locale |

## Test che richiedono root

L'installazione reale non viene eseguita automaticamente: `setup.sh` modifica
`~/.config/systemd/user`, `/etc/logrotate.d` e il crontab. Il test di contratto
verifica i passaggi; il test end-to-end va eseguito manualmente seguendo la
sezione 9.5 di `AGENTS.md`:

```bash
sudo ./setup.sh
systemctl --user list-timers --all | grep rclone
systemctl --user status rclone-bisync-watcher@gdrive-f4frank.service
sudo ./unsetup.sh
```

Impostare `RUN_ROOT_TESTS=1` abilita solo il messaggio informativo nel test di
contratto; non esegue operazioni privilegiate.

## Variabili utili

| Variabile | Effetto |
|---|---|
| `KEEP_TMP=1` | mantiene le directory temporanee per il debug |
| `TMPDIR` | directory base per i file temporanei |
| `TEST_TMP` | usa una directory specifica per un singolo test |
| `RUN_ROOT_TESTS=1` | abilita il promemoria del test root in `test_30` |
