#!/usr/bin/env bash
set -Eeuo pipefail

# Helper function for logging
log() {
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [ISO] [${level}] ${message}"
}

error_exit() {
  log "ERROR" "${1}" >&2
  exit 1
}

usage(){
  echo "Usage: $0 --config <file> --output <iso_path>" >&2
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

# shellcheck source=/dev/null
. "$CONFIG_FILE"

log "INFO" "Starting ISO build process."
log "INFO" "Output ISO will be: ${OUTPUT_ISO}"

# --- Temporary Working Directory ---
ISO_BUILD_DIR="/tmp/iso_build_$(date +%s)"
INSTALLER_ROOT="${ISO_BUILD_DIR}/installer_root"
mkdir -p "${INSTALLER_ROOT}" || error_exit "Failed to create installer root directory."

log "INFO" "Created temporary ISO build directory: ${ISO_BUILD_DIR}"

# --- Conditional Pre-build Custom Kernel on Host ---
if [ "${PREBUILD_CUSTOM_KERNEL}" -eq 1 ]; then
  log "INFO" "Pre-building custom kernel on host machine..."
  # Use host's config (CFLAGS_BASELINE/LDFLAGS_BASELINE should be statically in hardened-os.conf for kernel)
  (
    # Ensure build_custom_kernel.sh gets the correct config and flags
    export KERNEL_BUILD_CFLAGS="${CFLAGS_BASELINE}"
    export KERNEL_BUILD_LDFLAGS="${LDFLAGS_BASELINE}"
    ./scripts/build_custom_kernel.sh --config "$CONFIG_FILE" --output-dir "${PREBUILD_KERNEL_DEBS_DIR}"
  ) || error_exit "Failed to pre-build custom kernel."
  log "INFO" "Custom kernel pre-built."
else
  log "INFO" "Custom kernel pre-build skipped. Installer will install stock kernel or build on target if configured."
fi

# --- Conditional Pre-build Accelerated Libraries on Host ---
if [ "${PREBUILD_ACCEL_LIBS}" -eq 1 ]; then
  log "INFO" "Pre-building accelerated libraries on host machine..."
  (
    # The build_accel_libs.sh script itself sets CFLAGS/LDFLAGS based on ACCEL_CFLAGS/LDFLAGS from config
    # and dynamic detection. These should be the user's provided hot/baseline flags.
    export ACCEL_PREFIX="${PREBUILD_ACCEL_LIBS_INSTALL_DIR}"
    ./scripts/build_accel_libs.sh "$CONFIG_FILE"
  ) || error_exit "Failed to pre-build accelerated libraries."

  # Tar up the installed libraries
  log "INFO" "Creating tarball of pre-built accelerated libraries..."
  tar -cJf "${PREBUILD_ACCEL_LIBS_TAR}" -C "${PREBUILD_ACCEL_LIBS_INSTALL_DIR}" . || error_exit "Failed to create tarball of accelerated libraries."
  log "INFO" "Accelerated libraries pre-built and tarballed."
else
  log "INFO" "Accelerated libraries pre-build skipped. Installer will build on target if configured."
fi

# --- Conditional Pre-build FFmpeg Wasm on Host ---
log "INFO" "Pre-building FFmpeg Wasm module on host machine..."
# The build_ffmpeg_wasm.sh script will handle its own dependencies and build process.
(
  # The scripts from IMAGEHARDER might have their own way of handling output directories.
  # Let's assume for now they produce ffmpeg.wasm in the current directory.
  ./scripts/setup_emsdk.sh || error_exit "Failed to set up Emscripten SDK."
  ./scripts/build_ffmpeg_wasm.sh || error_exit "Failed to build FFmpeg Wasm module."
) || error_exit "Failed to pre-build FFmpeg Wasm."
log "INFO" "FFmpeg Wasm module pre-built."

# --- Pre-build Hardened Drivers on Host ---
log "INFO" "Pre-building hardened drivers on host machine..."
PREBUILD_AUDIO_DRIVERS_DIR="/opt/hardened-audio-drivers"
PREBUILD_VIDEO_DRIVERS_DIR="/opt/hardened-drivers"
PREBUILD_AUDIO_DRIVERS_TAR="${ISO_BUILD_DIR}/prebuilt_audio_drivers.tar.xz"
PREBUILD_VIDEO_DRIVERS_TAR="${ISO_BUILD_DIR}/prebuilt_video_drivers.tar.xz"

# The driver build scripts will install to /opt/hardened-*-drivers
./scripts/build_hardened_audio_drivers.sh || error_exit "Failed to build hardened audio drivers."
./scripts/build_hardened_drivers.sh || error_exit "Failed to build hardened video drivers."

# Tar up the installed drivers
log "INFO" "Creating tarball of pre-built hardened drivers..."
tar -cJf "${PREBUILD_AUDIO_DRIVERS_TAR}" -C "${PREBUILD_AUDIO_DRIVERS_DIR}" . || error_exit "Failed to create tarball of hardened audio drivers."
tar -cJf "${PREBUILD_VIDEO_DRIVERS_TAR}" -C "${PREBUILD_VIDEO_DRIVERS_DIR}" . || error_exit "Failed to create tarball of hardened video drivers."
log "INFO" "Hardened drivers pre-built and tarballed."

# --- Pre-build ImageHarden Rust Crate on Host ---
log "INFO" "Pre-building ImageHarden Rust crate on host machine..."
(
  cd IMAGEHARDER_reference/image_harden || error_exit "Failed to cd into IMAGEHARDER_reference/image_harden"
  cargo build --release || error_exit "Failed to build ImageHarden Rust crate."
)
log "INFO" "ImageHarden Rust crate pre-built."


# --- Installer Root Debootstrap ---
log "INFO" "Debootstrapping minimal Debian ${DEBIAN_RELEASE} for installer root..."
debootstrap --arch=amd64 "${DEBIAN_RELEASE}" "${INSTALLER_ROOT}" "${DEBIAN_MIRROR}" || error_exit "Debootstrap for installer root failed."

log "INFO" "Installer root debootstrap complete."

# Chroot environment setup for the installer
log "INFO" "Setting up chroot environment for installer root..."
mount --bind /dev "${INSTALLER_ROOT}/dev" || error_exit "Failed to bind mount /dev"
mount --bind /proc "${INSTALLER_ROOT}/proc" || error_exit "Failed to bind mount /proc"
mount --bind /sys "${INSTALLER_ROOT}/sys" || error_exit "Failed to bind mount /sys"
mount --bind /run "${INSTALLER_ROOT}/run" || error_exit "Failed to bind mount /run"
cp /etc/resolv.conf "${INSTALLER_ROOT}/etc/resolv.conf" || error_exit "Failed to copy resolv.conf"

# Copy installer scripts and config into chroot
mkdir -p "${INSTALLER_ROOT}/hardened-installer/scripts" "${INSTALLER_ROOT}/hardened-installer/templates" || error_exit "Failed to create installer script directories in chroot"
cp "${CONFIG_FILE}" "${INSTALLER_ROOT}/hardened-installer/hardened-os.conf" || error_exit "Failed to copy hardened-os.conf to chroot"
cp ./scripts/*.sh "${INSTALLER_ROOT}/hardened-installer/scripts/" || error_exit "Failed to copy scripts to chroot"
cp ./templates/* "${INSTALLER_ROOT}/hardened-installer/templates/" || error_exit "Failed to copy templates to chroot"
cp -r ./profiles "${INSTALLER_ROOT}/hardened-installer/" || error_exit "Failed to copy profiles to chroot"

# Copy pre-built artifacts into the installer root
if [ "${PREBUILD_CUSTOM_KERNEL}" -eq 1 ]; then
  log "INFO" "Copying pre-built kernel .deb packages into installer root..."
  mkdir -p "${INSTALLER_ROOT}${KERNEL_DEB_DIR_CUSTOM}" || error_exit "Failed to create kernel debs dir in installer root."
  cp "${PREBUILD_KERNEL_DEBS_DIR}"/*.deb "${INSTALLER_ROOT}${KERNEL_DEB_DIR_CUSTOM}/" || error_exit "Failed to copy pre-built kernel debs."
fi

if [ "${PREBUILD_ACCEL_LIBS}" -eq 1 ]; then
  log "INFO" "Copying pre-built accelerated libraries tarball into installer root..."
  mkdir -p "${INSTALLER_ROOT}/opt/prebuilt-accel" || error_exit "Failed to create prebuilt-artifacts dir in installer root."
  cp "${PREBUILD_ACCEL_LIBS_TAR}" "${INSTALLER_ROOT}/opt/prebuilt-accel/" || error_exit "Failed to copy pre-built accelerated libs tarball."
fi

if [ -f "ffmpeg.wasm" ]; then
  log "INFO" "Copying pre-built FFmpeg Wasm module into installer root..."
  mkdir -p "${INSTALLER_ROOT}/opt/media-processor/wasm" || error_exit "Failed to create wasm dir in installer root."
  cp ffmpeg.wasm "${INSTALLER_ROOT}/opt/media-processor/wasm/" || error_exit "Failed to copy ffmpeg.wasm."
fi

if [ -f "${PREBUILD_AUDIO_DRIVERS_TAR}" ]; then
  log "INFO" "Copying pre-built hardened audio drivers tarball into installer root..."
  mkdir -p "${INSTALLER_ROOT}/opt/prebuilt-drivers" || error_exit "Failed to create prebuilt-drivers dir in installer root."
  cp "${PREBUILD_AUDIO_DRIVERS_TAR}" "${INSTALLER_ROOT}/opt/prebuilt-drivers/" || error_exit "Failed to copy pre-built audio drivers tarball."
fi

if [ -f "${PREBUILD_VIDEO_DRIVERS_TAR}" ]; then
  log "INFO" "Copying pre-built hardened video drivers tarball into installer root..."
  mkdir -p "${INSTALLER_ROOT}/opt/prebuilt-drivers" || error_exit "Failed to create prebuilt-drivers dir in installer root."
  cp "${PREBUILD_VIDEO_DRIVERS_TAR}" "${INSTALLER_ROOT}/opt/prebuilt-drivers/" || error_exit "Failed to copy pre-built video drivers tarball."
fi

if [ -f "IMAGEHARDER_reference/image_harden/target/release/image_harden_cli" ]; then
  log "INFO" "Copying pre-built ImageHarden CLI into installer root..."
  mkdir -p "${INSTALLER_ROOT}/usr/local/bin" || error_exit "Failed to create /usr/local/bin in installer root."
  cp "IMAGEHARDER_reference/image_harden/target/release/image_harden_cli" "${INSTALLER_ROOT}/usr/local/bin/" || error_exit "Failed to copy image_harden_cli."
fi

log "INFO" "Copying Systemd, Sysctl, and other profiles into installer root..."
mkdir -p "${INSTALLER_ROOT}/etc/systemd/system" || error_exit "Failed to create systemd dir in installer root."
cp systemd/*.service "${INSTALLER_ROOT}/etc/systemd/system/" || error_exit "Failed to copy .service files."
cp systemd/*.timer "${INSTALLER_ROOT}/etc/systemd/system/" || error_exit "Failed to copy .timer files."

mkdir -p "${INSTALLER_ROOT}/etc/seccomp" || error_exit "Failed to create seccomp dir in installer root."
cp "seccomp-profile.json" "${INSTALLER_ROOT}/etc/seccomp/" || error_exit "Failed to copy seccomp-profile.json."

mkdir -p "${INSTALLER_ROOT}/etc/sysctl.d" || error_exit "Failed to create sysctl.d dir in installer root."
cp "templates/99-media-hardening.conf" "${INSTALLER_ROOT}/etc/sysctl.d/" || error_exit "Failed to copy 99-media-hardening.conf."

mkdir -p "${INSTALLER_ROOT}/usr/share/applications" || error_exit "Failed to create applications dir in installer root."
cp desktop/*.desktop "${INSTALLER_ROOT}/usr/share/applications/" || error_exit "Failed to copy .desktop files."

cp scripts/update-mime-types.sh "${INSTALLER_ROOT}/scripts/" || error_exit "Failed to copy update-mime-types.sh."
cp scripts/randomize_mac.sh "${INSTALLER_ROOT}/scripts/" || error_exit "Failed to copy randomize_mac.sh."
cp scripts/ping_target.sh "${INSTALLER_ROOT}/scripts/" || error_exit "Failed to copy ping_target.sh."


log "INFO" "Copying desktop and MIME-type scripts into installer root..."
mkdir -p "${INSTALLER_ROOT}/usr/share/applications" || error_exit "Failed to create applications dir in installer root."
cp desktop/*.desktop "${INSTALLER_ROOT}/usr/share/applications/" || error_exit "Failed to copy .desktop files."
cp scripts/update-mime-types.sh "${INSTALLER_ROOT}/scripts/" || error_exit "Failed to copy update-mime-types.sh."

log "INFO" "Copying ping_target script and systemd units into installer root..."
mkdir -p "${INSTALLER_ROOT}/hardened-installer/systemd" || error_exit "Failed to create systemd dir for ping_target in installer root."
cp systemd/ping_target.service "${INSTALLER_ROOT}/hardened-installer/systemd/" || error_exit "Failed to copy ping_target.service."
cp systemd/ping_target.timer "${INSTALLER_ROOT}/hardened-installer/systemd/" || error_exit "Failed to copy ping_target.timer."
cp scripts/ping_target.sh "${INSTALLER_ROOT}/hardened-installer/scripts/" || error_exit "Failed to copy ping_target.sh."


log "INFO" "Copying local debs into installer root..."
mkdir -p "${INSTALLER_ROOT}/debs" || error_exit "Failed to create debs dir in installer root."
cp debs/*.deb "${INSTALLER_ROOT}/debs/" || error_exit "Failed to copy .deb files."



# Prepare CHROOT_INSTALLER_COMMANDS
cat <<EOF > "${INSTALLER_ROOT}/tmp/installer_chroot_script.sh"
#!/usr/bin/env bash
set -Eeuo pipefail

log_chroot_iso() {
  local level="\${1}"
  local message="\${2}"
  local timestamp
  timestamp=\$(date +"%Y-%m-%d %H:%M:%S")
  echo "[CHROOT-ISO] [\${timestamp}] [\${level}] \${message}"
}

error_exit_chroot_iso() {
  log_chroot_iso "ERROR" "\${1}" >&2
  exit 1
}

log_chroot_iso "INFO" "Starting post-debootstrap configurations inside installer chroot."

# Install necessary packages for TUI installer
log_chroot_iso "INFO" "Installing packages for TUI installer..."
export DEBIAN_FRONTEND=noninteractive
apt-get update || error_exit_chroot_iso "apt-get update failed inside installer chroot"
# We only need minimal tools for the installer environment
apt-get install -y --no-install-recommends \
  dialog \
  cryptsetup \
  grub-efi-amd64 \
  parted \
  dosfstools \
  efibootmgr \
  sgdisk \
  xorriso \
  mtools \
  uuid-runtime \
  eatmydata \
  procps \
  iproute2 \
  net-tools \
  locales \
  vim \
  curl \
  wget \
  gzip \
  bzip2 \
  xz-utils \
  fdisk \
  e2fsprogs || error_exit_chroot_iso "Failed to install packages for installer chroot"

# Configure locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Setup tty1 to automatically start tui-installer.sh
log_chroot_iso "INFO" "Configuring init to launch tui-installer.sh..."
systemctl set-default multi-user.target
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<SYSTEMD_OVERRIDE > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/unshare --mount --cgroup --pid --fork -- /bin/bash -c "cd /hardened-installer && /usr/bin/env bash scripts/tui-installer.sh --config hardened-os.conf </dev/tty1 >/dev/tty1 2>&1"
StandardInput=tty
StandardOutput=tty
SYSTEMD_OVERRIDE
systemctl daemon-reload

log_chroot_iso "INFO" "Post-debootstrap configurations inside installer chroot complete."
EOF

chmod +x "${INSTALLER_ROOT}/tmp/installer_chroot_script.sh" || error_exit "Failed to make installer chroot script executable"

log "INFO" "Executing installer chroot script..."
chroot "${INSTALLER_ROOT}" /tmp/installer_chroot_script.sh || error_exit "Installer chroot script execution failed"

# Clean up chroot script
rm "${INSTALLER_ROOT}/tmp/installer_chroot_script.sh" || log "WARN" "Failed to remove installer chroot script."

log "INFO" "Chroot environment setup for installer complete."

# --- Generate GRUB configuration for the ISO ---
log "INFO" "Generating GRUB configuration for the ISO..."
GRUB_EFI_DIR="${INSTALLER_ROOT}/boot/efi/EFI/BOOT"
mkdir -p "${GRUB_EFI_DIR}" || error_exit "Failed to create GRUB EFI directory"
cp "${INSTALLER_ROOT}/usr/lib/grub/x86_64-efi/grub.efi" "${GRUB_EFI_DIR}/bootx64.efi" || error_exit "Failed to copy grubx64.efi"

# Create a minimal grub.cfg for the ISO to boot into the installer environment
cat <<EOT > "${GRUB_EFI_DIR}/grub.cfg"
set default="0"
set timeout="5"

menuentry "Start Hardened Installer" {
    # This assumes the installer's kernel and initrd are located at /boot/vmlinuz and /boot/initrd.img
    # within the ISO filesystem. In our case, the installer root itself will be the squashfs root.
    # So we boot to the systemd init in the installer root.
    # The systemd override will launch tui-installer.sh
    linux /boot/vmlinuz root=/dev/ram0 rw init=/sbin/init quiet
    initrd /boot/initrd.img
}
EOT

# Ensure the kernel and initramfs are present in the installer root /boot
# These are generated by update-initramfs and installed with the linux-image package
log "INFO" "Copying kernel and initramfs to ISO boot directory..."
# If custom kernel was pre-built, extract from .deb and copy
if [ "${PREBUILD_CUSTOM_KERNEL}" -eq 1 ]; then
  # Find the latest kernel image .deb from the pre-built debs
  KERNEL_DEB_FILE=$(find "${PREBUILD_KERNEL_DEBS_DIR}" -name "linux-image-*.deb" | head -n 1)
  if [ -z "$KERNEL_DEB_FILE" ]; then
      error_exit "No pre-built kernel image .deb found in ${PREBUILD_KERNEL_DEBS_DIR}."
  fi

  TMP_KERNEL_EXTRACT_DIR="${ISO_BUILD_DIR}/tmp_kernel_extract"
  mkdir -p "${TMP_KERNEL_EXTRACT_DIR}" || error_exit "Failed to create temp kernel extract dir."
  dpkg -x "${KERNEL_DEB_FILE}" "${TMP_KERNEL_EXTRACT_DIR}" || error_exit "Failed to extract kernel deb: ${KERNEL_DEB_FILE}"
  
  # Find the actual kernel image and initrd from the extracted deb
  KERNEL_IMAGE_PATH=$(find "${TMP_KERNEL_EXTRACT_DIR}/boot" -name "vmlinuz-*" | head -n 1)
  INITRD_IMAGE_PATH=$(find "${TMP_KERNEL_EXTRACT_DIR}/boot" -name "initrd.img-*" | head -n 1)

  if [ -z "$KERNEL_IMAGE_PATH" ] || [ -z "$INITRD_IMAGE_PATH" ]; then
      error_exit "Could not find vmlinuz or initrd.img in extracted kernel deb."
  fi

  cp "${KERNEL_IMAGE_PATH}" "${INSTALLER_ROOT}/boot/vmlinuz" || error_exit "Failed to copy custom kernel image"
  cp "${INITRD_IMAGE_PATH}" "${INSTALLER_ROOT}/boot/initrd.img" || error_exit "Failed to copy custom initramfs image"
  rm -rf "${TMP_KERNEL_EXTRACT_DIR}" || log "WARN" "Failed to remove temp kernel extract dir."
else
  # Fallback to stock kernel/initramfs. This assumes debootstrap installed a minimal kernel.
  cp "${INSTALLER_ROOT}/boot/vmlinuz"* "${INSTALLER_ROOT}/boot/vmlinuz" || error_exit "Failed to copy kernel"
  cp "${INSTALLER_ROOT}/boot/initrd.img"* "${INSTALLER_ROOT}/boot/initrd.img" || error_exit "Failed to copy initrd.img"
fi


# --- Generate ISO using xorriso ---
log "INFO" "Generating bootable EFI ISO: ${OUTPUT_ISO}..."
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "HARDENED_INSTALLER" \
  -eltorito-boot boot/efi/EFI/BOOT/bootx64.efi \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --eltorito-catalog boot/eltorito.cat \
  -output "${OUTPUT_ISO}" \
  -graft-points \
    "/boot/efi=${INSTALLER_ROOT}/boot/efi" \
    "/hardened-installer=${INSTALLER_ROOT}/hardened-installer" \
    "/boot/vmlinuz=${INSTALLER_ROOT}/boot/vmlinuz" \
    "/boot/initrd.img=${INSTALLER_ROOT}/boot/initrd.img" || error_exit "Failed to create ISO"

log "INFO" "ISO generation complete: ${OUTPUT_ISO}"

# --- Cleanup ---
log "INFO" "Cleaning up temporary directories..."
# Unmount bind mounts
umount "${INSTALLER_ROOT}/dev" || true # Ignore errors if not mounted
umount "${INSTALLER_ROOT}/proc" || true
umount "${INSTALLER_ROOT}/sys" || true
umount "${INSTALLER_ROOT}/run" || true

rm -rf "${ISO_BUILD_DIR}" || log "WARN" "Failed to remove ISO build directory ${ISO_BUILD_DIR}"
rm -rf "${PREBUILD_KERNEL_DEBS_DIR}" || log "WARN" "Failed to remove prebuilt kernel debs dir."
rm -rf "${PREBUILD_ACCEL_LIBS_INSTALL_DIR}" || log "WARN" "Failed to remove prebuilt accel libs install dir."
rm -f "${PREBUILD_ACCEL_LIBS_TAR}" || log "WARN" "Failed to remove prebuilt accel libs tarball."

log "INFO" "ISO build process finished."

exit 0

