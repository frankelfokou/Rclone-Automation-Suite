#!/bin/bash
# =============================================================================
# common.sh — modulo condiviso da rclone_bisync.sh, rclone_sync.sh e watcher
# =============================================================================
# Responsabilità comuni ai motori di sincronizzazione:
#   - logging e notifiche (con deduplicazione degli eventi);
#   - validazione di argomenti e remote;
#   - calcolo dei percorsi di log/lock/stato;
#   - safety check sui file aperti (lsof);
#   - lock flock;
#   - esecuzione di rclone e cattura dell'exit code;
#   - classificazione degli errori e analisi del danno;
#   - guard sugli invarianti delle coppie (Pro = solo vault);
#   - quarantena dei file rimossi;
#   - marker di blocco con cooldown (nessun blocco permanente).
#
# Non esegue `set -e`: la politica di uscita appartiene allo script chiamante.
# Non esegue operazioni di sincronizzazione: quelle restano negli entrypoint.
#
# -----------------------------------------------------------------------------
# CONFIGURAZIONE (override tramite variabili d'ambiente)
# -----------------------------------------------------------------------------
#   RCLONE_BIN              default /usr/bin/rclone
#   RCLONE_CONFIG_DIR       default /home/frankel/.config/rclone
#   RCLONE_EXCLUDE_FILE     default $RCLONE_CONFIG_DIR/exclude_patterns.txt
#   RCLONE_EXCLUDE_EXTRA    file di esclusione aggiuntivo (per istanza)
#   NOTIFY_BIN              default notify-send
#   NOTIFY_ENABLED          1 = invia notifiche, 0 = disabilita (test)
#   NOTIFY_TITLE            titolo delle notifiche (impostato dagli entrypoint)
#   NOTIFY_APP              nome applicazione (default "Rclone Script")
#   NOTIFY_MIN_LEVEL        livello minimo per una notifica (default WARN)
#   LOG_TAG                 componente nella riga di log (BISYNC/SYNC/WATCH)
#   DEBUG_MODE              0 = log su file, 1 = output su stderr
#   LOG_FULL_ON_SUCCESS     1 = scrive tutto l'output rclone anche sui successi
#   LOCK_WAIT               secondi di attesa sul lock remoto (default 120)
#   LSOF_WAIT_SECONDS       secondi tra due controlli lsof (default 10)
#   LSOF_MAX_RETRIES        numero di tentativi lsof (default 18)
#   QUARANTINE_ROOT         default ~/.local/share/rclone-quarantine
#   QUARANTINE_DAYS         giorni di conservazione in quarantena (default 7)
#
# -----------------------------------------------------------------------------
# FORMATO DI LOG E NOTIFICHE
# -----------------------------------------------------------------------------
# Ogni record di log è una sola riga:
#
#   [YYYY-MM-DD HH:MM:SS] [LIVELLO] [TAG] messaggio
#
#   LIVELLO  DEBUG | INFO | WARN | ERROR | CRITICAL
#   TAG      componente che scrive (LOG_TAG)
#
# I messaggi su più righe producono un record per riga, con lo stesso
# timestamp e la stessa intestazione: una riga = un evento.
# I record DEBUG vengono emessi solo con DEBUG_MODE=1.
#
# Le notifiche desktop usano la stessa classificazione:
#
#   riepilogo  "$NOTIFY_TITLE [$LIVELLO]"
#   corpo      messaggio (l'ultimo errore rclone, se presente)
#   icona      dialog-information (DEBUG/INFO), dialog-warning (WARN),
#              dialog-error (ERROR/CRITICAL)
#   urgenza    low (DEBUG/INFO), normal (WARN/ERROR), critical (CRITICAL)
#
# Le notifiche sotto NOTIFY_MIN_LEVEL non vengono inviate. La funzione
# notify_event aggiunge la deduplicazione: lo stesso evento non viene
# notificato due volte finché non cambia stato.
#
# -----------------------------------------------------------------------------
# EXIT CODE
# -----------------------------------------------------------------------------
#   EXIT_OK        = 0   successo
#   EXIT_ERROR     = 1   errore d'uso o errore definitivo
#   EXIT_CRITICAL  = 7   errore critico bisync (richiede --resync)
#   EXIT_TEMPFAIL  = 75  rinvio: file aperti, lock occupato, rete assente
#
# -----------------------------------------------------------------------------
# CONTRATTO DELLE FUNZIONI
# -----------------------------------------------------------------------------
#   log_emit <stderr|file> <livello> <messaggio>
#       Scrittore unico: applica il formato standard a ogni riga del messaggio.
#
#   log_debug / log_info / log_warn / log_error / log_critical <msg>
#       Scrivono su stderr con il livello indicato.
#
#   log_text <livello> <testo>
#       Come sopra, per testi multiriga (output di rclone, messaggi d'uso).
#
#   log_line <file> <msg> / log_line_at <file> <livello> <msg>
#       Scrivono un record nel file indicato.
#
#   log_summary <output rclone>
#       Estrae le righe di riepilogo (Transferred, Checks, Deleted, Errors,
#       Elapsed time) e le scrive come record INFO.
#
#   log_message <msg>   (compatibilità)
#       Alias di log_debug.
#
#   send_notification <msg> [livello]
#       Invia una notifica desktop. Non fallisce mai.
#
#   notify_event <key> <livello> <msg>
#       Notifica solo se il messaggio è diverso dall'ultimo inviato per <key>.
#
#   notify_clear <key>
#       Dimentica lo stato di <key>: la prossima occorrenza viene notificata.
#
#   level_value <livello>
#       Peso numerico del livello (DEBUG 10 … CRITICAL 50, 0 se sconosciuto).
#
#   require_args / is_remote_path / remote_name_of / require_remote_path /
#   require_configured_remote
#       Validazione di argomenti e remote.
#
#   conf_dir_for / log_dir_for / lock_dir_for / state_dir_for /
#   blocked_file_for <remote_name>
#       Stampa il percorso corrispondente.
#
#   init_rclone_paths <remote_name> <operation> <log_basename>
#       Imposta CONF_DIR, LOG_FILES_DIR, LOCK_FILES_DIR, STATE_DIR,
#       LOCK_FILE_REMOTE, LOCK_FILE_OPERATION, BLOCKED_FILE, LOG_FILE.
#
#   ensure_runtime_dirs / ensure_log_file / redirect_output_to_log
#       Preparano directory e file di log.
#
#   require_local_dir / ensure_local_check_file / check_local_write /
#   check_disk_space
#       Controlli locali. check_local_write non scrive mai nell'albero
#       sincronizzato (evita di auto-innescare il watcher).
#
#   wait_for_no_open_files <path> <poll> <max> [log]
#       Attende che non ci siano FILE REGOLARI aperti (gli handle su
#       directory, tipici delle app Electron, non bloccano).
#
#   remote_is_reachable / remote_has_check_file / ensure_remote_check_file
#       Controlli sul remote.
#
#   run_rclone <comando...>
#       Esegue il comando, imposta RCLONE_OUTPUT e RCLONE_RC. Ritorna sempre 0.
#
#   is_critical_rc <rc>
#       Ritorna 0 se rc == 7.
#
#   is_network_error / is_auth_error / is_rate_limit_error /
#   is_retryable_without_resync / is_too_many_deletes <output>
#       Riconoscono le firme note di rclone.
#
#   classify_bisync_failure <rc> <output>
#       Stampa: too_many_deletes | retryable | auth | rate_limit | network |
#               critical | other.
#
#   rclone_size_count <path> [extra...]
#       Numero di oggetti (rclone size --json).
#
#   bisync_prev_counts <remote_name>
#       Stampa "path1 path2" contando i listing precedenti di bisync.
#
#   bisync_damage_analysis <local> <remote> <remote_name>
#       Stampa: remote_damaged | local_shrunk | both_shrunk | unknown.
#
#   state_get / state_set / state_del <key> [valore]
#       Stato persistente in STATE_DIR.
#
#   record_success / record_failure / failure_streak
#       Aggiornano last_success e il contatore di fallimenti consecutivi.
#
#   blocked_set <file> <motivo> <tentativo> / blocked_is_due <file> /
#   blocked_attempts <file> / mark_blocked / clear_blocked / is_blocked
#       Marker di blocco con cooldown (15m, 1h, 6h, 24h).
#
#   filters_signature <file...>
#       Hash dei file di esclusione: usato per forzare un --resync quando
#       cambiano i filtri (bisync non ne calcola l'hash).
#
#   guard_enforce <local_path> <remote_path>
#       Applica gli invarianti guidati da (liste separate da '|'):
#         GUARD_ALLOWED_TOP_LEVEL    voci ammesse nella radice (modalità strict)
#         GUARD_PURGE_TOP_LEVEL      voci da eliminare (quarantena + purge)
#         GUARD_FORBIDDEN_TOP_LEVEL  voci vietate (quarantena + purge)
#         GUARD_MIGRATE_TARGET       destinazione della migrazione
#       Imposta GUARD_CHANGED=1 se ha modificato qualcosa e GUARD_SUMMARY.
#
#   guard_quarantine_move <path> / guard_quarantine_prune
#       Sposta in quarantena e ripulisce le voci più vecchie di QUARANTINE_DAYS.
#
#   acquire_remote_lock / acquire_operation_lock
#       `flock -w $LOCK_WAIT 201` e `flock -n 200`.
# =============================================================================

