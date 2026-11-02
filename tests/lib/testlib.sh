#!/bin/bash
# Libreria comune per la suite di test.
# Non usa `set -e`: i test devono poter verificare exit code non-zero.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

TEST_NAME="${TEST_NAME:-$(basename "${0%.sh}")}"
TEST_TMP="${TEST_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/rclone-suite-${TEST_NAME}.XXXXXX")}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_NAMES=()
BG_PIDS=()

cleanup() {
    local pid
    if [ "${#BG_PIDS[@]}" -gt 0 ]; then
        for pid in "${BG_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        for pid in "${BG_PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    fi
    if [ "${KEEP_TMP:-0}" = "1" ]; then
        printf '  tmp mantenuta: %s\n' "$TEST_TMP"
    else
        rm -rf "$TEST_TMP"
    fi
}
trap cleanup EXIT INT TERM

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  ok    %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_NAMES+=("$1")
    printf '  FAIL  %s%s\n' "$1" "${2:+: $2}" >&2
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf '  skip  %s%s\n' "$1" "${2:+: $2}"
}

assert_eq() { # atteso, attuale, messaggio
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3" "atteso '$1', ottenuto '$2'"
    fi
}

assert_ne() { # non_atteso, attuale, messaggio
    if [ "$1" != "$2" ]; then
        pass "$3"
    else
        fail "$3" "valore inatteso '$2'"
    fi
}

assert_exists() { # percorso, messaggio
    if [ -e "$1" ]; then pass "$2"; else fail "$2" "$1 non esiste"; fi
}

assert_absent() { # percorso, messaggio
    if [ ! -e "$1" ]; then pass "$2"; else fail "$2" "$1 esiste"; fi
}

assert_executable() { # percorso, messaggio
    if [ -x "$1" ]; then pass "$2"; else fail "$2" "$1 non è eseguibile"; fi
}

assert_contains() { # file, pattern, messaggio
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        pass "$3"
    else
        fail "$3" "'$2' non trovato in $1"
    fi
}

assert_not_contains() { # file, pattern, messaggio
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        fail "$3" "'$2' trovato in $1"
    else
        pass "$3"
    fi
}

count_lines() { # file
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d ' '
    else
        echo 0
    fi
}

wait_until() { # comando, timeout_sec, messaggio
    local cmd="$1"
    local timeout="$2"
    local msg="$3"
    local i=0

    while [ "$i" -lt "$timeout" ]; do
        if eval "$cmd"; then
            pass "$msg"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    fail "$msg" "timeout dopo ${timeout}s"
    return 1
}

# Crea un albero di test con stub di rclone, copie derivate degli script,
# stub del bisync per il watcher e directory di log/lock.
setup_bisync_fixture() {
    mkdir -p "$TEST_TMP/bin" "$TEST_TMP/src" "$TEST_TMP/logs" \
             "$TEST_TMP/conf/conf_dir_tst/log_files" \
             "$TEST_TMP/conf/conf_dir_tst/lock_files"

    cat > "$TEST_TMP/bin/rclone" <<'EOS'
#!/bin/bash
case "$1" in
  listremotes) printf 'tst:\n'; exit 0 ;;
  about) exit "${STUB_ABOUT_RC:-0}" ;;
  lsf) exit 0 ;;
  touch) exit 0 ;;
  bisync)
      n=$(cat "${COUNT_FILE:-/dev/null}" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > "${COUNT_FILE:-/dev/null}"
      if [ "${STUB_FAIL_ALWAYS:-0}" != "0" ]; then exit "$STUB_FAIL_ALWAYS"; fi
      if [ "${STUB_FAIL_FIRST:-0}" = "1" ] && [ "$n" -eq 1 ]; then exit 7; fi
      sleep "${STUB_SLEEP:-0}"
      exit 0
      ;;
  *) exit 0 ;;
esac
EOS
    chmod +x "$TEST_TMP/bin/rclone"

    sed -e "s|/usr/bin/rclone|$TEST_TMP/bin/rclone|g" \
        -e "s|/home/frankel/.config/rclone|$TEST_TMP/conf|g" \
        -e "s|notify-send|true|g" \
        "$REPO_ROOT/scripts/rclone_bisync.sh" > "$TEST_TMP/bisync.sh"
    chmod +x "$TEST_TMP/bisync.sh"

    sed -e "s|/home/frankel/.config/rclone|$TEST_TMP/conf|g" \
        -e "s|notify-send|true|g" \
        "$REPO_ROOT/scripts/rclone_watch_bisync.sh" > "$TEST_TMP/watch.sh"
    chmod +x "$TEST_TMP/watch.sh"

    cat > "$TEST_TMP/stub_bisync.sh" <<EOS
#!/bin/bash
echo "[\$(date +%s)] CALL \$*" >> "$TEST_TMP/logs/calls.log"
sleep "\${STUB_BISYNC_SLEEP:-0}"
exit "\${STUB_BISYNC_RC:-0}"
EOS
    chmod +x "$TEST_TMP/stub_bisync.sh"

    export COUNT_FILE="$TEST_TMP/logs/count"
}

summary() {
    printf '\n  %s: %d ok, %d fail, %d skip\n' \
        "$TEST_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf '  falliti: %s\n' "${FAILED_NAMES[*]}"
        return 1
    fi
    return 0
}

finish() {
    summary
    exit $?
}
