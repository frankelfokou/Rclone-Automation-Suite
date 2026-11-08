#!/bin/bash
# Test di contratto su setup.sh e unsetup.sh: verificano che installazione e
# disinstallazione contengano tutti i passaggi richiesti dalla documentazione.
# Non eseguono setup.sh (richiede root e modifica il sistema): per il test
# end-to-end reale vedere la sezione 9.5 di AGENTS.md.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"

SETUP="$REPO_ROOT/setup.sh"
UNSETUP="$REPO_ROOT/unsetup.sh"

printf '\n-- setup.sh --\n'
assert_contains "$SETUP" 'if [ "$EUID" -ne 0 ]' "setup richiede root"
assert_contains "$SETUP" 'conf_dir_${remote}/log_files' "setup crea log_files"
assert_contains "$SETUP" 'conf_dir_${remote}/lock_files' "setup crea lock_files"
assert_contains "$SETUP" 'config/exclude_patterns.txt' "setup installa exclude_patterns.txt da config/"
assert_contains "$SETUP" 'RCLONE_TEST' "setup gestisce RCLONE_TEST"
assert_contains "$SETUP" 'loginctl enable-linger' "setup abilita linger"
assert_contains "$SETUP" 'watcher gdrive-f4frank' "setup aggiunge logrotate watcher"
assert_contains "$SETUP" 'bisync gdrive-pro' "setup aggiunge logrotate bisync pro"
assert_contains "$SETUP" 'sync pro-to-mega' "setup aggiunge logrotate sync pro-to-mega"
assert_contains "$SETUP" 'rclone-bisync@.service' "setup copia il servizio bisync"
assert_contains "$SETUP" 'rclone-bisync@.timer' "setup copia il timer bisync"
assert_contains "$SETUP" 'rclone-sync@.service' "setup copia il servizio sync"
assert_contains "$SETUP" 'rclone-sync@.timer' "setup copia il timer sync"
assert_contains "$SETUP" 'rclone-bisync-watcher@.service' "setup copia il watcher"
assert_contains "$SETUP" 'rclone-bisync-gdrive-f4frank.env' "setup copia l'env bisync"
assert_contains "$SETUP" 'rclone-sync-drive-to-drive.env' "setup rimuove l'env F4Frank -> GDrive-Pro"
assert_contains "$SETUP" 'rclone-sync-f4frank-to-mega.env' "setup copia l'env f4frank-to-mega"
assert_contains "$SETUP" 'rclone-sync-pro-to-mega.env' "setup copia l'env pro-to-mega"
assert_contains "$SETUP" 'rclone-bisync-gdrive-pro.env' "setup copia l'env bisync gdrive-pro"
assert_contains "$SETUP" 'enable --now' "setup abilita i timer"
assert_contains "$SETUP" 'rclone-bisync@gdrive-pro.timer' "setup abilita il timer bisync pro"
assert_contains "$SETUP" 'rclone-sync@f4frank-to-mega.timer' "setup abilita il sync f4frank-to-mega"
assert_contains "$SETUP" 'rclone-sync@pro-to-mega.timer' "setup abilita il sync pro-to-mega"
assert_contains "$SETUP" 'WATCHERS=(gdrive-f4frank gdrive-pro)' "setup abilita i due watcher"
assert_contains "$SETUP" 'LEGACY_CRON_MARKERS' "setup ripulisce le righe cron legacy"
assert_contains "$SETUP" 'inotifywait' "setup verifica inotifywait"
assert_contains "$SETUP" 'scripts/lib/common.sh' "setup copia lib/common.sh"
assert_contains "$SETUP" 'BIN_FOLDER/lib' "setup crea ~/.bin/lib"

printf '\n-- unsetup.sh --\n'
assert_contains "$UNSETUP" 'for instance in gdrive-f4frank gdrive-pro' "unsetup ferma i due watcher"
assert_contains "$UNSETUP" 'stop "rclone-bisync-watcher@${instance}.service"' "unsetup ferma il watcher"
assert_contains "$UNSETUP" 'disable "rclone-bisync-watcher@${instance}.service"' "unsetup disabilita il watcher"
assert_contains "$UNSETUP" 'watcher_gdrive-f4frank' "unsetup rimuove il logrotate watcher"
assert_contains "$UNSETUP" 'rclone-bisync-watcher@.service' "unsetup rimuove l'unità watcher"
assert_contains "$UNSETUP" '.blocked' "unsetup rimuove i marker .blocked"
assert_contains "$UNSETUP" 'LEGACY_CRON_MARKERS' "unsetup ripulisce le righe cron legacy"
assert_contains "$UNSETUP" 'rclone_bisync.sh' "unsetup rimuove rclone_bisync.sh"
assert_contains "$UNSETUP" 'rclone_sync.sh' "unsetup rimuove rclone_sync.sh"
assert_contains "$UNSETUP" 'rclone_watch_bisync.sh' "unsetup rimuove rclone_watch_bisync.sh"
assert_contains "$UNSETUP" 'lib/common.sh' "unsetup rimuove lib/common.sh"
assert_contains "$UNSETUP" 'exclude_patterns.txt' "unsetup rimuove il file di esclusione"

printf '\n-- coerenza sorgenti --\n'
assert_exists "$REPO_ROOT/scripts/rclone_bisync.sh" "sorgente bisync presente"
assert_exists "$REPO_ROOT/scripts/rclone_sync.sh" "sorgente sync presente"
assert_exists "$REPO_ROOT/scripts/rclone_watch_bisync.sh" "sorgente watcher presente"
assert_exists "$REPO_ROOT/scripts/lib/common.sh" "modulo comune presente"
assert_exists "$REPO_ROOT/config/exclude_patterns.txt" "template exclude_patterns.txt presente"

if grep -rq 'utility/' "$SETUP" "$UNSETUP"; then
    fail "nessun riferimento a utility/ in setup/unsetup"
else
    pass "nessun riferimento a utility/ in setup/unsetup"
fi

if grep -rq 'legacy/' "$SETUP" "$UNSETUP"; then
    fail "nessun riferimento a legacy/ in setup/unsetup"
else
    pass "nessun riferimento a legacy/ in setup/unsetup"
fi

if grep -rqE '\bdocs/' "$SETUP" "$UNSETUP"; then
    fail "nessun riferimento a docs/ in setup/unsetup"
else
    pass "nessun riferimento a docs/ in setup/unsetup"
fi

printf '\n-- test root --\n'
if [ "${RUN_ROOT_TESTS:-0}" = "1" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        skip "test root end-to-end" "eseguire manualmente la sezione 9.5 di AGENTS.md"
    else
        skip "test root end-to-end" "richiede root"
    fi
else
    skip "test root end-to-end" "impostare RUN_ROOT_TESTS=1 per abilitarlo"
fi

finish