# Pulisce l'ambiente da librerie potenzialmente "inquinanti" (es. AppImage).
unset LD_LIBRARY_PATH

# --- Configurazione ---
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
RCLONE_CONFIG_DIR="${RCLONE_CONFIG_DIR:-/home/frankel/.config/rclone}"
RCLONE_EXCLUDE_FILE="${RCLONE_EXCLUDE_FILE:-${RCLONE_CONFIG_DIR}/exclude_patterns.txt}"
RCLONE_EXCLUDE_EXTRA="${RCLONE_EXCLUDE_EXTRA:-}"
NOTIFY_BIN="${NOTIFY_BIN:-notify-send}"
NOTIFY_ENABLED="${NOTIFY_ENABLED:-1}"
NOTIFY_TITLE="${NOTIFY_TITLE:-Rclone}"
NOTIFY_APP="${NOTIFY_APP:-Rclone Script}"
NOTIFY_MIN_LEVEL="${NOTIFY_MIN_LEVEL:-WARN}"
LOG_TAG="${LOG_TAG:-RCLONE}"
DEBUG_MODE="${DEBUG_MODE:-0}"
LOG_FULL_ON_SUCCESS="${LOG_FULL_ON_SUCCESS:-0}"
LOCK_WAIT="${LOCK_WAIT:-120}"
LSOF_WAIT_SECONDS="${LSOF_WAIT_SECONDS:-10}"
LSOF_MAX_RETRIES="${LSOF_MAX_RETRIES:-18}"
QUARANTINE_ROOT="${QUARANTINE_ROOT:-${HOME}/.local/share/rclone-quarantine}"
QUARANTINE_DAYS="${QUARANTINE_DAYS:-7}"
BISYNC_CACHE_DIR="${BISYNC_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/rclone/bisync}"

