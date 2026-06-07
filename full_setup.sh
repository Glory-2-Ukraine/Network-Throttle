#!/bin/bash
# =============================================================================
# Glory-2-Ukraine — Full Server Setup
# Installs:
#   1. Network Bandwidth Throttle (throttle.sh + systemd service)
#   2. Network Watchdog v3 (net-watchdog2.sh + systemd timer)
# =============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash setup.sh"; exit 1; }

echo "============================================="
echo " Glory-2-Ukraine Full Server Setup"
echo "============================================="
echo ""

# ── STEP 1: Dependencies ──────────────────────────────────────────────────────
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq iproute2 bc network-manager
echo "      Done."

# ── STEP 2: throttle.sh ───────────────────────────────────────────────────────
echo "[2/7] Installing throttle.sh..."
tee /usr/local/bin/throttle.sh > /dev/null << 'SCRIPT'
#!/bin/bash
# =============================================================================
# throttle.sh — Network Bandwidth Throttle Manager
# Config: /etc/throttle.ini
# Line 1: Max bandwidth MB/s (float)
# Line 2: Network interface (e.g. eth0, wlan0)
# Lines 3+: Time window pairs HH:MM HH:MM (24-hour). Throttle active during these windows.
# =============================================================================
set -euo pipefail
INI_FILE="/etc/throttle.ini"
LOG_TAG="throttle"
log() { logger -t "$LOG_TAG" "$*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

parse_ini() {
    [[ ! -f "$INI_FILE" ]] && { log "ERROR: $INI_FILE not found."; exit 1; }
    mapfile -t LINES < <(grep -v '^\s*#' "$INI_FILE" | grep -v '^\s*$')
    [[ ${#LINES[@]} -lt 3 ]] && { log "ERROR: throttle.ini needs bandwidth, interface, and at least one time pair."; exit 1; }
    BANDWIDTH_MBS="${LINES[0]}"
    INTERFACE="${LINES[1]}"
    [[ ! "$BANDWIDTH_MBS" =~ ^[0-9]+(\.[0-9]+)?$ ]] && { log "ERROR: Bandwidth '$BANDWIDTH_MBS' invalid."; exit 1; }
    ip link show "$INTERFACE" &>/dev/null || { log "ERROR: Interface '$INTERFACE' not found."; exit 1; }
    TIME_PAIRS=()
    for (( i=2; i<${#LINES[@]}; i++ )); do
        local pair="${LINES[$i]}"
        [[ "$pair" =~ ^([0-2][0-9]:[0-5][0-9])\ ([0-2][0-9]:[0-5][0-9])$ ]] \
            && TIME_PAIRS+=("$pair") \
            || log "WARNING: Skipping bad time pair: '$pair'"
    done
    [[ ${#TIME_PAIRS[@]} -eq 0 ]] && { log "ERROR: No valid time pairs."; exit 1; }
    log "Config: ${BANDWIDTH_MBS} MB/s on ${INTERFACE}, ${#TIME_PAIRS[@]} window(s)."
}

time_to_minutes() { local h="${1%%:*}"; local m="${1##*:}"; echo $(( 10#$h * 60 + 10#$m )); }
current_minutes() { date '+%-H * 60 + %-M' | bc; }

is_throttle_window() {
    local now; now=$(current_minutes)
    for pair in "${TIME_PAIRS[@]}"; do
        local start end
        start=$(time_to_minutes "${pair%% *}")
        end=$(time_to_minutes "${pair##* }")
        if [[ "$start" -lt "$end" ]]; then
            [[ "$now" -ge "$start" && "$now" -lt "$end" ]] && return 0
        else
            [[ "$now" -ge "$start" || "$now" -lt "$end" ]] && return 0
        fi
    done
    return 1
}

apply_throttle() {
    local kbits; kbits=$(echo "$BANDWIDTH_MBS * 8000" | bc | cut -d. -f1)
    local bytes_per_sec; bytes_per_sec=$(echo "$BANDWIDTH_MBS * 1000000" | bc | cut -d. -f1)
    local r2q; r2q=$(echo "$bytes_per_sec / 1500" | bc)
    [[ "$r2q" -lt 1     ]] && r2q=1
    [[ "$r2q" -gt 65535 ]] && r2q=65535
    local burst=$(( kbits / 10 )); [[ "$burst" -lt 64 ]] && burst=64
    log "Applying throttle: ${BANDWIDTH_MBS} MB/s (${kbits} kbit/s) on ${INTERFACE}"
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 10 r2q "${r2q}"
    tc class add dev "$INTERFACE" parent 1: classid 1:10 htb rate "${kbits}kbit" burst "${burst}kbit"
    log "Throttle active."
}

remove_throttle() {
    log "Removing throttle — full bandwidth on ${INTERFACE}"
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    log "Throttle removed."
}

main() {
    log "Starting throttle.sh. Reading $INI_FILE"
    parse_ini
    if is_throttle_window; then apply_throttle; last_state="throttled"
    else remove_throttle; last_state="open"; fi
    while true; do
        sleep 60
        if is_throttle_window; then cur="throttled"; else cur="open"; fi
        if [[ "$cur" != "$last_state" ]]; then
            log "State change: $last_state -> $cur"
            if [[ "$cur" == "throttled" ]]; then apply_throttle; else remove_throttle; fi
            last_state="$cur"
        fi
    done
}
main
SCRIPT
chmod +x /usr/local/bin/throttle.sh
echo "      Done."

# ── STEP 3: throttle.ini (only if not already present) ───────────────────────
echo "[3/7] Setting up throttle.ini..."
if [[ ! -f /etc/throttle.ini ]]; then
    tee /etc/throttle.ini > /dev/null << 'INI'
# Line 1: Max bandwidth in MB/s (e.g. 50.0 = 50 MB/s = 400 Mbit/s)
50.0
# Line 2: Network interface — run 'ip link show' to find yours
eth0
# Lines 3+: Time pairs HH:MM HH:MM (24-hour). Throttle active during these windows.
08:00 18:00
INI
    echo "      /etc/throttle.ini created — EDIT THIS before starting the service."
    echo "      Run: nano /etc/throttle.ini"
else
    echo "      /etc/throttle.ini already exists — not overwritten."
fi

# ── STEP 4: throttle.service ──────────────────────────────────────────────────
echo "[4/7] Installing throttle.service..."
tee /etc/systemd/system/throttle.service > /dev/null << 'SVC'
[Unit]
Description=Network Bandwidth Throttle Manager
Documentation=https://github.com/Glory-2-Ukraine/Network-Throttle
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/throttle.sh
Restart=always
RestartSec=5
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
NoNewPrivileges=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=throttle

[Install]
WantedBy=multi-user.target
SVC
echo "      Done."

# ── STEP 5: net-watchdog2.sh ──────────────────────────────────────────────────
echo "[5/7] Installing net-watchdog2.sh..."
tee /usr/local/bin/net-watchdog2.sh > /dev/null << 'SCRIPT'
#!/bin/bash
# =============================================================================
# net-watchdog2.sh — Network Watchdog v3
# GW neighbor check + external TCP check; congestion-aware
# Configured via environment in net-watchdog2.service:
#   IFACE      — interface to monitor (default: wlan0)
#   COOLDOWN_S — seconds between recovery attempts (default: 180)
# =============================================================================
IFACE="${IFACE:-wlan0}"
COOLDOWN_S="${COOLDOWN_S:-180}"
COOLDOWN_FILE="/tmp/net-watchdog2.cooldown"
LOG_TAG="net-watchdog2"
log() { logger -t "$LOG_TAG" "$*"; }

if [[ -f "$COOLDOWN_FILE" ]]; then
    last=$(cat "$COOLDOWN_FILE"); now=$(date +%s); elapsed=$(( now - last ))
    if [[ $elapsed -lt $COOLDOWN_S ]]; then
        log "Cooldown active (${elapsed}s < ${COOLDOWN_S}s), skipping."; exit 0
    fi
fi

if ! ip link show "$IFACE" 2>/dev/null | grep -q "state UP"; then
    log "FAIL: $IFACE not UP. Reconnecting."
    date +%s > "$COOLDOWN_FILE"; nmcli device connect "$IFACE" 2>/dev/null || true; exit 1
fi

if ! timeout 5 bash -c "echo >/dev/tcp/8.8.8.8/53" 2>/dev/null && \
   ! timeout 5 bash -c "echo >/dev/tcp/1.1.1.1/53" 2>/dev/null; then
    log "FAIL: No internet on $IFACE. Reconnecting."
    date +%s > "$COOLDOWN_FILE"; nmcli device connect "$IFACE" 2>/dev/null || true; exit 1
fi

LOAD=$(awk '{print $1}' /proc/loadavg | cut -d. -f1); CPU_COUNT=$(nproc)
log "OK: $IFACE internet reachable, load=${LOAD}/${CPU_COUNT}"
exit 0
SCRIPT
chmod +x /usr/local/bin/net-watchdog2.sh
echo "      Done."

# ── STEP 6: net-watchdog2.service + timer ────────────────────────────────────
echo "[6/7] Installing net-watchdog2 service and timer..."
tee /etc/systemd/system/net-watchdog2.service > /dev/null << 'SVC'
[Unit]
Description=Network watchdog v3 (GW neighbor + external TCP check; congestion-aware)
Documentation=https://github.com/Glory-2-Ukraine/Network-Watchdog
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=IFACE=wlan0
Environment=COOLDOWN_S=180
ExecStart=/usr/local/bin/net-watchdog2.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=net-watchdog2

[Install]
WantedBy=multi-user.target
SVC

tee /etc/systemd/system/net-watchdog2.timer > /dev/null << 'TIMER'
[Unit]
Description=Run network watchdog v3 every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
Unit=net-watchdog2.service

[Install]
WantedBy=timers.target
TIMER
echo "      Done."

# ── STEP 7: Enable and start everything ──────────────────────────────────────
echo "[7/7] Enabling and starting services..."
systemctl daemon-reload

systemctl enable throttle.service
systemctl start throttle.service

systemctl enable net-watchdog2.timer
systemctl start net-watchdog2.timer
systemctl reset-failed net-watchdog2.service 2>/dev/null || true

echo ""
echo "============================================="
echo " Setup complete."
echo "============================================="
echo ""
echo "IMPORTANT: Edit your throttle config before the"
echo "throttle service does anything meaningful:"
echo ""
echo "  nano /etc/throttle.ini"
echo "  systemctl restart throttle"
echo ""
echo "Key settings in /etc/throttle.ini:"
echo "  Line 1: Max bandwidth in MB/s"
echo "  Line 2: Interface name (run 'ip link show' to find yours)"
echo "  Lines 3+: Time windows HH:MM HH:MM"
echo ""
echo "Watchdog interface (default: wlan0):"
echo "  nano /etc/systemd/system/net-watchdog2.service"
echo "  systemctl daemon-reload && systemctl restart net-watchdog2.timer"
echo ""
echo "Check status:"
echo "  systemctl status throttle"
echo "  systemctl status net-watchdog2.timer"
echo ""
echo "Live logs:"
echo "  journalctl -t throttle -f"
echo "  journalctl -t net-watchdog2 -f"
echo ""
echo "Emergency — remove all throttle rules instantly:"
echo "  tc qdisc del dev eth0 root"
echo "  tc qdisc del dev wlan0 root"
echo "============================================="
