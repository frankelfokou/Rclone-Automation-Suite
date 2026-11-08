#!/bin/bash
# Verifiche statiche: presenza file, sintassi, unità systemd, riferimenti.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"

printf '\n-- file e sintassi --\n'
for file in \
    scripts/rclone_bisync.sh \
    scripts/rclone_sync.sh \
    scripts/rclone_watch_bisync.sh \
    scripts/lib/common.sh \
    setup.sh \
    unsetup.sh
do
    assert_exists "$REPO_ROOT/$file" "esiste $file"
    if bash -n "$REPO_ROOT/$file" 2>/dev/null; then
        pass "sintassi $file"
    else
        fail "sintassi $file"
    fi
done

printf '\n-- moduli --\n'
assert_exists "$REPO_ROOT/scripts/lib/common.sh" "esiste scripts/lib/common.sh"
for entry in \
    scripts/rclone_bisync.sh \
    scripts/rclone_sync.sh \
    scripts/rclone_watch_bisync.sh
do
    assert_contains "$REPO_ROOT/$entry" 'lib/common.sh' \
        "$entry carica il modulo comune"
done

printf '\n-- unità systemd --\n'
for unit in \
    systemd/user/rclone-bisync@.service \
    systemd/user/rclone-bisync@.timer \
    systemd/user/rclone-sync@.service \
    systemd/user/rclone-sync@.timer \
    systemd/user/rclone-bisync-watcher@.service
do
    assert_exists "$REPO_ROOT/$unit" "esiste $unit"
done

assert_contains "$REPO_ROOT/systemd/user/rclone-bisync@.service" \
    "SuccessExitStatus=75" "bisync service considera 75 un successo"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync@.timer" \
    "OnUnitActiveSec=2min" "timer bisync a 2 minuti"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync@.timer" \
    "AccuracySec=10s" "timer bisync con AccuracySec"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-watcher@.service" \
    "Restart=on-failure" "watcher con Restart=on-failure"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-watcher@.service" \
    "SuccessExitStatus=75" "watcher considera 75 un successo"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-watcher@.service" \
    "rclone_watch_bisync.sh \${LOCAL_PATH} \${REMOTE_PATH} 15" \
    "watcher con debounce 15"

printf '\n-- file .env --\n'
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-gdrive-f4frank.env" \
    "LOCAL_PATH=/home/frankel/GDrive-F4Frank" "env bisync f4frank LOCAL_PATH"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-gdrive-f4frank.env" \
    "REMOTE_PATH=GDrive-F4Frank:" "env bisync f4frank REMOTE_PATH"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-gdrive-pro.env" \
    "LOCAL_PATH=/home/frankel/GDrive-Pro" "env bisync pro LOCAL_PATH"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-gdrive-pro.env" \
    "REMOTE_PATH=GDrive-Pro:" "env bisync pro REMOTE_PATH"
assert_contains "$REPO_ROOT/systemd/user/rclone-sync-f4frank-to-mega.env" \
    "SOURCE_PATH=GDrive-F4Frank:" "env sync f4frank-to-mega SOURCE"
assert_contains "$REPO_ROOT/systemd/user/rclone-sync-f4frank-to-mega.env" \
    "DEST_PATH=Mega:GDrive-F4Frank" "env sync f4frank-to-mega DEST"
assert_contains "$REPO_ROOT/systemd/user/rclone-sync-pro-to-mega.env" \
    "SOURCE_PATH=GDrive-Pro:" "env sync pro-to-mega SOURCE"
assert_contains "$REPO_ROOT/systemd/user/rclone-sync-pro-to-mega.env" \
    "DEST_PATH=Mega:GDrive-Pro" "env sync pro-to-mega DEST"
assert_absent "$REPO_ROOT/systemd/user/rclone-sync-drive-to-drive.env" \
    "env F4Frank -> GDrive-Pro rimosso"
assert_absent "$REPO_ROOT/systemd/user/rclone-sync-drive-to-mega.env" \
    "env drive-to-mega legacy rimosso"

printf '\n-- struttura e riferimenti --\n'
assert_exists "$REPO_ROOT/config/exclude_patterns.txt" "esiste config/exclude_patterns.txt"
assert_exists "$REPO_ROOT/tests/run_all.sh" "esiste tests/run_all.sh"
assert_absent "$REPO_ROOT/utility" "la vecchia directory utility/ è stata rimossa"
assert_absent "$REPO_ROOT/test" "la vecchia directory test/ è stata rimossa"
assert_absent "$REPO_ROOT/legacy" "la directory legacy/ è stata rimossa"
assert_absent "$REPO_ROOT/docs" "la directory docs/ è stata rimossa"

if grep -q 'scripts/rclone_bisync.sh' "$REPO_ROOT/setup.sh"; then
    pass "setup.sh usa scripts/rclone_bisync.sh"