# --- Exit code ---
EXIT_OK=0
EXIT_ERROR=1
EXIT_CRITICAL=7
EXIT_TEMPFAIL=75

# --- Livelli ---

level_value() { # livello -> peso numerico (0 se sconosciuto)
    case "${1^^}" in
        DEBUG)    printf '10\n' ;;
        INFO)     printf '20\n' ;;
        WARN)     printf '30\n' ;;
        ERROR)    printf '40\n' ;;
        CRITICAL) printf '50\n' ;;
        *)        printf '0\n' ;;
    esac
}

# --- Logging ---

log_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

strip_ansi() { # rimuove le sequenze ANSI (rclone colora l'output)
    sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

log_emit() { # destinazione (stderr|percorso file), livello, messaggio
    local dest="$1"
    local level="${2^^}"
    local message="$3"
    local ts line

    [ -n "$message" ] || return 0
    if [ "$level" = "DEBUG" ] && [ "$DEBUG_MODE" -ne 1 ]; then
        return 0
    fi

    ts="$(log_timestamp)"
    while IFS= read -r line; do
        if [ "$dest" = "stderr" ]; then
            printf '[%s] [%s] [%s] %s\n' "$ts" "$level" "$LOG_TAG" "$line" >&2
        else
            printf '[%s] [%s] [%s] %s\n' "$ts" "$level" "$LOG_TAG" "$line" \
                >> "$dest" 2>/dev/null || true
        fi
    done <<< "$message"

    return 0
}

log_debug()    { log_emit stderr DEBUG "$*"; }
log_info()     { log_emit stderr INFO "$*"; }
log_warn()     { log_emit stderr WARN "$*"; }
log_error()    { log_emit stderr ERROR "$*"; }
log_critical() { log_emit stderr CRITICAL "$*"; }

log_text() { # livello, testo (anche multiriga)
    local level="$1"
    shift
    log_emit stderr "$level" "$*"
}

log_line() { # file, messaggio
    local file="$1"
    shift
    log_emit "$file" INFO "$*"
}

log_line_at() { # file, livello, messaggio
    local file="$1"
    local level="$2"
    shift 2
    log_emit "$file" "$level" "$*"
}

log_message() { # compatibilità: solo con DEBUG_MODE=1
    log_debug "$*"
}

# Riepilogo compatto dell'output di rclone: una riga per metrica, senza
# l'intero listing (che sui successi occupa migliaia di righe).
# Ogni estrazione termina con `|| true`: con `set -e -o pipefail` un grep
# senza corrispondenze farebbe uscire il run come se fosse fallito.
log_summary() { # output rclone
    local out key line
    out="$(printf '%s\n' "$1" | strip_ansi 2>/dev/null || true)"
    for key in "Transferred:" "Checks:" "Deleted:" "Errors:" "Elapsed time:"; do
        line="$(printf '%s\n' "$out" | grep -F "$key" 2>/dev/null | tail -n 1 || true)"
        [ -n "$line" ] && log_info "$(printf '%s' "$line" | sed -E 's/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9:]+ +[A-Z]+ +: +//')"
    done
    return 0
}

# --- Notifiche ---

notify_icon_for() {
    case "${1^^}" in
        DEBUG|INFO) printf 'dialog-information\n' ;;
        WARN)       printf 'dialog-warning\n' ;;
        *)          printf 'dialog-error\n' ;;
    esac
}

notify_urgency_for() {
    case "${1^^}" in
        DEBUG|INFO) printf 'low\n' ;;
        WARN|ERROR) printf 'normal\n' ;;
        *)          printf 'critical\n' ;;
    esac
}

