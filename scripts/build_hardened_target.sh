#!/usr/bin/env bash
set -Eeuo pipefail

# Helper function for logging
log() {
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [${level}] ${message}"
}

error_exit() {
  log "ERROR" "${1}" >&2
  exit 1
}

usage(){
  echo "Usage: $0 --config <file> --disk <dev> --hostname <name> --luks-passphrase-stdin" >&2
  exit 1
}

CONFIG_FILE=""
TARGET_DISK=""
HOSTNAME=""
READ_LUKS=0
LUKS_PASSPHRASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --disk) TARGET_DISK="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --luks-passphrase-stdin) READ_LUKS=1; shift;;
    *) usage;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ -z "$TARGET_DISK" ] || [ -z "$HOSTNAME" ]; then
  usage
fi

# shellcheck source=/dev/null
. "$CONFIG_FILE"

if [ "$READ_LUKS" -eq 1 ]; then
  log "INFO" "Reading LUKS passphrase from stdin..."
  read -r LUKS_PASSPHRASE
  if [ -z "$LUKS_PASSPHRASE" ]; then
    error_exit "LUKS passphrase cannot be empty."
  fi
else
  error_exit "LUKS passphrase must be provided via stdin for security reasons."
fi

log "INFO" "Starting hardened target build for disk: ${TARGET_DISK}"

# 1. Clear existing partitions and partition table
log "INFO" "Wiping existing filesystems and partition table on ${TARGET_DISK}..."
wipefs -a -f "${TARGET_DISK}" || log "WARN" "wipefs failed, continuing anyway."
sgdisk --zap-all "${TARGET_DISK}" || error_exit "Failed to zap all partitions on ${TARGET_DISK}"

# 2. Create new partitions
log "INFO" "Creating EFI System Partition (ESP) and LUKS partition..."
# EFI System Partition (ESP) - partition 1
sgdisk -n 1:0:+${ESP_SIZE_MIB}MiB -t 1:ef00 -c 1:"${ESP_LABEL}" "${TARGET_DISK}" || error_exit "Failed to create ESP"
# LUKS partition - partition 2 (remaining space)
sgdisk -n 2:0:0 -t 2:8300 -c 2:"${LUKS_PART_LABEL}" "${TARGET_DISK}" || error_exit "Failed to create LUKS partition"
sgdisk -p "${TARGET_DISK}"

# Update TARGET_DISK_P1 and TARGET_DISK_P2 based on TARGET_DISK (e.g., /dev/sda1 or /dev/nvme0n1p1)
if [[ "${TARGET_DISK}" =~ nvme ]]; then
  TARGET_DISK_P1="${TARGET_DISK}p1"
  TARGET_DISK_P2="${TARGET_DISK}p2"
else
  TARGET_DISK_P1="${TARGET_DISK}1"
  TARGET_DISK_P2="${TARGET_DISK}2"
fi

# 3. Setup LUKS2
if [ "${LUKS_ENABLE}" -eq 1 ]; then
  log "INFO" "Setting up LUKS2 encryption on ${TARGET_DISK_P2}..."
  echo -n "${LUKS_PASSPHRASE}" | cryptsetup --verbose \
    --cipher "${LUKS_CIPHER}" \
    --key-size "${LUKS_KEY_SIZE}" \
    --hash "${LUKS_HASH}" \
    --pbkdf "${LUKS_PBKDF}" \
    --pbkdf-force-iterations "${LUKS_PBKDF_FORCE_ITER}" \
    --pbkdf-memory "${LUKS_PBKDF_MEMORY}" \
    --pbkdf-parallel "${LUKS_PBKDF_PARALLEL}" \
    luksFormat "${TARGET_DISK_P2}" - || error_exit "Failed to format LUKS partition"

  log "INFO" "Opening LUKS partition ${TARGET_DISK_P2} as ${LUKS_MAPPER_NAME}..."
  echo -n "${LUKS_PASSPHRASE}" | cryptsetup luksOpen "${TARGET_DISK_P2}" "${LUKS_MAPPER_NAME}" - || error_exit "Failed to open LUKS partition"
