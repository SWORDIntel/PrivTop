#!/usr/bin/env bash
set -Eeuo pipefail

log_build(){
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [BUILD.SH] [${level}] ${message}"
}

error_exit(){
  log_build "ERROR" "${1}" >&2
  exit 1
}

check_dependencies(){
  log_build "INFO" "Checking for required system dependencies..."
  local deps=(debootstrap xorriso git wget tar gzip bzip2 xz gcc make dpkg-deb pkg-config dialog lsblk cpio bc kmod flex bison python3 qemu-system-x86 rustc cargo)
  local missing_deps=()

  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      missing_deps+=("$dep")
    fi
  done

  if [ "${#missing_deps[@]}" -ne 0 ]; then
    error_exit "Missing required system dependencies: ${missing_deps[*]}

Please install them using your distribution's package manager (e.g., 'sudo apt install <package-name>')."
  fi
  log_build "INFO" "All required command-line dependencies found."

  # Check for firmware packages (these are apt packages, not commands)
  # This part is a bit trickier to "check" if installed from a script, but we can assume
  # a modern Debian-based system will have these or can install them.
  # For now, a manual check or relying on apt to handle it during debootstrap/kernel build.
  log_build "INFO" "Ensuring firmware packages are considered for installation (e.g. firmware-iwlwifi)."
}

usage(){
  echo "Usage: $0 --config <file> --output <iso_path>" >&2
  echo "Example: sudo $0 --config hardened-os.conf --output hardened-debian-installer.iso" >&2
  exit 1
}

CONFIG_FILE=""
OUTPUT_ISO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --output) OUTPUT_ISO="$2"; shift 2;;
    *) usage;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ -z "$OUTPUT_ISO" ]; then
  usage
fi

if [ ! -f "$CONFIG_FILE" ]; then
  error_exit "Configuration file not found: $CONFIG_FILE"
fi

# Ensure root privileges
if [ "$(id -u)" -ne 0 ]; then
  error_exit "This script must be run as root. Please use sudo."
fi

# Check and install dependencies
check_dependencies

log_build "INFO" "Starting the ISO generation process..."
# Call the main ISO build script
./scripts/build_iso.sh --config "$CONFIG_FILE" --output "$OUTPUT_ISO" || error_exit "ISO build process failed."

log_build "INFO" "ISO generation completed successfully: $OUTPUT_ISO"
