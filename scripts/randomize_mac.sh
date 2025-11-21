#!/usr/bin/env bash
set -Eeuo pipefail

# This script randomizes the MAC addresses of all network interfaces except loopback.

log_mac_randomizer(){
  echo "[MAC-RANDOMIZER] $1"
}

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi

log_mac_randomizer "Starting MAC address randomization..."

for dev in $(ls /sys/class/net); do
  case "$dev" in
    lo) continue ;; # Skip loopback interface
  esac
  log_mac_randomizer "Processing device: $dev"
  if command -v macchanger >/dev/null 2>&1; then
    ip link set "$dev" down || log_mac_randomizer "WARN: Failed to bring down $dev, proceeding anyway."
    macchanger -r "$dev" || log_mac_randomizer "WARN: Failed to randomize MAC for $dev, proceeding anyway."
    ip link set "$dev" up || log_mac_randomizer "WARN: Failed to bring up $dev, proceeding anyway."
  else
    log_mac_randomizer "ERROR: macchanger not found. Cannot randomize MAC for $dev."
    exit 1
  fi
done

log_mac_randomizer "MAC address randomization complete."
