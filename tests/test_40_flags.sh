#!/bin/bash
# Test dei nuovi flag di conflitto su una coppia locale usa-e-getta:
#   --conflict-resolve newer
#   --resync-mode newer
# Non usa remote: non tocca Google Drive.
#
# Questo test va eseguito PRIMA di aggiungere i flag a RCLONE_CMD.

set -u
. "$(dirname "$0")/lib/testlib.sh"

echo "[$TEST_NAME]"

if ! command -v rclone >/dev/null 2>&1; then
    skip "rclone non disponibile"
    finish
fi

BASE="$TEST_TMP/flags"
LOG="$TEST_TMP/logs/flags.log"
mkdir -p "$BASE/p1" "$BASE/p2" "$TEST_TMP/logs"

RCLONE="$(command -v rclone)"

rclone_bisync() {
    "$RCLONE" bisync "$BASE/p1" "$BASE/p2" \
        --check-access --resilient --recover --max-lock 2m \
        --compare "${COMPARE:-modtime}" "$@" >> "$LOG" 2>&1
}

printf '\n-- baseline --\n'
# I marker devono essere identici anche nel mtime: con --compare modtime
# due RCLONE_TEST creati in momenti diversi farebbero fallire il resync.
: > "$BASE/p1/RCLONE_TEST"
: > "$BASE/p2/RCLONE_TEST"
touch -d '2026-01-01 00:00:00' "$BASE/p1/RCLONE_TEST" "$BASE/p2/RCLONE_TEST"
rclone_bisync --resync
assert_eq 0 "$?" "resync iniziale"

printf '\n-- conflitto: vince il più recente --\n'
printf 'P1\n' > "$BASE/p1/f.txt"
printf 'P2\n' > "$BASE/p2/f.txt"
touch -d '2026-01-01 10:00:00' "$BASE/p2/f.txt"
touch -d '2026-01-01 10:05:00' "$BASE/p1/f.txt"

rclone_bisync --conflict-resolve newer
assert_eq 0 "$?" "run con --conflict-resolve newer"
assert_eq "P1" "$(cat "$BASE/p1/f.txt")" "Path1 contiene la versione più recente"
assert_eq "P1" "$(cat "$BASE/p2/f.txt")" "Path2 contiene la versione più recente"
assert_exists "$BASE/p1/f.txt.conflict1" "Path1 conserva il perdente come .conflict1"
assert_exists "$BASE/p2/f.txt.conflict1" "Path2 conserva il perdente come .conflict1"
assert_eq "P2" "$(cat "$BASE/p1/f.txt.conflict1")" "il perdente è la versione P2"

printf '\n-- --resync-mode newer --\n'
printf 'P1\n' > "$BASE/p1/g.txt"
printf 'P2\n' > "$BASE/p2/g.txt"
touch -d '2026-01-01 11:00:00' "$BASE/p2/g.txt"
touch -d '2026-01-01 11:05:00' "$BASE/p1/g.txt"

rclone_bisync --resync-mode newer
assert_eq 0 "$?" "run con --resync-mode newer"
assert_eq "P1" "$(cat "$BASE/p1/g.txt")" "resync: Path1 contiene la versione più recente"
assert_eq "P1" "$(cat "$BASE/p2/g.txt")" "resync: Path2 contiene la versione più recente"

printf '\n-- fallback: mtime uguali, dimensioni diverse --\n'
# Con --compare modtime due file con lo stesso mtime sono considerati identici,
# quindi il conflitto non viene rilevato. Per esercitare il fallback di
# --conflict-resolve newer serve confrontare anche la dimensione.
COMPARE="size,modtime" rclone_bisync --resync
assert_eq 0 "$?" "resync con --compare size,modtime"

printf 'AAA\n' > "$BASE/p1/h.txt"
printf 'B\n' > "$BASE/p2/h.txt"
touch -d '2026-01-01 12:00:00' "$BASE/p1/h.txt"
touch -d '2026-01-01 12:00:00' "$BASE/p2/h.txt"

COMPARE="size,modtime" rclone_bisync --conflict-resolve newer
assert_eq 0 "$?" "run con mtime uguali e dimensioni diverse"
assert_exists "$BASE/p1/h.txt.conflict1" "mtime uguali: fallback con .conflict1"
assert_exists "$BASE/p1/h.txt.conflict2" "mtime uguali: fallback con .conflict2"

finish
