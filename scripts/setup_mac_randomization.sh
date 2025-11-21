#!/usr/bin/env bash
set -Eeuo pipefail

# Helper function for logging
log() {
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [MACRAND] [${level}] ${message}"
}

error_exit() {
  log "ERROR" "${1}" >&2
  exit 1
}

usage(){
  echo "Usage: $0 --config <file>" >&2
  exit 1
}

CONFIG_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    *) usage;;
  esac
done

if [ -z "$CONFIG_FILE" ]; then
  usage
fi

# shellcheck source=/dev/null
. "$CONFIG_FILE"

install_pkgs(){
  log "INFO" "Installing necessary packages: network-manager, macchanger"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || error_exit "apt-get update failed"
  apt-get install -y network-manager macchanger || error_exit "Failed to install network-manager or macchanger"
  apt-get clean
}

setup_nm_randomization(){
  log "INFO" "Configuring NetworkManager for MAC randomization."
  mkdir -p /etc/NetworkManager/conf.d || error_exit "Failed to create /etc/NetworkManager/conf.d"
  cat > /etc/NetworkManager/conf.d/00-mac-randomization.conf << 'EOF'
[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
wifi.scan-rand-mac-address=yes

[device]
wifi.scan-rand-mac-address=yes
EOF
  log "INFO" "NetworkManager configuration applied."
}

setup_macchanger_unit(){
  log "INFO" "Setting up systemd service for boot-time macchanger randomization."
  cat > /etc/systemd/system/macchanger-randomize.service << 'EOF'
[Unit]
Description=Randomize MAC addresses at boot
After=network-pre.target
Before=NetworkManager.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/macrotate.sh

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p /usr/local/sbin || error_exit "Failed to create /usr/local/sbin"
  cat > /usr/local/sbin/macrotate.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# This script is executed by systemd to randomize MAC addresses.
# It iterates over network devices and applies macchanger.
# Errors are explicitly ignored for 'ip link set down/up' as device state might vary.
log_macchanger(){ printf '[MACROTATE] %s\n' "$*"; }

log_macchanger "INFO" "Starting MAC address randomization for active interfaces."
for dev in $(ls /sys/class/net); do
  case "$dev" in
    lo) continue ;; # Skip loopback interface
  esac
  log_macchanger "INFO" "Processing device: $dev"
  if command -v macchanger >/dev/null 2>&1; then
    ip link set "$dev" down || log_macchanger "WARN" "Failed to bring down $dev, proceeding anyway."
    macchanger -r "$dev" || log_macchanger "WARN" "Failed to randomize MAC for $dev, proceeding anyway."
    ip link set "$dev" up || log_macchanger "WARN" "Failed to bring up $dev, proceeding anyway."
  else
    log_macchanger "WARN" "macchanger not found. Cannot randomize MAC for $dev."
  fi
done
log_macchanger "INFO" "MAC address randomization sweep finished."
EOF
  chmod +x /usr/local/sbin/macrotate.sh || error_exit "Failed to make macrotate.sh executable"

  systemctl enable macchanger-randomize.service || log "WARN" "Failed to enable macchanger-randomize.service (may not be in chroot)."
  log "INFO" "Systemd service for macchanger randomization configured."
}

log "INFO" "Configuring MAC address randomization."

if [ "${ENABLE_MAC_RANDOMIZATION}" -eq 1 ]; then
  install_pkgs
  setup_nm_randomization
  setup_macchanger_unit
  log "INFO" "MAC randomization successfully configured."
else
  log "INFO" "MAC randomization is disabled in hardened-os.conf. Skipping configuration."
fi
