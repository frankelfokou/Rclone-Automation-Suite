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
    "LOCAL_PATH=/home/frankel/GDrive-F4Frank" "env bisync LOCAL_PATH"
assert_contains "$REPO_ROOT/systemd/user/rclone-bisync-gdrive-f4frank.env" \
    "REMOTE_PATH=GDrive-F4Frank:" "env bisync REMOTE_PATH"
assert_contains "$REPO_ROOT/systemd/user/rclone-sync-drive-to-drive.env" \
    "SOURCE_PATH=GDrive-F4Frank:" "env sync drive-to-drive SOURCE"
assert_contains "$REPO_ROOT/systemd/user/rclone-sync-drive-to-mega.env" \
    "DEST_PATH=Mega:" "env sync drive-to-mega DEST"

printf '\n-- struttura e riferimenti --\n'
assert_exists "$REPO_ROOT/legacy/crontab.txt" "esiste legacy/crontab.txt"
assert_exists "$REPO_ROOT/docs/all_service_plan.md" "esiste docs/all_service_plan.md"
assert_exists "$REPO_ROOT/tests/run_all.sh" "esiste tests/run_all.sh"
assert_absent "$REPO_ROOT/utility" "la vecchia directory utility/ è stata rimossa"
assert_absent "$REPO_ROOT/test" "la vecchia directory test/ è stata rimossa"

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
if grep -q 'legacy/crontab.txt' "$REPO_ROOT/setup.sh" "$REPO_ROOT/unsetup.sh"; then
    pass "setup/unsetup usano legacy/crontab.txt"
else
    fail "setup/unsetup usano legacy/crontab.txt"
fi
if grep -rq 'utility/' "$REPO_ROOT/setup.sh" "$REPO_ROOT/unsetup.sh"; then
    fail "nessun riferimento residuo a utility/ in setup/unsetup"
else
    pass "nessun riferimento residuo a utility/ in setup/unsetup"
fi

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
