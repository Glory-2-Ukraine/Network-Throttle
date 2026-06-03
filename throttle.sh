#!/bin/bash
# =============================================================================
# throttle.sh — Network Bandwidth Throttle Manager
# =============================================================================
# PURPOSE:
#   Reads throttle.ini to configure time-based bandwidth limits on a network
#   interface using Linux Traffic Control (tc). During defined time windows,
#   bandwidth is capped to the configured maximum. Outside those windows,
#   bandwidth is unrestricted (all tc rules removed).
#
# CONFIGURATION FILE: /etc/throttle.ini
#   Line 1: Maximum bandwidth in MB/s (float), e.g.: 50.0
#   Line 2: Network interface name, e.g.: eth0
#   Lines 3+: Time window pairs in 24-hour HH:MM format, space-separated
#             e.g.: 08:00 18:00
#             Multiple pairs are supported. During ANY of these windows,
#             the bandwidth cap is active.
#
# DEPENDENCIES: tc (iproute2), bash >= 4.0
# RUNS AS: root (required for tc commands)
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
INI_FILE="/etc/throttle.ini"
LOG_TAG="throttle"

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING — writes to syslog (readable with: journalctl -t throttle)
# ──────────────────────────────────────────────────────────────────────────────
log() {
    logger -t "$LOG_TAG" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"
}