send_notification() { # messaggio, [livello=ERROR]
    local message="$1"
    local level="${2:-ERROR}"
    local icon urgency

    [ "$NOTIFY_ENABLED" = "1" ] || return 0
    [ -n "$message" ] || return 0
    [ "$(level_value "$level")" -ge "$(level_value "$NOTIFY_MIN_LEVEL")" ] || return 0

    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi

    icon="$(notify_icon_for "$level")"
    urgency="$(notify_urgency_for "$level")"

    "$NOTIFY_BIN" -u "$urgency" \
                  -i "$icon" \
                  -a "$NOTIFY_APP" \
                  "${NOTIFY_TITLE} [${level^^}]" \
                  "$message" || true

    return 0
}

notify_event() { # chiave, livello, messaggio
    local key="$1"
    local level="$2"
    local message="$3"
    local hash previous

    [ -n "$key" ] || { send_notification "$message" "$level"; return 0; }
    hash="$(printf '%s' "$message" | sha256sum | cut -d' ' -f1)"
    previous="$(state_get "notify_${key}")"
    [ "$previous" = "$hash" ] && return 0

    state_set "notify_${key}" "$hash"
    send_notification "$message" "$level"
}

notify_clear() { # chiave
    state_del "notify_${1}"
}

# --- Validazione ---

require_args() { # n_attuale, n_atteso, uso
    if [ "$1" -ne "$2" ]; then
        local msg="Numero di argomenti non corretto: attesi $2, ricevuti $1."
        log_error "$msg"
        if [ -n "$3" ]; then
            log_error "$3"
        fi
        send_notification "$msg
$3" ERROR
        exit "$EXIT_ERROR"
    fi
}

is_remote_path() {
    [[ "$1" == *:* ]]
}

remote_name_of() {
    printf '%s\n' "${1%%:*}"
}

require_remote_path() { # path, label, uso
    if ! is_remote_path "$1"; then
        local msg="Il percorso remoto '$1' non è valido (manca ':')."
        log_error "$msg"
        if [ -n "$3" ]; then
            log_error "$3"
        fi
        send_notification "$msg
$3" ERROR
        exit "$EXIT_ERROR"
    fi
}

require_configured_remote() { # remote_name
    if ! "$RCLONE_BIN" listremotes | grep -q "^${1}:"; then
        local msg="Il remote '$1' non è configurato in rclone."
        log_error "$msg"
        send_notification "$msg" ERROR
        exit "$EXIT_ERROR"
    fi
}

# --- Percorsi ---

conf_dir_for() {
    printf '%s/conf_dir_%s' "$RCLONE_CONFIG_DIR" "$1"
}

log_dir_for() {
    printf '%s/log_files' "$(conf_dir_for "$1")"
}

lock_dir_for() {
    printf '%s/lock_files' "$(conf_dir_for "$1")"
}

state_dir_for() {
    printf '%s/state' "$(conf_dir_for "$1")"
}

blocked_file_for() {
    printf '%s/bisync-%s.blocked' "$(lock_dir_for "$1")" "$1"
}

init_rclone_paths() { # remote_name, operation, log_basename
    local remote="$1"
    local operation="$2"
    local log_basename="$3"

    CONF_DIR="$(conf_dir_for "$remote")"
    LOG_FILES_DIR="$(log_dir_for "$remote")"
    LOCK_FILES_DIR="$(lock_dir_for "$remote")"
    STATE_DIR="$(state_dir_for "$remote")"
    LOCK_FILE_REMOTE="${LOCK_FILES_DIR}/remote-${remote}.lock"
    LOCK_FILE_OPERATION="${LOCK_FILES_DIR}/${operation}-${remote}.lock"
    BLOCKED_FILE="$(blocked_file_for "$remote")"
    LOG_FILE="${LOG_FILES_DIR}/${log_basename}"
}

ensure_runtime_dirs() {
    if ! mkdir -p "$LOG_FILES_DIR" "$LOCK_FILES_DIR" "$STATE_DIR"; then
        local msg="Impossibile creare le directory in '$CONF_DIR'. Controllare i permessi."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi
}

ensure_log_file() {
    if [ ! -f "$LOG_FILE" ] && ! touch "$LOG_FILE"; then
        local msg="Impossibile creare il file di log '$LOG_FILE'. Controllare i permessi."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi
}

redirect_output_to_log() {
    if [ "$DEBUG_MODE" -eq 0 ]; then
        exec >> "$LOG_FILE" 2>&1
    fi
}

# --- Stato persistente ---

