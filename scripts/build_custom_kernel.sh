#!/usr/bin/env bash
set -Eeuo pipefail

# Helper function for logging
log() {
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [KERNEL-BUILD] [${level}] ${message}"
}

error_exit() {
  log "ERROR" "${1}" >&2
  exit 1
}

usage(){
  echo "Usage: $0 --config <file> --output-dir <path>" >&2
  exit 1
}

CONFIG_FILE=""
OUTPUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    *) usage;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
  usage
fi

# shellcheck source=/dev/null
. "$CONFIG_FILE"

log "INFO" "Starting custom kernel build process."
log "INFO" "Kernel source URL: ${KERNEL_SOURCE_URL}"
log "INFO" "Kernel config template: ${KERNEL_CONFIG_TEMPLATE}"
log "INFO" "Output directory for .deb packages: ${OUTPUT_DIR}"

mkdir -p "${OUTPUT_DIR}" || error_exit "Failed to create output directory ${OUTPUT_DIR}"

BUILD_DIR="/tmp/kernel_build_$(date +%s)"
mkdir -p "${BUILD_DIR}" || error_exit "Failed to create kernel build directory ${BUILD_DIR}"
cd "${BUILD_DIR}" || error_exit "Failed to change to kernel build directory ${BUILD_DIR}"

# 1. Install Build Dependencies
log "INFO" "Installing kernel build dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update || error_exit "apt-get update failed"
apt-get install -y --no-install-recommends \
  build-essential \
  flex \
  bison \
  libssl-dev \
  libelf-dev \
  pahole \
  python3 \
  python3-pyelftools \
  xz-utils \
  bc \
  kmod \
  cpio \
  debianutils \
  firmware-linux-free \
  firmware-misc-nonfree \
  firmware-iwlwifi \
  firmware-realtek \
  firmware-atheros || error_exit "Failed to install kernel build dependencies"
apt-get clean

# 2. Download and Extract Kernel Source
log "INFO" "Downloading kernel source from ${KERNEL_SOURCE_URL}..."
local kernel_tarball_name=$(basename "${KERNEL_SOURCE_URL}")
wget -q -O "${kernel_tarball_name}" "${KERNEL_SOURCE_URL}" || error_exit "Failed to download kernel source from ${KERNEL_SOURCE_URL}"

# Verify SHA256 sum
if [ -n "${KERNEL_SOURCE_SHA256SUM}" ] && [ "${KERNEL_SOURCE_SHA256SUM}" != "<PLACEHOLDER_KERNEL_SHA256SUM>" ]; then
  log "INFO" "Verifying SHA256 sum of ${kernel_tarball_name}..."
  echo "${KERNEL_SOURCE_SHA256SUM}  ${kernel_tarball_name}" | sha256sum -c || error_exit "SHA256 sum verification failed for kernel source."
else
  log "WARN" "KERNEL_SOURCE_SHA256SUM is not set or is a placeholder. Skipping SHA256 verification for kernel source."
fi

tar -xJ -f "${kernel_tarball_name}" --strip-components=1 || error_exit "Failed to extract kernel source."

# 3. Configure Kernel
log "INFO" "Configuring kernel using template: ${KERNEL_CONFIG_TEMPLATE}..."
cp "${KERNEL_CONFIG_TEMPLATE}" ./.config || error_exit "Failed to copy kernel config template"

# Update kernel config for current system
yes "" | make oldconfig || error_exit "Failed to run make oldconfig"

# Optional: Further hardening/tweaking of the .config can go here
# e.g., using scripts to enforce certain options, or modifying .config directly with sed

# 4. Inject Compiler Flags from environment
log "INFO" "Using KERNEL_BUILD_CFLAGS='${KERNEL_BUILD_CFLAGS}' and KERNEL_BUILD_LDFLAGS='${KERNEL_BUILD_LDFLAGS}' for kernel build."
export KBUILD_CFLAGS="${KERNEL_BUILD_CFLAGS}"
export KBUILD_LDFLAGS="${KERNEL_BUILD_LDFLAGS}"
export KCFLAGS="${KBUILD_CFLAGS}" # For kernel internal use

# 5. Build Kernel .deb packages
log "INFO" "Building kernel .deb packages. This may take a while..."
make -j"$(nproc)" bindeb-pkg || error_exit "Failed to build kernel .deb packages"

# 6. Copy .deb packages to output directory
log "INFO" "Copying generated .deb packages to ${OUTPUT_DIR}..."
cp "${BUILD_DIR}/.."/*.deb "${OUTPUT_DIR}/" || error_exit "Failed to copy kernel .deb packages"

# 7. Cleanup
log "INFO" "Cleaning up kernel build directory..."
cd /tmp || error_exit "Failed to change to /tmp"
rm -rf "${BUILD_DIR}" || log "WARN" "Failed to remove kernel build directory ${BUILD_DIR}"

log "INFO" "Custom kernel build process finished successfully."
