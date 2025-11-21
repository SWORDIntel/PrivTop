#!/usr/bin/env bash
set -Eeuo pipefail

# Helper function for logging
log() {
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [PRIVACY] [${level}] ${message}"
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
  log "INFO" "Installing necessary packages: tor, i2pd, network-manager."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || error_exit "apt-get update failed"
  # Note: 'i2p' package is a client for I2P, 'i2pd' is the daemon. Installing both.
  apt-get install -y tor i2pd i2p network-manager || error_exit "Failed to install privacy-related packages"
  apt-get clean
}

setup_offline_unit(){
  log "INFO" "Setting up systemd service to disable networking by default."
  if ! command -v nmcli >/dev/null 2>&1; then
    log "WARN" "NetworkManager not present; skipping offline-by-default unit setup."
    return 0
  fi

  cat > /etc/systemd/system/offline-by-default.service << 'EOF'
[Unit]
Description=Disable networking by default until privacy launcher is used
After=network-online.target NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nmcli networking off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable offline-by-default.service || log "WARN" "Failed to enable offline-by-default.service (may not be in chroot)."
  log "INFO" "Offline-by-default systemd service configured."
}

create_launchers(){
  log "INFO" "Creating privacy tool launchers."
  mkdir -p /usr/local/bin || error_exit "Failed to create /usr/local/bin"

  cat > /usr/local/bin/start-tor-locked.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
log_launcher(){ printf '[LAUNCHER-TOR] %s\n' "$*"; }
log_launcher "INFO" "Attempting to enable networking and start Tor."
if command -v nmcli >/dev/null 2>&1; then nmcli networking on || log_launcher "WARN" "Failed to enable NetworkManager networking."; fi
systemctl start tor || log_launcher "WARN" "Failed to start Tor service."
printf "Tor started. Launch Tor Browser manually if installed.\n"
EOF
  chmod +x /usr/local/bin/start-tor-locked.sh || error_exit "Failed to make start-tor-locked.sh executable"

  cat > /usr/local/bin/start-i2p-locked.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
log_launcher(){ printf '[LAUNCHER-I2P] %s\n' "$*"; }
log_launcher "INFO" "Attempting to enable networking and start I2P router."
if command -v nmcli >/dev/null 2>&1; then nmcli networking on || log_launcher "WARN" "Failed to enable NetworkManager networking."; fi
systemctl start i2pd || log_launcher "WARN" "Failed to start i2pd service."
printf "I2P router started. Open http://127.0.0.1:7657/ in your browser.\n"
EOF
  chmod +x /usr/local/bin/start-i2p-locked.sh || error_exit "Failed to make start-i2p-locked.sh executable"

  mkdir -p /usr/share/applications || error_exit "Failed to create /usr/share/applications"

  cat > /usr/share/applications/tor-locked.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Tor (Locked Network)
Comment=Enable networking and start Tor daemon
Exec=/usr/local/bin/start-tor-locked.sh
Icon=network-vpn
Terminal=false
Categories=Network;Security;
EOF

  cat > /usr/share/applications/i2p-locked.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=I2P (Locked Network)
Comment=Enable networking and start I2P router
Exec=/usr/local/bin/start-i2p-locked.sh
Icon=network-workgroup
Terminal=false
Categories=Network;Security;
EOF
  log "INFO" "Privacy tool launchers created."
}

log "INFO" "Configuring privacy tools (Tor/I2P stack)."

if [ "${ENABLE_TOR_I2P_STACK}" -eq 1 ]; then
  install_pkgs
  setup_offline_unit
  create_launchers
  log "INFO" "Privacy tools (Tor/I2P stack) successfully configured."
else
  log "INFO" "Tor/I2P stack installation is disabled in hardened-os.conf. Skipping configuration."
fi