state_get() { # chiave
    local file="${STATE_DIR}/${1}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

state_set() { # chiave, valore
    [ -n "${STATE_DIR:-}" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s\n' "$2" > "${STATE_DIR}/${1}" 2>/dev/null || true
}

state_del() { # chiave
    [ -n "${STATE_DIR:-}" ] || return 0
    rm -f "${STATE_DIR}/${1}" 2>/dev/null || true
}

record_success() {
    state_set last_success "$(date +%s)"
    state_set streak "0"
}

record_failure() { # stampa il nuovo conteggio
    local streak
    streak="$(state_get streak)"
    streak="${streak:-0}"
    streak=$((streak + 1))
    state_set streak "$streak"
    printf '%s\n' "$streak"
}

failure_streak() {
    local streak
    streak="$(state_get streak)"
    printf '%s\n' "${streak:-0}"
}

last_success_epoch() {
    local value
    value="$(state_get last_success)"
    printf '%s\n' "${value:-0}"
}

# --- Directory e marker locali ---

require_local_dir() {
    if [ ! -d "$1" ]; then
        local msg="La directory locale '$1' non esiste."
        log_error "$msg"
        send_notification "$msg" ERROR
        exit "$EXIT_ERROR"
    fi
}

ensure_local_check_file() {
    if [ ! -f "$1/RCLONE_TEST" ] && ! touch "$1/RCLONE_TEST"; then
        local msg="Impossibile creare '$1/RCLONE_TEST'. Controllare i permessi."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi
}

# --- Safety check file aperti ---

wait_for_no_open_files() { # path, poll_seconds, max_wait_seconds, [log_file]
    local path="$1"
    local poll="$2"
    local max_wait="$3"
    local log_file="${4:-}"
    local start=$SECONDS
    local out

    command -v lsof >/dev/null 2>&1 || return 0

    # Solo i file regolari bloccano la sync. Gli handle su directory
    # (Electron/Obsidian, IDE, file manager) non indicano una scrittura in
    # corso e bloccherebbero il gate per sempre.
    while out=$(lsof +D "$path" -Fftn 2>/dev/null | awk '
            /^t/ { type = substr($0, 2) }
            /^n/ { if (type == "REG") print substr($0, 2) }
        '); [ -n "$out" ]; do
        if [ $((SECONDS - start)) -ge "$max_wait" ]; then
            if [ -n "$log_file" ]; then
                log_line_at "$log_file" WARN \
                    "File aperti dopo ${max_wait}s: rinvio (exit 75)."
            else
                log_warn "File aperti dopo ${max_wait}s: rinvio (exit 75)."
            fi
            return 1
        fi

        if [ -n "$log_file" ]; then
            log_line_at "$log_file" INFO "File aperti: attendo ${poll}s."
        else
            log_debug "File in uso rilevati. Attesa di ${poll}s. File aperti:"
            log_debug "$(printf '%s\n' "$out" | sed 's/^/- /')"
        fi

        sleep "$poll"
    done

    return 0
}

# --- Remote ---

remote_is_reachable() {
    "$RCLONE_BIN" about "${1}:" \
        --timeout 15s --contimeout 10s --retries 1 &>/dev/null
}

remote_has_check_file() { # remote_path
    local listing
    listing="$("$RCLONE_BIN" lsf "$1" 2>/dev/null || true)"
    printf '%s\n' "$listing" | grep -qx 'RCLONE_TEST'
}

ensure_remote_check_file() { # remote_path
    if ! remote_has_check_file "$1"; then
        if ! "$RCLONE_BIN" touch "$1/RCLONE_TEST"; then
            local msg="Impossibile creare 'RCLONE_TEST' sul remote '$1'. Controllare i permessi del remote."
            log_critical "$msg"
            send_notification "$msg" CRITICAL
            exit "$EXIT_ERROR"
        fi
    fi
}

# --- Controlli locali ---

# Verifica la scrittura senza creare file nell'albero sincronizzato: un file
# di prova dentro LOCAL_PATH genererebbe un evento inotify che rilancia il
# watcher a ogni fallimento (loop auto-alimentato).
check_local_write() {
    local dir="$1"
    local probe

    if [ ! -w "$dir" ]; then
        local msg="Impossibile scrivere nella cartella locale '$dir'. Permessi negati."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi

    probe="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/rclone-writecheck.XXXXXX" 2>/dev/null)" || {
        local msg="Impossibile creare un file di prova per verificare la scrittura."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    }
    rm -rf "$probe" 2>/dev/null || true
}

check_disk_space() { # path, [min_mb]
    local path="$1"
    local min_mb="${2:-1024}"
    local available

    if ! df -BM "$path" | awk -v min="$min_mb" 'NR==2 {if ($4 < min) exit 1}'; then
        available=$(df -h "$path" | awk 'NR==2 {print $4}' || echo "N/A")
        local msg="Spazio libero insufficiente in '${path}' (disponibile: ${available}, richiesto: ${min_mb} MB)."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi
}

# --- Esecuzione rclone ---

run_rclone() {
    RCLONE_RC=0
    RCLONE_OUTPUT="$("$@" 2>&1)" || RCLONE_RC=$?
    return 0
}

is_critical_rc() {
    [ "$1" -eq "$EXIT_CRITICAL" ]
}

# --- Classificazione degli errori ---

is_network_error() {
    printf '%s' "$1" | grep -qiE \
        'dial tcp|no such host|network is unreachable|connection refused|connection reset|i/o timeout|tls handshake timeout|temporary failure in name resolution|context deadline exceeded|proxyconnect|unexpected EOF|: EOF'
}

is_auth_error() {
    printf '%s' "$1" | grep -qiE \
        '401|invalid authentication credentials|token has been expired|invalid_grant|oauth2: cannot fetch token'
}

is_rate_limit_error() {
    printf '%s' "$1" | grep -qiE \
        'rate limit|quota|userRateLimitExceeded|too many requests|429'
}

is_retryable_without_resync() {
    printf '%s' "$1" | grep -qi 'retryable without --resync'
}

is_too_many_deletes() {
    printf '%s' "$1" | grep -qi 'too many deletes'
}

classify_bisync_failure() { # rc, output
    local rc="$1"
    local out="$2"

    if is_too_many_deletes "$out"; then
        printf 'too_many_deletes\n'
        return 0
    fi
    if is_retryable_without_resync "$out"; then
        printf 'retryable\n'
        return 0
    fi
    if is_auth_error "$out"; then
        printf 'auth\n'
        return 0
    fi
    if is_rate_limit_error "$out"; then
        printf 'rate_limit\n'
        return 0
    fi
    if is_network_error "$out"; then
        printf 'network\n'
        return 0
    fi
    if [ "$rc" -eq "$EXIT_CRITICAL" ]; then
        printf 'critical\n'
        return 0
    fi
    printf 'other\n'
}

# --- Analisi del danno ---

rclone_size_count() { # path [extra...]
    local path="$1"
    shift
    local json

    json="$("$RCLONE_BIN" size "$path" "$@" --json 2>/dev/null)" || return 1
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.count // empty'
    else
        printf '%s' "$json" | sed -n 's/.*"count":\([0-9][0-9]*\).*/\1/p'
    fi
}

# Conta gli oggetti nei listing precedenti di bisync: sono la fotografia
# dello stato buono, scritta da rclone stesso, senza chiamate API extra.
bisync_prev_counts() { # remote_name -> "path1 path2"
    local key="$1"
    local p1 p2

    [ -d "$BISYNC_CACHE_DIR" ] || return 1
    p1="$(ls -t "$BISYNC_CACHE_DIR"/*"$key"*.path1.lst 2>/dev/null | head -n 1)"
    p2="$(ls -t "$BISYNC_CACHE_DIR"/*"$key"*.path2.lst 2>/dev/null | head -n 1)"
    [ -n "$p1" ] && [ -n "$p2" ] || return 1

    printf '%s %s\n' \
        "$(( $(wc -l < "$p1") - 1 ))" \
        "$(( $(wc -l < "$p2") - 1 ))"
}

# Decide chi ha subito il danno confrontando i conteggi attuali con i
# listing precedenti. Soglia: calo > 30% su un lato e < 10% sull'altro.
bisync_damage_analysis() { # local_path remote_path remote_name
    local local_path="$1"
    local remote="$2"
    local remote_name="$3"
    local local_now remote_now local_prev remote_prev
    local extra=()

    [ -n "$RCLONE_EXCLUDE_FILE" ] && extra+=(--exclude-from "$RCLONE_EXCLUDE_FILE")
    [ -n "$RCLONE_EXCLUDE_EXTRA" ] && extra+=(--exclude-from "$RCLONE_EXCLUDE_EXTRA")

    local_now="$(rclone_size_count "$local_path" "${extra[@]}")" || { printf 'unknown\n'; return 0; }
    remote_now="$(rclone_size_count "$remote" "${extra[@]}")" || { printf 'unknown\n'; return 0; }

    if ! read -r local_prev remote_prev < <(bisync_prev_counts "$remote_name"); then
        printf 'unknown\n'
        return 0
    fi
    [ -n "$local_prev" ] && [ -n "$remote_prev" ] || { printf 'unknown\n'; return 0; }
    [ "$local_prev" -gt 0 ] && [ "$remote_prev" -gt 0 ] || { printf 'unknown\n'; return 0; }

    local local_ratio remote_ratio
    local_ratio=$(( local_now * 100 / local_prev ))
    remote_ratio=$(( remote_now * 100 / remote_prev ))

    log_debug "Analisi danno: locale ${local_now}/${local_prev} (${local_ratio}%), remoto ${remote_now}/${remote_prev} (${remote_ratio}%)."

    # Un albero locale vuoto non è mai una cancellazione volontaria.
    if [ "$local_now" -eq 0 ]; then
        printf 'unknown\n'
        return 0
    fi

    if [ "$remote_ratio" -le 70 ] && [ "$local_ratio" -ge 90 ]; then
        printf 'remote_damaged\n'
    elif [ "$local_ratio" -le 70 ] && [ "$remote_ratio" -ge 90 ]; then
        printf 'local_shrunk\n'
    elif [ "$local_ratio" -le 70 ] && [ "$remote_ratio" -le 70 ]; then
        printf 'both_shrunk\n'
    else
        printf 'unknown\n'
    fi
}

# --- Firma dei filtri ---

filters_signature() { # file...
    local file
    {
        for file in "$@"; do
            [ -n "$file" ] || continue
            printf '%s\n' "$file"
            # if/fi e non `[ ... ] &&`: con `set -e -o pipefail` un file
            # mancante farebbe fallire la pipeline e quindi l'intero script.
            if [ -f "$file" ]; then
                cat "$file" 2>/dev/null || true
            fi
        done
    } | sha256sum | cut -d' ' -f1
    return 0
}

# Valida i file di esclusione prima di costruire il comando: un percorso
# sbagliato deve produrre un errore parlante, non un'uscita silenziosa.
require_exclude_files() {
    if [ -n "$RCLONE_EXCLUDE_FILE" ] && [ ! -f "$RCLONE_EXCLUDE_FILE" ]; then
        local msg="File di esclusione mancante: '$RCLONE_EXCLUDE_FILE'. Reinstalla con sudo ./setup.sh."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi

    if [ -n "$RCLONE_EXCLUDE_EXTRA" ] && [ ! -f "$RCLONE_EXCLUDE_EXTRA" ]; then
        local msg="File di esclusione aggiuntivo mancante: '$RCLONE_EXCLUDE_EXTRA'."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi
}

# --- Marker di blocco con cooldown ---

blocked_set() { # file, motivo, tentativo
    local file="$1"
    local reason="$2"
    local attempt="${3:-1}"
    local delay retry

    case "$attempt" in
        1) delay=900 ;;      # 15 minuti
        2) delay=3600 ;;     # 1 ora
        3) delay=21600 ;;    # 6 ore
        *) delay=86400 ;;    # 24 ore
    esac

    retry=$(( $(date +%s) + delay ))
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf 'reason=%s\nretry_after=%s\nattempts=%s\n' \
        "$reason" "$retry" "$attempt" > "$file" 2>/dev/null || true
}

