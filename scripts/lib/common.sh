#!/bin/bash              
# =============================================================================
# common.sh — modulo condiviso da rclone_bisync.sh, rclone_sync.sh e watcher
# =============================================================================
# Questo file contiene tutte le responsabilità comuni ai due motori di
# sincronizzazione:
#   - logging e notifiche;
#   - validazione di argomenti e remote;
#   - calcolo dei percorsi di log/lock;
#   - preparazione delle directory e del file di log;
#   - safety check sui file aperti (lsof);
#   - lock flock;
#   - esecuzione di rclone e cattura dell'exit code;
#   - marker di blocco per gli errori critici.
#
# Non esegue `set -e`: la politica di uscita appartiene allo script chiamante.
# Non esegue operazioni di sincronizzazione: quelle restano negli entrypoint.
#
# -----------------------------------------------------------------------------
# CONFIGURAZIONE (override tramite variabili d'ambiente)
# -----------------------------------------------------------------------------
#   RCLONE_BIN            default /usr/bin/rclone
#   RCLONE_CONFIG_DIR     default /home/frankel/.config/rclone
#   RCLONE_EXCLUDE_FILE   default $RCLONE_CONFIG_DIR/exclude_patterns.txt
#   NOTIFY_BIN            default notify-send
#   NOTIFY_ENABLED        1 = invia notifiche, 0 = disabilita (test)
#   NOTIFY_TITLE          titolo delle notifiche (impostato dagli entrypoint)
#   NOTIFY_APP            nome applicazione (default "Rclone Script")
#   NOTIFY_MIN_LEVEL      livello minimo per una notifica (default WARN)
#   LOG_TAG               componente nella riga di log (BISYNC/SYNC/WATCH)
#   DEBUG_MODE            0 = log su file, 1 = output su stderr
#   LOCK_WAIT             secondi di attesa sul lock remoto (default 120)
#   LSOF_WAIT_SECONDS     secondi tra due controlli lsof (default 10)
#   LSOF_MAX_RETRIES      numero di tentativi lsof (default 18)
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
# La notifica desktop usa la stessa classificazione:
#
#   riepilogo  "$NOTIFY_TITLE [$LIVELLO]"
#   corpo      messaggio (l'ultimo errore rclone, se presente)
#   icona      dialog-information (DEBUG/INFO), dialog-warning (WARN),
#              dialog-error (ERROR/CRITICAL)
#   urgenza    low (DEBUG/INFO), normal (WARN/ERROR), critical (CRITICAL)
#
# Le notifiche sotto NOTIFY_MIN_LEVEL non vengono inviate.
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
#       Scrivono su stderr con il livello indicato. Quando lo script ha
#       rediretto stderr sul file di log, finiscono nel file (DEBUG solo con
#       DEBUG_MODE=1).
#
#   log_text <livello> <testo>
#       Come sopra, per testi multiriga (output di rclone, messaggi d'uso).
#
#   log_line <file> <msg>
#       Scrive un record INFO nel file indicato.
#
#   log_line_at <file> <livello> <msg>
#       Scrive un record del livello indicato nel file.
#
#   log_message <msg>   (compatibilità)
#       Alias di log_debug: scrive solo con DEBUG_MODE=1.
#
#   send_notification <msg> [livello]
#       Invia una notifica desktop con stile derivato dal livello
#       (default ERROR) e riepilogo "$NOTIFY_TITLE [$LIVELLO]".
#       Sotto NOTIFY_MIN_LEVEL non invia nulla.
#       Non fallisce mai (return 0 anche se notify-send manca).
#
#   level_value <livello>
#       Stampa il peso numerico del livello (DEBUG 10 … CRITICAL 50, 0 se
#       sconosciuto).
#
#   require_args <n_attuale> <n_atteso> <uso>
#       Esce con EXIT_ERROR se il numero di argomenti non corrisponde.
#
#   is_remote_path <path>
#       Ritorna 0 se il path contiene ':', 1 altrimenti.
#
#   remote_name_of <remote_path>
#       Stampa la parte prima dei ':'.
#
#   require_remote_path <path> <label> <uso>
#       Esce con EXIT_ERROR se il path non contiene ':'.
#
#   require_configured_remote <remote_name>
#       Esce con EXIT_ERROR se il remote non è in `rclone listremotes`.
#
#   conf_dir_for / log_dir_for / lock_dir_for / blocked_file_for <remote_name>
#       Stampa il percorso corrispondente.
#
#   init_rclone_paths <remote_name> <operation> <log_basename>
#       Imposta CONF_DIR, LOG_FILES_DIR, LOCK_FILES_DIR, LOCK_FILE_REMOTE,
#       LOCK_FILE_OPERATION, BLOCKED_FILE, LOG_FILE.
#
#   ensure_runtime_dirs
#       Crea LOG_FILES_DIR e LOCK_FILES_DIR; esce con EXIT_ERROR se fallisce.
#
#   ensure_log_file
#       Crea LOG_FILE se manca; esce con EXIT_ERROR se fallisce.
#
#   redirect_output_to_log
#       Con DEBUG_MODE=0 esegue `exec >> "$LOG_FILE" 2>&1`.
#
#   require_local_dir <path>
#       Esce con EXIT_ERROR se la directory non esiste.
#
#   ensure_local_check_file <path>
#       Crea <path>/RCLONE_TEST; esce con EXIT_ERROR se fallisce.
#
#   wait_for_no_open_files <path> <poll_seconds> <max_wait_seconds> [log_file]
#       Attende finché `lsof +D <path>` non trova file aperti.
#       Ritorna 0 quando la directory è libera, 1 allo scadere di max_wait.
#       Con max_wait=0 fa un solo controllo.
#
#   remote_is_reachable <remote_name>
#       Ritorna 0 se `rclone about <remote_name>:` riesce.
#
#   remote_has_check_file <remote_path>
#       Ritorna 0 se RCLONE_TEST è presente alla radice del remote.
#
#   ensure_remote_check_file <remote_path>
#       Crea RCLONE_TEST se manca; esce con EXIT_ERROR se non può crearlo.
#
#   check_local_write <path>
#       Verifica la scrittura con un file temporaneo; esce con EXIT_ERROR.
#
#   check_disk_space <path> [min_mb]
#       Esce con EXIT_ERROR se lo spazio libero è inferiore a min_mb (1024).
#
#   run_rclone <comando...>
#       Esegue il comando, imposta RCLONE_OUTPUT e RCLONE_RC. Ritorna sempre 0.
#
#   is_critical_rc <rc>
#       Ritorna 0 se rc == 7.
#
#   mark_blocked <file> / clear_blocked <file> / is_blocked <file>
#       Gestiscono il marker degli errori critici.
#
#   acquire_remote_lock
#       `flock -w $LOCK_WAIT 201`; richiede che FD 201 sia già aperto.
#
#   acquire_operation_lock
#       `flock -n 200`; richiede che FD 200 sia già aperto.
# =============================================================================

