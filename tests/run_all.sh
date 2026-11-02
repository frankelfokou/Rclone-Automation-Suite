#!/bin/bash
#
# Esegue tutta la suite di test.
#
# Uso:
#   ./tests/run_all.sh              # tutti i test
#   ./tests/run_all.sh bisync       # solo i file il cui nome contiene "bisync"
#   ./tests/run_all.sh --keep       # mantiene le directory temporanee
#   KEEP_TMP=1 ./tests/run_all.sh   # equivalente a --keep

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERN=""
KEEP_TMP=0

for arg in "$@"; do
    case "$arg" in
        --keep)
            KEEP_TMP=1
            ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            PATTERN="$arg"
            ;;
    esac
done

export KEEP_TMP

total=0
passed=0
failed=0
failed_tests=()

for test_file in "$TESTS_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue

    test_name="$(basename "$test_file")"
    if [ -n "$PATTERN" ] && [[ "$test_name" != *"$PATTERN"* ]]; then
        continue
    fi

    total=$((total + 1))
    printf '\n=== %s ===\n' "$test_name"

    if bash "$test_file"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        failed_tests+=("$test_name")
    fi
done

printf '\n========================================\n'
printf 'Totale:   %d\n' "$total"
printf 'Passati:  %d\n' "$passed"
printf 'Falliti:  %d\n' "$failed"
if [ "$failed" -gt 0 ]; then
    printf 'Test falliti: %s\n' "${failed_tests[*]}"
    exit 1
fi

exit 0
