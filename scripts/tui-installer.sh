#!/usr/bin/env bash
set -Eeuo pipefail

# Simple TUI front-end that will later call build_hardened_target.sh
# from the live/installer environment.

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Helper function for logging
log() {
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [TUI] [${level}] ${message}"
}

error_exit() {
  log "ERROR" "${1}" >&2
  exit 1
}

CONFIG_DIR="$(dirname "$(readlink -f "$0")")/.." # Path to the hardened-installer directory
CONFIG_FILE="${CONFIG_DIR}/hardened-os.conf"
BUILD_SCRIPT="${CONFIG_DIR}/scripts/build_hardened_target.sh"
DIALOG=${DIALOG:-dialog}

# shellcheck source=/dev/null
. "$CONFIG_FILE"

require_root(){
  if [ "$(id -u)" -ne 0 ]; then
    log "ERROR" "This installer must be run as root." >&2
    error_exit "Root privileges required."
  fi
}

select_disk(){
  log "INFO" "Selecting target disk."
  local disks choices
  # Use lsblk to get disks and their sizes
  disks=$(lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk"{print $1" "$2}')
  choices=""
  for d in $disks; do
    name=$(echo "$d" | awk '{print $1}')
    size=$(echo "$d" | awk '{print $2}')
    choices="$choices /dev/$name \"$size\""
  done
  
  if [ -z "$choices" ]; then
    $DIALOG --msgbox "No disks found. Exiting." 7 40
    error_exit "No disks available for installation."
  fi
  
  # Present disk selection menu
  # shellcheck disable=SC2086
  TARGET_DISK=$(eval "$DIALOG --stdout --menu 'Select target disk (WARNING: ALL DATA WILL BE WIPED):' 20 70 10 $choices") || error_exit "Disk selection cancelled."
  log "INFO" "Selected target disk: $TARGET_DISK"
}

confirm_wipe(){
  log "WARN" "Asking for confirmation to wipe $TARGET_DISK."
  $DIALOG --title "CONFIRM DISK WIPE" --yesno "WARNING: All data on $TARGET_DISK will be ERASED. This action is irreversible.\n\nAre you absolutely sure you want to continue?" 10 60 || error_exit "Disk wipe confirmation denied."
  log "INFO" "Disk wipe confirmed."
}

ask_hostname(){
  log "INFO" "Asking for hostname."
  OS_HOSTNAME=$($DIALOG --stdout --inputbox "Enter hostname for the new system:" 8 50 "${OS_HOSTNAME}") || error_exit "Hostname entry cancelled."
  log "INFO" "Set hostname to: $OS_HOSTNAME"
}

ask_luks(){
  log "INFO" "Asking for LUKS passphrase."
  local L1 L2
  L1=$($DIALOG --stdout --insecure --passwordbox "Enter a strong LUKS passphrase for Full Disk Encryption:" 10 60) || error_exit "LUKS passphrase entry cancelled."
  L2=$($DIALOG --stdout --insecure --passwordbox "Confirm LUKS passphrase:" 10 60) || error_exit "LUKS passphrase confirmation cancelled."
  
  if [ "$L1" != "$L2" ]; then
    $DIALOG --msgbox "Passphrases do not match. Please try again." 7 50
    ask_luks # Recurse if passphrases don't match
  elif [ -z "$L1" ]; then
    $DIALOG --msgbox "Passphrase cannot be empty. Please try again." 7 50
    ask_luks
  else
    LUKS_PASS="$L1"
    log "INFO" "LUKS passphrase entered."
  fi
}

run_install(){
  local install_log="/tmp/hardened-install-$(date +%s).log"
  log "INFO" "Starting installation process on $TARGET_DISK. Output redirected to $install_log"

  # Run the build script in the background, piping LUKS_PASS to it, and redirecting its output to a log file.
  (echo "$LUKS_PASS" | "$BUILD_SCRIPT" --config "$CONFIG_FILE" --disk "$TARGET_DISK" --hostname "$OS_HOSTNAME" --luks-passphrase-stdin > "$install_log" 2>&1) &
  local build_pid=$!

  # Display a tailbox to show progress.
  $DIALOG --tailbox "$install_log" 25 80 &
  local tailbox_pid=$!

  # Wait for the build script to finish.
  wait "$build_pid"
  local rc=$?

  # Kill the tailbox process once the build is done.
  kill "$tailbox_pid" || true # Ignore error if tailbox already exited

  # Display final message based on return code
  if [ $rc -eq 0 ]; then
    $DIALOG --msgbox "Installation complete! Your hardened Debian system has been installed on $TARGET_DISK.\n\nYou can now reboot." 10 60
    log "INFO" "Installation finished successfully."
  else
    $DIALOG --msgbox "Installation FAILED (Error Code: $rc).\n\nCheck the full log in $install_log for details." 15 70
    log "ERROR" "Installation failed with exit code $rc. Log: $install_log"
  fi

  # Cleanup the install log (optional, or move to a more persistent location)
  rm "$install_log" || log "WARN" "Failed to remove install log: $install_log"

  return $rc
}

# --- Main Installer Flow ---
require_root

$DIALOG --title "Hardened Debian Installer" --msgbox "Welcome to the Hardened Debian 6.17 FDE Installer.\n\nThis installer will set up a Debian system with full disk encryption, hardened defaults, and an optimized privacy stack.\n\nPress OK to continue." 15 70

select_disk
confirm_wipe
ask_hostname
ask_luks

run_install
# Keep the terminal open on success for user to read final message
# or on failure to see logs
if [ $? -eq 0 ]; then
  log "INFO" "Installer finished. Reboot to complete."
else
  log "ERROR" "Installer encountered errors. Please review logs."
fi

# Give user time to see final message before shell potentially closes
read -rp "Press Enter to exit installer..."