# Pulisce l'ambiente da librerie potenzialmente "inquinanti" (es. AppImage).
unset LD_LIBRARY_PATH

# --- Configurazione ---
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
RCLONE_CONFIG_DIR="${RCLONE_CONFIG_DIR:-/home/frankel/.config/rclone}"
RCLONE_EXCLUDE_FILE="${RCLONE_EXCLUDE_FILE:-${RCLONE_CONFIG_DIR}/exclude_patterns.txt}"
NOTIFY_BIN="${NOTIFY_BIN:-notify-send}"
NOTIFY_ENABLED="${NOTIFY_ENABLED:-1}"
NOTIFY_TITLE="${NOTIFY_TITLE:-Rclone}"
NOTIFY_APP="${NOTIFY_APP:-Rclone Script}"
NOTIFY_MIN_LEVEL="${NOTIFY_MIN_LEVEL:-WARN}"
LOG_TAG="${LOG_TAG:-RCLONE}"
DEBUG_MODE="${DEBUG_MODE:-0}"
LOCK_WAIT="${LOCK_WAIT:-120}"
LSOF_WAIT_SECONDS="${LSOF_WAIT_SECONDS:-10}"
LSOF_MAX_RETRIES="${LSOF_MAX_RETRIES:-18}"

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
    LOCK_FILE_REMOTE="${LOCK_FILES_DIR}/remote-${remote}.lock"
    LOCK_FILE_OPERATION="${LOCK_FILES_DIR}/${operation}-${remote}.lock"
    BLOCKED_FILE="$(blocked_file_for "$remote")"
    LOG_FILE="${LOG_FILES_DIR}/${log_basename}"
}

ensure_runtime_dirs() {
    if ! mkdir -p "$LOG_FILES_DIR" "$LOCK_FILES_DIR"; then
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

    # Nota: ';' e non '&&'. lsof può restituire un exit code non-zero anche
    # quando stampa file aperti, quindi il test su $out va sempre eseguito.
    while out=$(lsof +D "$path" 2>/dev/null); [ -n "$out" ]; do
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
            log_debug "$(printf '%s\n' "$out" | awk 'NR>1 {print "- " $9}')"
        fi

        sleep "$poll"
    done

    return 0
}

# --- Remote ---

remote_is_reachable() {
    "$RCLONE_BIN" about "${1}:" &>/dev/null
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

check_local_write() {
    if ! touch "${1}/RCLONE_TEST_WRITE" 2>/dev/null; then
        local msg="Impossibile scrivere nella cartella locale '$1'. Permessi negati."
        log_critical "$msg"
        send_notification "$msg" CRITICAL
        exit "$EXIT_ERROR"
    fi
    rm -f "${1}/RCLONE_TEST_WRITE" || true
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

# --- Marker di blocco ---

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

# --- Lock ---

acquire_remote_lock() {
    flock -w "$LOCK_WAIT" 201
}

acquire_operation_lock() {
    flock -n 200
}