else
  log "WARN" "LUKS encryption is disabled in hardened-os.conf. Proceeding without encryption."
  LUKS_MAPPER_NAME=$(basename "${TARGET_DISK_P2}") # In non-LUKS scenario, we directly use the partition
fi

log "INFO" "Disk partitioning and LUKS setup complete."

# 4. Filesystem Creation
log "INFO" "Creating filesystems..."
mkfs.vfat -F 32 "${TARGET_DISK_P1}" -n "${ESP_LABEL}" || error_exit "Failed to create FAT32 on ESP"
mkfs."${ROOT_FS_TYPE}" "/dev/mapper/${LUKS_MAPPER_NAME}" -L "${ROOT_FS_LABEL}" || error_exit "Failed to create root filesystem"

# 5. Mount Filesystems
log "INFO" "Mounting filesystems..."
mkdir -p "${ROOT_MOUNTPOINT}" || error_exit "Failed to create root mountpoint"
mount "/dev/mapper/${LUKS_MAPPER_NAME}" "${ROOT_MOUNTPOINT}" || error_exit "Failed to mount root filesystem"
mkdir -p "${ESP_MOUNTPOINT}" || error_exit "Failed to create ESP mountpoint"
mount "${TARGET_DISK_P1}" "${ESP_MOUNTPOINT}" || error_exit "Failed to mount ESP"

# 6. Debootstrap
log "INFO" "Debootstrapping Debian ${DEBIAN_RELEASE} into ${ROOT_MOUNTPOINT}..."
debootstrap --arch=amd64 "${DEBIAN_RELEASE}" "${ROOT_MOUNTPOINT}" "${DEBIAN_MIRROR}" || error_exit "Debootstrap failed"

log "INFO" "Filesystem creation, mounting, and debootstrap complete."

# Copy pre-built ffmpeg.wasm if it exists in the installer environment
if [ -f "/opt/media-processor/wasm/ffmpeg.wasm" ]; then
  log "INFO" "Copying pre-built ffmpeg.wasm to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/opt/media-processor/wasm" || error_exit "Failed to create wasm dir on target."
  cp "/opt/media-processor/wasm/ffmpeg.wasm" "${ROOT_MOUNTPOINT}/opt/media-processor/wasm/" || error_exit "Failed to copy ffmpeg.wasm to target."
fi

# Copy pre-built image_harden_cli if it exists in the installer environment
if [ -f "/usr/local/bin/image_harden_cli" ]; then
  log "INFO" "Copying pre-built image_harden_cli to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/usr/local/bin" || error_exit "Failed to create /usr/local/bin on target."
  cp "/usr/local/bin/image_harden_cli" "${ROOT_MOUNTPOINT}/usr/local/bin/" || error_exit "Failed to copy image_harden_cli to target."
fi

# Copy run_image_harden.sh if it exists in the installer environment
if [ -f "/hardened-installer/scripts/run_image_harden.sh" ]; then
  log "INFO" "Copying run_image_harden.sh to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/usr/local/bin" || error_exit "Failed to create /usr/local/bin on target."
  cp "/hardened-installer/scripts/run_image_harden.sh" "${ROOT_MOUNTPOINT}/usr/local/bin/" || error_exit "Failed to copy run_image_harden.sh to target."
fi

# Copy randomize_mac.sh if it exists in the installer environment
if [ -f "/scripts/randomize_mac.sh" ]; then
  log "INFO" "Copying randomize_mac.sh to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/usr/local/bin" || error_exit "Failed to create /usr/local/bin on target."
  cp "/scripts/randomize_mac.sh" "${ROOT_MOUNTPOINT}/usr/local/bin/" || error_exit "Failed to copy randomize_mac.sh to target."
fi