blocked_field() { # file, chiave
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

blocked_attempts() { # file
    local value
    value="$(blocked_field "$1" attempts)"
    printf '%s\n' "${value:-0}"
}

blocked_is_due() { # file -> 0 se si può ritentare
    local retry
    [ -f "$1" ] || return 0
    retry="$(blocked_field "$1" retry_after)"
    [ -z "$retry" ] && return 0      # marker legacy o vuoto: tenta
    [ "$(date +%s)" -ge "$retry" ]
}

mark_blocked() {
    mkdir -p "$(dirname "$1")" 2>/dev/null || true
    : > "$1"
}

clear_blocked() {
    rm -f "$1"
}

is_blocked() {
    [ -f "$1" ]
}

# --- Quarantena ---

guard_quarantine_move() { # path
    local path="$1"
    local dest

    [ -e "$path" ] || return 0
    dest="${QUARANTINE_ROOT}/$(date +%Y%m%d-%H%M%S)-$$"
    if ! mkdir -p "$dest"; then
        log_error "Impossibile creare la quarantena '$dest'."
        return 1
    fi
    if ! mv "$path" "$dest/"; then
        log_error "Impossibile spostare '$path' in quarantena."
        return 1
    fi
    log_warn "Quarantena: '$path' -> '$dest/'"
    return 0
}

guard_quarantine_prune() {
    [ -d "$QUARANTINE_ROOT" ] || return 0
    find "$QUARANTINE_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -mtime "+${QUARANTINE_DAYS}" -exec rm -rf {} + 2>/dev/null || true
}

# --- Guard sugli invarianti delle coppie ---

guard_top_level_local() { # path
    find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
        | grep -vx 'RCLONE_TEST' | grep -v '^$' | sort
    return 0
}

guard_top_level_remote() { # remote_path
    local out
    out="$("$RCLONE_BIN" lsf "$1" --max-depth 1 2>/dev/null)" || return 1
    printf '%s\n' "$out" | sed 's:/$::' \
        | grep -vx 'RCLONE_TEST' | grep -v '^$' | sort
    return 0
}

guard_in_list() { # voce, lista separata da '|'
    local needle="$1"
    local item
    local IFS='|'
    for item in $2; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

guard_verify_paths() { # src, dst
    local missing
    [ -d "$1" ] || return 0
    [ -d "$2" ] || return 1
    missing="$(comm -23 \
        <(cd "$1" && find . -type f -printf '%P\n' | sort) \
        <(cd "$2" && find . -type f -printf '%P\n' | sort))"
    [ -z "$missing" ]
}

guard_merge_into() { # src, dst
    local src="$1"
    local dst="$2"

    [ -d "$src" ] || return 0
    if [ -e "$dst" ] && [ ! -d "$dst" ]; then
        log_error "Conflitto: '$dst' esiste ed è un file, '$src' è una cartella."
        return 1
    fi
    mkdir -p "$dst" || return 1
    # cp -au: copia solo i file mancanti o più recenti (vince il più recente).
    cp -au "$src/." "$dst/" 2>/dev/null || return 1
    guard_verify_paths "$src" "$dst"
}

guard_purge_remote() { # remote_path, nome
    local base="${1%/}"
    "$RCLONE_BIN" purge "${base}/${2}" >/dev/null 2>&1
}

guard_remove_both() { # local_path, remote_path, nome, elenco_remoto
    local local_path="$1"
    local remote="$2"
    local name="$3"
    local remote_listing="$4"
    local local_entry="${local_path}/${name}"

    if [ -e "$local_entry" ]; then
        if guard_quarantine_move "$local_entry"; then
            GUARD_CHANGED=1
            GUARD_SUMMARY="${GUARD_SUMMARY}${name} (locale); "
        fi
    fi

    if printf '%s\n' "$remote_listing" | grep -qxF -- "$name"; then
        if guard_purge_remote "$remote" "$name"; then
            GUARD_CHANGED=1
            GUARD_SUMMARY="${GUARD_SUMMARY}${name} (remoto); "
        else
            log_warn "Guard: impossibile rimuovere '$name' dal remote."
        fi
    fi
    return 0
}

guard_migrate_both() { # local_path, remote_path, nome, elenco_remoto, target
    local local_path="$1"
    local remote="$2"
    local name="$3"
    local remote_listing="$4"
    local target="$5"
    local src="${local_path}/${name}"
    local dst="${target}/${name}"

    # 1. Contenuto presente solo sul remote: portato in F4Frank (più recente).
    if printf '%s\n' "$remote_listing" | grep -qxF -- "$name"; then
        mkdir -p "$dst" || return 1
        if ! "$RCLONE_BIN" copy "${remote%/}/${name}" "$dst" \
                --update --create-empty-src-dirs >/dev/null 2>&1; then
            log_error "Guard: migrazione remota fallita per '$name'."
            return 1
        fi
    fi

    # 2. Contenuto locale: merge con la destinazione, vince il più recente.
    if [ -d "$src" ]; then
        if ! guard_merge_into "$src" "$dst"; then
            log_error "Guard: migrazione locale incompleta per '$name', resta in $local_path."
            return 1
        fi
    elif [ -f "$src" ]; then
        mkdir -p "$target" || return 1
        if ! cp -au "$src" "$target/" 2>/dev/null; then
            log_error "Guard: impossibile copiare '$name' in '$target'."
            return 1
        fi
    fi

    # 3. Rimozione dalle due radici.
    guard_remove_both "$local_path" "$remote" "$name" "$remote_listing"
    GUARD_CHANGED=1
    GUARD_SUMMARY="${GUARD_SUMMARY}${name} -> ${target}; "
    return 0
}

# Applica gli invarianti dichiarati nell'ambiente dell'istanza.
guard_enforce() { # local_path, remote_path
    local local_path="$1"
    local remote="$2"
    local allowed="${GUARD_ALLOWED_TOP_LEVEL:-}"
    local purge="${GUARD_PURGE_TOP_LEVEL:-}"
    local forbidden="${GUARD_FORBIDDEN_TOP_LEVEL:-}"
    local target="${GUARD_MIGRATE_TARGET:-$(dirname "$local_path")/GDrive-F4Frank}"
    local remote_listing local_names name
    local -a names=()

    GUARD_CHANGED=0
    GUARD_SUMMARY=""
    [ -n "$allowed$purge$forbidden" ] || return 0

    local_names="$(guard_top_level_local "$local_path")"
    if ! remote_listing="$(guard_top_level_remote "$remote")"; then
        log_warn "Guard: elenco del remote non disponibile, controllo rinviato."
        return 0
    fi

    mapfile -t names < <(
        { printf '%s\n' "$local_names"; printf '%s\n' "$remote_listing"; } \
            | grep -v '^$' | sort -u
    )

    for name in "${names[@]}"; do
        guard_in_list "$name" "$allowed" && continue

        if [ "${DRY_RUN:-0}" -eq 1 ]; then
            if guard_in_list "$name" "$forbidden" || guard_in_list "$name" "$purge"; then
                log_warn "Guard (dry-run): '$name' verrebbe rimosso da '$local_path' e dal remote."
            elif [ -n "$allowed" ]; then
                log_warn "Guard (dry-run): '$name' verrebbe migrato in '$target'."
            fi
            continue
        fi

        if guard_in_list "$name" "$forbidden" || guard_in_list "$name" "$purge"; then
            log_warn "Guard: '$name' non ammesso in '$local_path': rimozione."
            guard_remove_both "$local_path" "$remote" "$name" "$remote_listing"
            continue
        fi

        # Modalità strict: solo le voci ammesse restano, le altre migrano.
        if [ -n "$allowed" ]; then
            log_warn "Guard: '$name' non appartiene a '$local_path': migrazione in '$target'."
            guard_migrate_both "$local_path" "$remote" "$name" "$remote_listing" "$target" \
                || log_error "Guard: '$name' lasciato in '$local_path' (migrazione fallita)."
        fi
    done

    if [ "$GUARD_CHANGED" -eq 1 ]; then
        log_warn "Guard: modifiche applicate: ${GUARD_SUMMARY}"
    fi
    return 0
}

# --- Lock ---

acquire_remote_lock() {
    flock -w "$LOCK_WAIT" 201
}

acquire_operation_lock() {
    flock -n 200
}