else
    fail "setup.sh usa scripts/rclone_bisync.sh"
fi
if grep -q 'scripts/rclone_sync.sh' "$REPO_ROOT/setup.sh"; then
    pass "setup.sh usa scripts/rclone_sync.sh"
else
    fail "setup.sh usa scripts/rclone_sync.sh"
fi
if grep -q 'scripts/rclone_watch_bisync.sh' "$REPO_ROOT/setup.sh"; then
    pass "setup.sh usa scripts/rclone_watch_bisync.sh"
else
    fail "setup.sh usa scripts/rclone_watch_bisync.sh"
fi
if grep -q 'config/exclude_patterns.txt' "$REPO_ROOT/setup.sh"; then
    pass "setup installa config/exclude_patterns.txt"
else
    fail "setup installa config/exclude_patterns.txt"
fi
if grep -q 'LEGACY_CRON_MARKERS' "$REPO_ROOT/setup.sh" "$REPO_ROOT/unsetup.sh"; then
    pass "setup/unsetup ripuliscono le righe cron legacy"
else
    fail "setup/unsetup ripuliscono le righe cron legacy"
fi
if grep -rq 'utility/' "$REPO_ROOT/setup.sh" "$REPO_ROOT/unsetup.sh"; then
    fail "nessun riferimento residuo a utility/ in setup/unsetup"
else
    pass "nessun riferimento residuo a utility/ in setup/unsetup"
fi
if grep -rqE 'legacy/|\bdocs/' "$REPO_ROOT/setup.sh" "$REPO_ROOT/unsetup.sh"; then
    fail "nessun riferimento residuo a legacy/ o docs/ in setup/unsetup"
else
    pass "nessun riferimento residuo a legacy/ o docs/ in setup/unsetup"
fi
assert_contains "$REPO_ROOT/setup.sh" 'scripts/lib/common.sh' \
    "setup.sh installa il modulo comune"
assert_contains "$REPO_ROOT/unsetup.sh" 'lib/common.sh' \
    "unsetup.sh rimuove il modulo comune"

printf '\n-- formato di log e notifiche --\n'
assert_contains "$REPO_ROOT/scripts/lib/common.sh" '[%s] [%s] [%s] %s' \
    "il modulo definisce il formato standard dei record"
assert_contains "$REPO_ROOT/scripts/lib/common.sh" 'log_emit' \
    "il modulo espone lo scrittore unico log_emit"
for entry in rclone_bisync.sh rclone_sync.sh rclone_watch_bisync.sh; do
    assert_contains "$REPO_ROOT/scripts/$entry" 'LOG_TAG=' \
        "scripts/$entry imposta LOG_TAG"
    assert_not_contains "$REPO_ROOT/scripts/$entry" 'echo "$MSG" >&2' \
        "scripts/$entry non scrive log a mano"
done
assert_not_contains "$REPO_ROOT/scripts/lib/common.sh" '[$(date)]' \
    "nessun log scritto a mano nel modulo"
assert_contains "$REPO_ROOT/scripts/lib/common.sh" 'NOTIFY_MIN_LEVEL' \
    "il modulo definisce la soglia delle notifiche"
assert_contains "$REPO_ROOT/AGENTS.md" "Formato di log e notifiche" \
    "AGENTS.md documenta il formato di log e notifiche"

printf '\n-- documentazione --\n'
assert_contains "$REPO_ROOT/AGENTS.md" "## 2. Glossario" "AGENTS.md contiene il glossario"
assert_contains "$REPO_ROOT/AGENTS.md" "## 9. Test" "AGENTS.md contiene la sezione test"
assert_contains "$REPO_ROOT/AGENTS.md" '```mermaid' "AGENTS.md contiene diagrammi Mermaid"
assert_contains "$REPO_ROOT/AGENTS.md" "scripts/rclone_bisync.sh" "AGENTS.md usa i nuovi percorsi"

printf '\n-- systemd-analyze --\n'
if command -v systemd-analyze >/dev/null 2>&1; then
    verify_out=$(systemd-analyze verify \
        "$REPO_ROOT/systemd/user/rclone-bisync@.service" \
        "$REPO_ROOT/systemd/user/rclone-bisync@.timer" \
        "$REPO_ROOT/systemd/user/rclone-sync@.service" \
        "$REPO_ROOT/systemd/user/rclone-sync@.timer" \
        "$REPO_ROOT/systemd/user/rclone-bisync-watcher@.service" 2>&1 \
        | grep -v 'is not executable' \
        | grep -v '^$')
    if [ -z "$verify_out" ]; then
        pass "systemd-analyze verify senza errori inattesi"
    else
        fail "systemd-analyze verify" "$verify_out"
    fi
else
    skip "systemd-analyze non disponibile"
fi

finish