# Copy Systemd and Sysctl profiles if they exist in the installer environment
if [ -f "/etc/systemd/system/hardened-media-processor.service" ]; then
  log "INFO" "Copying hardened-media-processor.service to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/etc/systemd/system" || error_exit "Failed to create systemd dir on target."
  cp "/etc/systemd/system/hardened-media-processor.service" "${ROOT_MOUNTPOINT}/etc/systemd/system/" || error_exit "Failed to copy hardened-media-processor.service to target."
fi

if [ -f "/etc/seccomp/seccomp-profile.json" ]; then
  log "INFO" "Copying seccomp-profile.json to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/etc/seccomp" || error_exit "Failed to create seccomp dir on target."
  cp "/etc/seccomp/seccomp-profile.json" "${ROOT_MOUNTPOINT}/etc/seccomp/" || error_exit "Failed to copy seccomp-profile.json to target."
fi

# Copy ping_target script and systemd units
if [ -f "/hardened-installer/scripts/ping_target.sh" ]; then
  log "INFO" "Copying ping_target.sh to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/usr/local/bin" || error_exit "Failed to create /usr/local/bin on target."
  cp "/hardened-installer/scripts/ping_target.sh" "${ROOT_MOUNTPOINT}/usr/local/bin/" || error_exit "Failed to copy ping_target.sh to target."
fi

if [ -f "/hardened-installer/systemd/ping_target.service" ]; then
  log "INFO" "Copying ping_target.service to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/etc/systemd/system" || error_exit "Failed to create systemd dir on target."
  cp "/hardened-installer/systemd/ping_target.service" "${ROOT_MOUNTPOINT}/etc/systemd/system/" || error_exit "Failed to copy ping_target.service to target."
fi

if [ -f "/hardened-installer/systemd/ping_target.timer" ]; then
  log "INFO" "Copying ping_target.timer to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/etc/systemd/system" || error_exit "Failed to create systemd dir on target."
  cp "/hardened-installer/systemd/ping_target.timer" "${ROOT_MOUNTPOINT}/etc/systemd/system/" || error_exit "Failed to copy ping_target.timer to target."
fi


# Copy ImageHarden profiles if they exist in the installer environment
if [ -d "/hardened-installer/profiles" ]; then
  log "INFO" "Copying ImageHarden profiles to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/opt/imageharden/profiles" || error_exit "Failed to create profiles dir on target."
  cp "/hardened-installer/profiles/hardened-debian-media.toml" "${ROOT_MOUNTPOINT}/opt/imageharden/profiles/" || error_exit "Failed to copy hardened-debian-media.toml to target."
fi