# ──────────────────────────────────────────────────────────────────────────────
# PARSE INI FILE
#   Sets globals: BANDWIDTH_MBS, INTERFACE, TIME_PAIRS (array)
# ──────────────────────────────────────────────────────────────────────────────
parse_ini() {
    if [[ ! -f "$INI_FILE" ]]; then
        log "ERROR: $INI_FILE not found. Cannot continue."
        exit 1
    fi

    # Read all non-empty, non-comment lines into an array
    mapfile -t LINES < <(grep -v '^\s*#' "$INI_FILE" | grep -v '^\s*$')

    if [[ ${#LINES[@]} -lt 3 ]]; then
        log "ERROR: $INI_FILE must have at least 3 lines (bandwidth, interface, one time pair)."
        exit 1
    fi

    BANDWIDTH_MBS="${LINES[0]}"
    INTERFACE="${LINES[1]}"

    # Validate bandwidth is a positive float
    if ! [[ "$BANDWIDTH_MBS" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log "ERROR: Bandwidth '$BANDWIDTH_MBS' is not a valid positive number."
        exit 1
    fi

    # Validate interface exists
    if ! ip link show "$INTERFACE" &>/dev/null; then
        log "ERROR: Network interface '$INTERFACE' does not exist."
        exit 1
    fi

    # Parse time pairs — each line from index 2 onward is one pair
    TIME_PAIRS=()
    for (( i=2; i<${#LINES[@]}; i++ )); do
        local pair="${LINES[$i]}"
        # Validate format: HH:MM HH:MM
        if [[ "$pair" =~ ^([0-2][0-9]:[0-5][0-9])\ ([0-2][0-9]:[0-5][0-9])$ ]]; then
            TIME_PAIRS+=("$pair")
        else
            log "WARNING: Skipping malformed time pair: '$pair'"
        fi
    done

    if [[ ${#TIME_PAIRS[@]} -eq 0 ]]; then
        log "ERROR: No valid time pairs found in $INI_FILE."
        exit 1
    fi

    log "Config loaded: ${BANDWIDTH_MBS} MB/s on ${INTERFACE}, ${#TIME_PAIRS[@]} time window(s)."
}

# ──────────────────────────────────────────────────────────────────────────────
# TIME UTILITIES
#   Convert HH:MM to minutes-since-midnight for integer comparison
# ──────────────────────────────────────────────────────────────────────────────
time_to_minutes() {
    # $1 = "HH:MM"
    local h="${1%%:*}"
    local m="${1##*:}"
    echo $(( 10#$h * 60 + 10#$m ))
}

current_minutes() {
    date '+%-H * 60 + %-M' | bc
}

# ──────────────────────────────────────────────────────────────────────────────
# IS_THROTTLE_WINDOW
#   Returns 0 (true) if current time falls within any configured time pair.
#   Handles midnight-spanning windows (e.g., 22:00 06:00).
# ──────────────────────────────────────────────────────────────────────────────
is_throttle_window() {
    local now
    now=$(current_minutes)

    for pair in "${TIME_PAIRS[@]}"; do
        local start_str end_str
        start_str="${pair%% *}"
        end_str="${pair##* }"
        local start end
        start=$(time_to_minutes "$start_str")
        end=$(time_to_minutes "$end_str")

        if [[ "$start" -lt "$end" ]]; then
            # Normal window: e.g., 08:00–18:00
            if [[ "$now" -ge "$start" && "$now" -lt "$end" ]]; then
                return 0
            fi
        else
            # Midnight-spanning window: e.g., 22:00–06:00
            if [[ "$now" -ge "$start" || "$now" -lt "$end" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# APPLY THROTTLE
#   Installs an HTB (Hierarchical Token Bucket) qdisc on the interface.
#   HTB is the standard Linux method for rate limiting. The root qdisc
#   drops all old rules first to ensure idempotency.
#   BANDWIDTH_MBS is converted: 1 MB/s = 8 Mbit/s
# ──────────────────────────────────────────────────────────────────────────────
apply_throttle() {
    # Convert MB/s to kbit/s for tc (tc uses kbit)
    # 1 MB/s = 1,000,000 bytes/s = 8,000,000 bits/s = 8000 kbit/s
    local kbits
    kbits=$(echo "$BANDWIDTH_MBS * 8000" | bc | cut -d. -f1)

    log "Applying throttle: ${BANDWIDTH_MBS} MB/s (${kbits} kbit/s) on ${INTERFACE}"

    # Remove any existing qdisc (ignore error if none exists)
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true

    # Add root HTB qdisc
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 10

    # Add HTB class with rate = max bandwidth, burst = 10% of rate
    local burst_kbits=$(( kbits / 10 ))
    [[ "$burst_kbits" -lt 64 ]] && burst_kbits=64  # Minimum sensible burst

    tc class add dev "$INTERFACE" parent 1: classid 1:10 htb \
        rate "${kbits}kbit" \
        burst "${burst_kbits}kbit"

    log "Throttle active: ${BANDWIDTH_MBS} MB/s on ${INTERFACE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# REMOVE THROTTLE
#   Deletes all tc rules — restores full/unlimited bandwidth.
# ──────────────────────────────────────────────────────────────────────────────
remove_throttle() {
    log "Removing throttle — restoring full bandwidth on ${INTERFACE}"
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    log "Throttle removed. Full bandwidth restored on ${INTERFACE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# STATUS CHECK
#   Used at startup and each evaluation cycle to apply or remove rules
#   based on current time.
# ──────────────────────────────────────────────────────────────────────────────
evaluate_and_apply() {
    if is_throttle_window; then
        apply_throttle
    else
        remove_throttle
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
#   Evaluates every 60 seconds. This tight loop ensures transitions at
#   window boundaries occur within one minute of the configured time.
# ──────────────────────────────────────────────────────────────────────────────
main() {
    log "throttle.sh starting. Reading $INI_FILE"
    parse_ini

    log "Bandwidth: ${BANDWIDTH_MBS} MB/s | Interface: ${INTERFACE}"
    for pair in "${TIME_PAIRS[@]}"; do
        log "  Throttle window: $pair"
    done

    # Apply correct state immediately on start
    evaluate_and_apply

    # Track last applied state to avoid redundant tc calls
    local last_state=""
    if is_throttle_window; then
        last_state="throttled"
    else
        last_state="open"
    fi

    while true; do
        sleep 60

        local current_state
        if is_throttle_window; then
            current_state="throttled"
        else
            current_state="open"
        fi

        # Only reconfigure tc if state has changed
        if [[ "$current_state" != "$last_state" ]]; then
            log "State change detected: $last_state → $current_state"
            evaluate_and_apply
            last_state="$current_state"
        fi
    done
}

main