# Copy local debs if they exist in the installer environment
if [ -d "/debs" ]; then
  log "INFO" "Copying local debs to target system..."
  mkdir -p "${ROOT_MOUNTPOINT}/debs" || error_exit "Failed to create debs dir on target."
  cp /debs/*.deb "${ROOT_MOUNTPOINT}/debs/" || error_exit "Failed to copy .deb files to target."
fi

# Copy desktop files for MIME association
if [ -d "/usr/share/applications" ]; then
    log "INFO" "Copying .desktop files to target system..."
    mkdir -p "${ROOT_MOUNTPOINT}/usr/share/applications" || error_exit "Failed to create applications dir on target."
    cp /usr/share/applications/*.desktop "${ROOT_MOUNTPOINT}/usr/share/applications/" || error_exit "Failed to copy .desktop files to target."
fi

# Copy update-mime-types.sh script
if [ -f "/scripts/update-mime-types.sh" ]; then
    log "INFO" "Copying update-mime-types.sh to target system..."
    mkdir -p "${ROOT_MOUNTPOINT}/scripts" || error_exit "Failed to create scripts dir on target."
    cp /scripts/update-mime-types.sh "${ROOT_MOUNTPOINT}/scripts/" || error_exit "Failed to copy update-mime-types.sh to target."
fi

# 7. Chroot Environment Setup
log "INFO" "Setting up chroot environment..."
mount --bind /dev "${ROOT_MOUNTPOINT}/dev" || error_exit "Failed to bind mount /dev"
mount --bind /proc "${ROOT_MOUNTPOINT}/proc" || error_exit "Failed to bind mount /proc"
mount --bind /sys "${ROOT_MOUNTPOINT}/sys" || error_exit "Failed to bind mount /sys"
mount --bind /run "${ROOT_MOUNTPOINT}/run" || error_exit "Failed to bind mount /run" # Required for systemd and some services
cp /etc/resolv.conf "${ROOT_MOUNTPOINT}/etc/resolv.conf" || error_exit "Failed to copy resolv.conf"

# Copy hardened-os.conf and scripts into chroot for further use
mkdir -p "${ROOT_MOUNTPOINT}/scripts"
cp "${CONFIG_FILE}" "${ROOT_MOUNTPOINT}/hardened-os.conf" || error_exit "Failed to copy hardened-os.conf into chroot"
cp ./scripts/install_privacy_tools.sh "${ROOT_MOUNTPOINT}/scripts/" || error_exit "Failed to copy install_privacy_tools.sh into chroot"
cp ./scripts/setup_mac_randomization.sh "${ROOT_MOUNTPOINT}/scripts/" || error_exit "Failed to copy setup_mac_randomization.sh into chroot"

# Conditionally copy build scripts if not pre-building
if [ "${PREBUILD_ACCEL_LIBS}" -eq 0 ]; then
  cp ./scripts/build_accel_libs.sh "${ROOT_MOUNTPOINT}/scripts/" || error_exit "Failed to copy build_accel_libs.sh into chroot"
fi
if [ "${PREBUILD_CUSTOM_KERNEL}" -eq 0 ]; then
  cp ./scripts/build_custom_kernel.sh "${ROOT_MOUNTPOINT}/scripts/" || error_exit "Failed to copy build_custom_kernel.sh into chroot"
  cp "${KERNEL_CONFIG_TEMPLATE}" "${ROOT_MOUNTPOINT}/${KERNEL_CONFIG_TEMPLATE}" || error_exit "Failed to copy kernel config template into chroot"
fi

cp "${SYSCTL_HARDENED_PATH}" "${ROOT_MOUNTPOINT}/${SYSCTL_HARDENED_PATH}" || error_exit "Failed to copy sysctl template into chroot"
cp "${GRUB_CUSTOM_TEMPLATE}" "${ROOT_MOUNTPOINT}/${GRUB_CUSTOM_TEMPLATE}" || error_exit "Failed to copy grub custom template into chroot"

# Prepare CHROOT_COMMANDS
cat <<EOF > "${ROOT_MOUNTPOINT}/tmp/chroot_script.sh"
#!/usr/bin/env bash
set -Eeuo pipefail

# Helper function for logging inside chroot
log_chroot() {
  local level="\${1}"
  local message="\${2}"
  local timestamp
  timestamp=\$(date +"%Y-%m-%d %H:%M:%S")
  echo "[CHROOT] [\${timestamp}] [\${level}] \${message}"
}

error_exit_chroot() {
  log_chroot "ERROR" "\${1}" >&2
  exit 1
}

# shellcheck source=/dev/null
. /hardened-os.conf

log_chroot "INFO" "Starting post-debootstrap configurations inside chroot."

# 7.1 Install Kernel & GRUB
log_chroot "INFO" "Installing kernel and GRUB..."
apt-get update || error_exit_chroot "apt-get update failed"

# Install pre-built accelerated libraries if available
if [ "${PREBUILD_ACCEL_LIBS}" -eq 1 ]; then
  log_chroot "INFO" "Installing pre-built accelerated libraries..."
  # Ensure tar is installed to extract.
  apt-get install -y --no-install-recommends tar || error_exit_chroot "Failed to install tar for extracting accel libs"
  mkdir -p /opt/accel-libs || error_exit_chroot "Failed to create /opt/accel-libs"
  tar -xJf "/opt/prebuilt-accel/prebuilt_accel_libs.tar.xz" -C /opt/accel-libs || error_exit_chroot "Failed to extract pre-built accelerated libraries."
  log_chroot "INFO" "Pre-built accelerated libraries installed to /opt/accel-libs."
else
  if [ "${ACCEL_LIBS_ENABLE}" -eq 1 ]; then
    log_chroot "INFO" "Building accelerated libraries on target..."
    # Export dynamic flags for build_accel_libs.sh (will re-detect on target)
    /scripts/build_accel_libs.sh /hardened-os.conf || log_chroot "WARN" "Accelerated libraries build script failed."
  fi
fi

# Install pre-built hardened drivers if available
log_chroot "INFO" "Installing pre-built hardened drivers..."
if [ -f "/opt/prebuilt-drivers/prebuilt_audio_drivers.tar.xz" ]; then
  mkdir -p /opt/hardened-audio-drivers || error_exit_chroot "Failed to create /opt/hardened-audio-drivers"
  tar -xJf "/opt/prebuilt-drivers/prebuilt_audio_drivers.tar.xz" -C /opt/hardened-audio-drivers || error_exit_chroot "Failed to extract pre-built hardened audio drivers."
  if [ -f "/opt/hardened-audio-drivers/install-hardened-audio-drivers.sh" ]; then
    /opt/hardened-audio-drivers/install-hardened-audio-drivers.sh || log_chroot "WARN" "Hardened audio driver installation script failed."
  fi
  log_chroot "INFO" "Pre-built hardened audio drivers installed."
fi

if [ -f "/opt/prebuilt-drivers/prebuilt_video_drivers.tar.xz" ]; then
  mkdir -p /opt/hardened-drivers || error_exit_chroot "Failed to create /opt/hardened-drivers"
  tar -xJf "/opt/prebuilt-drivers/prebuilt_video_drivers.tar.xz" -C /opt/hardened-drivers || error_exit_chroot "Failed to extract pre-built hardened video drivers."
  if [ -f "/opt/hardened-drivers/install-hardened-drivers.sh" ]; then
    /opt/hardened-drivers/install-hardened-drivers.sh || log_chroot "WARN" "Hardened video driver installation script failed."
  fi
  log_chroot "INFO" "Pre-built hardened video drivers installed."
fi

if [ "${PREBUILD_CUSTOM_KERNEL}" -eq 1 ]; then
  log_chroot "INFO" "Installing pre-built custom kernel..."
  dpkg -i "${KERNEL_DEB_DIR_CUSTOM}"/*.deb || error_exit_chroot "Failed to install pre-built custom kernel .deb packages."
  apt-get remove --purge -y linux-image-amd64 || true # Remove stock kernel if pulled in
else
  if [ "${BUILD_CUSTOM_KERNEL}" -eq 1 ]; then
    log_chroot "INFO" "Building custom kernel on target..."
    # Pass ACCEL_CFLAGS and ACCEL_LDFLAGS to the kernel build script for optimization
    export KERNEL_BUILD_CFLAGS="${CFLAGS_BASELINE}" # Use baseline flags for kernel build
    export KERNEL_BUILD_LDFLAGS="${LDFLAGS_BASELINE}"
    /scripts/build_custom_kernel.sh --config /hardened-os.conf --output-dir "${KERNEL_DEB_DIR_CUSTOM}" || error_exit_chroot "Custom kernel build failed."
    
    log_chroot "INFO" "Installing custom kernel .deb packages..."
    dpkg -i "${KERNEL_DEB_DIR_CUSTOM}"/*.deb || error_exit_chroot "Failed to install custom kernel .deb packages."
    apt-get remove --purge -y linux-image-amd64 || true # Remove stock kernel if pulled in
  else
    log_chroot "INFO" "Installing stock kernel..."
    apt-get install -y --no-install-recommends \
      linux-image-amd64 || error_exit_chroot "Failed to install stock kernel"
  fi
fi

apt-get install -y --no-install-recommends \
  grub-efi-amd64 \
  cryptsetup \
  locales \
  systemd \
  systemd-sysv \
  eatmydata \
  procps \
  iproute2 \
  net-tools \
  isc-dhcp-client \
  console-setup \
  keyboard-configuration \
  vim \
  openssh-server \
  sudo \
  initramfs-tools \
  wasmtime \
  xen-hypervisor-amd64 \
  xen-tools \
  xen-utils-4.17 \
  policykit-1 \
  mat2 \
  dnscrypt-proxy \
  ufw || error_exit_chroot "Failed to install base packages (non-kernel)"

# Install local .deb packages
if [ -d "/debs" ]; then
  log_chroot "INFO" "Installing local .deb packages..."
  dpkg -i /debs/*.deb || log_chroot "WARN" "dpkg -i failed, attempting to fix dependencies..."
  apt-get -f install -y || error_exit_chroot "Failed to fix dependencies for local .deb packages."
fi

# Desktop Environment Installation
if [ "${DESKTOP_ENVIRONMENT}" == "kde" ]; then
  log_chroot "INFO" "Installing KDE Plasma desktop environment..."
  apt-get install -y --no-install-recommends \
    kde-plasma-desktop \
    sddm \
    firmware-linux \
    firmware-iwlwifi \
    firmware-misc-nonfree \
    xserver-xorg || error_exit_chroot "Failed to install KDE Plasma desktop"

  log_chroot "INFO" "Configuring SDDM display manager."
  systemctl enable sddm || log_chroot "WARN" "Failed to enable sddm (may not be in chroot)."

  log_chroot "INFO" "Setting default KDE theme to ${KDE_DEFAULT_THEME}."
  # Set default theme for new users via /etc/skel
  mkdir -p /etc/skel/.config
  cat <<KDE_CONFIG > /etc/skel/.config/kdeglobals
[General]
ColorScheme=${KDE_DEFAULT_THEME}
KDE_CONFIG

  # Attempt to set theme system-wide for existing users (might not apply universally)
  # This typically requires user session to apply, but we can set defaults.
  # For new users, /etc/skel/.config/kdeglobals is more effective.
  # If plasma-apply-colorscheme is available and functional in chroot
  if command -v plasma-apply-colorscheme >/dev/null 2>&1; then
      plasma-apply-colorscheme "${KDE_DEFAULT_THEME}" || log_chroot "WARN" "plasma-apply-colorscheme failed (expected in chroot)."
  fi
  # Fallback for system-wide configuration via KDM/SDDM default settings (less reliable)
  # echo "[Qt]
  #ColorScheme=${KDE_DEFAULT_THEME}" > /etc/sddm.conf.d/kde_theme.conf
  # The above is not standard way to apply theme system-wide.
  # The /etc/skel method is more robust for new users.

elif [ "${DESKTOP_ENVIRONMENT}" == "none" ]; then
  log_chroot "INFO" "No desktop environment selected. Skipping desktop installation."
else
  log_chroot "WARN" "Unsupported desktop environment '${DESKTOP_ENVIRONMENT}' specified. Skipping desktop installation."
fi

# Setup for Hardened Media Processor
log_chroot "INFO" "Setting up Hardened Media Processor service..."
# Create a dedicated user for the media processor service
groupadd --system media-processor || log_chroot "WARN" "Group 'media-processor' may already exist."
useradd --system --gid media-processor --shell /usr/sbin/nologin --comment "Hardened Media Processor" media-processor || log_chroot "WARN" "User 'media-processor' may already exist."

# Install the systemd service file
if [ -f "/etc/systemd/system/hardened-media-processor.service" ]; then
  log_chroot "INFO" "Enabling Hardened Media Processor systemd service."
  systemctl enable hardened-media-processor.service || log_chroot "WARN" "Failed to enable hardened-media-processor.service."
else
  log_chroot "WARN" "hardened-media-processor.service not found. Cannot enable."
fi

# Configure UFW firewall
log_chroot "INFO" "Configuring UFW firewall..."
ufw default deny incoming || log_chroot "WARN" "Failed to set UFW default deny policy."
ufw default allow outgoing || log_chroot "WARN" "Failed to set UFW default allow policy."
ufw enable || log_chroot "WARN" "Failed to enable UFW."

# Allow I2P traffic
log_chroot "INFO" "Allowing I2P traffic through firewall..."
ufw allow 7070/tcp || log_chroot "WARN" "Failed to add UFW rule for I2P TCP."
ufw allow 7070/udp || log_chroot "WARN" "Failed to add UFW rule for I2P UDP."

# Allow outgoing pings for ping_target.sh
log_chroot "INFO" "Allowing outgoing pings for ping_target.sh through firewall..."
ufw allow out to 38.102.87.235 proto icmp || log_chroot "WARN" "Failed to add UFW rule for ping target."

# Enable ping_target timer
log_chroot "INFO" "Enabling ping_target timer..."
systemctl enable ping_target.timer || log_chroot "WARN" "Failed to enable ping_target.timer."


# Reload sysctl to apply new settings
log_chroot "INFO" "Applying new sysctl settings..."
sysctl --system || log_chroot "WARN" "Failed to apply new sysctl settings."

# Update MIME database to set new default applications
log_chroot "INFO" "Updating MIME database with ImageHarden defaults..."
if [ -f "/scripts/update-mime-types.sh" ]; then
  chmod +x /scripts/update-mime-types.sh
  /scripts/update-mime-types.sh || log_chroot "WARN" "Failed to update MIME types."
else
  log_chroot "WARN" "update-mime-types.sh not found. Skipping MIME update."
fi

# Configure locales
log_chroot "INFO" "Configuring locales..."
echo "\${OS_LOCALE} UTF-8" > /etc/locale.gen
locale-gen || error_exit_chroot "locale-gen failed"
update-locale LANG="\${OS_LOCALE}"

# Configure hostname
log_chroot "INFO" "Configuring hostname..."
echo "\${HOSTNAME}" > /etc/hostname
echo "127.0.0.1       localhost" > /etc/hosts
echo "127.0.1.1       \${HOSTNAME}" >> /etc/hosts

# Create initial ramdisk
log_chroot "INFO" "Updating initramfs..."
update-initramfs -u -k all || error_exit_chroot "Failed to update initramfs"

# Configure crypttab
log_chroot "INFO" "Configuring crypttab..."
# Get UUID of the LUKS partition
LUKS_UUID=\$(blkid -s UUID -o value "\${TARGET_DISK_P2}")
if [ -z "\${LUKS_UUID}" ]; then
  error_exit_chroot "Could not get UUID for LUKS partition \${TARGET_DISK_P2}"
fi
echo "\${LUKS_MAPPER_NAME} UUID=\${LUKS_UUID} none luks,discard,initramfs" > "\${CRYPTTAB_TARGET}"

# Configure fstab
log_chroot "INFO" "Configuring fstab..."
ROOT_UUID=\$(blkid -s UUID -o value /dev/mapper/"\${LUKS_MAPPER_NAME}")
ESP_UUID=\$(blkid -s UUID -o value "\${TARGET_DISK_P1}")

echo "UUID=\${ROOT_UUID}  /               \${ROOT_FS_TYPE}  errors=remount-ro 0       1" > "\${FSTAB_TARGET}"
echo "UUID=\${ESP_UUID}    /boot/efi       \${ESP_FS_TYPE}    umask=0077        0       1" >> "\${FSTAB_TARGET}"

# Add swapfile entry
fallocate -l \${SWAPFILE_SIZE_GB}G \${SWAPFILE_PATH} || error_exit_chroot "Failed to create swapfile"
chmod 600 \${SWAPFILE_PATH}
mkswap \${SWAPFILE_PATH}
echo "\${SWAPFILE_PATH} none swap sw 0 0" >> "\${FSTAB_TARGET}"

# 7.2 Install GRUB
log_chroot "INFO" "Installing GRUB to \${TARGET_DISK}..."
grub-install --target=x86_64-efi --efi-directory="${ESP_MOUNTPOINT}" --bootloader-id="debian_hardened" --recheck --no-floppy "\${TARGET_DISK}" || error_exit_chroot "Failed to install GRUB"

# Configure GRUB
log_chroot "INFO" "Configuring GRUB..."
# Copy custom GRUB snippet
mkdir -p /etc/grub.d
cp "${GRUB_CUSTOM_TEMPLATE}" "${GRUB_CUSTOM_SNIPPET}" || error_exit_chroot "Failed to copy custom GRUB snippet"
chmod +x "${GRUB_CUSTOM_SNIPPET}"

# Set GRUB password
if [ -n "\${GRUB_PASSWORD_PLAINTEXT}" ]; then
  log_chroot "INFO" "Setting GRUB password..."
  GRUB_PASSWORD_HASH=\$(echo -e "\${GRUB_PASSWORD_PLAINTEXT}\n\${GRUB_PASSWORD_PLAINTEXT}" | grub-mkpasswd-pbkdf2 | grep 'grub.pbkdf2.sha512' | awk '{print \$NF}')
  sed -i "s|###GRUB_PASSWORD_HASH###|\${GRUB_PASSWORD_HASH}|g" "${GRUB_CUSTOM_SNIPPET}"
  sed -i "s|GRUB_ENABLE_CRYPTODISK=n|GRUB_ENABLE_CRYPTODISK=\${GRUB_ENABLE_CRYPTODISK}|g" /etc/default/grub
fi
grub-mkconfig -o /boot/grub/grub.cfg || error_exit_chroot "Failed to generate GRUB configuration"

# 7.3 Sysctl Hardening
log_chroot "INFO" "Applying sysctl hardening..."
mkdir -p /etc/sysctl.d
cp "${SYSCTL_HARDENED_PATH}" "${SYSCTL_TARGET_NAME}" || error_exit_chroot "Failed to copy sysctl hardening config"
sysctl -p "${SYSCTL_TARGET_NAME}" || log_chroot "WARN" "Failed to apply sysctl config immediately, will apply on boot."

# 7.4 User/Password
log_chroot "INFO" "Setting root password to 'toor' for now. PLEASE CHANGE AFTER INSTALLATION!"
echo "root:toor" | chpasswd || error_exit_chroot "Failed to set root password"

# 7.5 Privacy Tools & MAC Randomization (Stubs)
if [ "\${ENABLE_MAC_RANDOMIZATION}" -eq 1 ]; then
  log_chroot "INFO" "Enabling MAC randomization (calling stub script)..."
  # This script will be implemented later
  /scripts/setup_mac_randomization.sh --config /hardened-os.conf || log_chroot "WARN" "MAC randomization setup script failed (stub)."
fi

if [ "\${ENABLE_TOR_I2P_STACK}" -eq 1 ]; then
  log_chroot "INFO" "Installing privacy tools (calling stub script)..."
  # This script will be implemented later
  /scripts/install_privacy_tools.sh --config /hardened-os.conf || log_chroot "WARN" "Privacy tools installation script failed (stub)."
fi

log_chroot "INFO" "Post-debootstrap configurations inside chroot complete."
EOF

chmod +x "${ROOT_MOUNTPOINT}/tmp/chroot_script.sh" || error_exit "Failed to make chroot script executable"

log "INFO" "Executing chroot script..."
chroot "${ROOT_MOUNTPOINT}" /tmp/chroot_script.sh || error_exit "Chroot script execution failed"

# Clean up chroot script
rm "${ROOT_MOUNTPOINT}/tmp/chroot_script.sh" || log "WARN" "Failed to remove chroot script."

log "INFO" "Chroot environment setup and post-debootstrap configurations complete."

# 8. Cleanup
log "INFO" "Cleaning up mounts and LUKS device..."
# Unmount filesystems
umount -R "${ROOT_MOUNTPOINT}" || error_exit "Failed to unmount all from root mountpoint."

# Close LUKS device
if [ "${LUKS_ENABLE}" -eq 1 ]; then
  cryptsetup luksClose "${LUKS_MAPPER_NAME}" || log "WARN" "Failed to close LUKS device (might already be closed)."
fi
log "INFO" "Cleanup complete."

exit 0
