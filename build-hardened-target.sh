#!/usr/bin/env bash
set -Eeuo pipefail

# Hardened Debian Target Installer
# --------------------------------
# This script is intended to be run from the live/installer environment.
# It will:
#   - Wipe the entire target disk
#   - Create GPT: ESP (FAT32) + LUKS2 root
#   - Setup LUKS2 FDE
#   - debootstrap Debian into the encrypted root
#   - Install kernel + GRUB (EFI) with encrypted GRUB password
#   - Apply sysctl hardening, swapfile, and privacy/MAC features

usage() {
  echo "Usage: $0 --config <file> --disk <dev> --hostname <name> --luks-passphrase-stdin" >&2
  echo "Example: echo 'MyStrongPass' | $0 --config /opt/hardened-installer/hardened-os.conf --disk /dev/nvme0n1 --hostname secure-os --luks-passphrase-stdin" >&2
  exit 1
}

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[FATAL] %s\n' "$*" >&2; exit 1; }

trap 'warn "Error on line $LINENO"' ERR

CONFIG_FILE=""
TARGET_DISK=""
HOSTNAME=""
READ_LUKS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --disk) TARGET_DISK="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --luks-passphrase-stdin) READ_LUKS=1; shift;;
    *) usage;;
  esac
done

[ -n "$CONFIG_FILE" ] || usage
[ -n "$TARGET_DISK" ] || usage
[ -n "$HOSTNAME" ] || usage

[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
[ -b "$TARGET_DISK" ] || die "Target disk is not a block device: $TARGET_DISK"

if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root"
fi

# Read LUKS passphrase from stdin if requested
if [ "$READ_LUKS" -eq 1 ]; then
  IFS= read -r LUKS_PASSPHRASE || die "Failed to read LUKS passphrase from stdin"
  [ -n "$LUKS_PASSPHRASE" ] || die "Empty LUKS passphrase is not allowed"
else
  die "For safety, you must pass --luks-passphrase-stdin and pipe the passphrase via stdin"
fi

# Load config
# shellcheck source=/dev/null
. "$CONFIG_FILE"

# Base paths (assuming standard layout: /opt/hardened-installer)
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES_DIR="${BASE_DIR}/templates"
SYSCTL_TEMPLATE="${TEMPLATES_DIR}/90-hardened.conf"
GRUB_STUB_TEMPLATE="${TEMPLATES_DIR}/grub-40_custom.stub"

# Config defaults / sanity
ROOT_MOUNTPOINT="${ROOT_MOUNTPOINT:-/mnt/target}"
ESP_SIZE_MIB="${ESP_SIZE_MIB:-512}"
LUKS_MAPPER_NAME="${LUKS_MAPPER_NAME:-cryptroot}"
ROOT_FS_TYPE="${ROOT_FS_TYPE:-ext4}"
ROOT_FS_LABEL="${ROOT_FS_LABEL:-rootfs}"
ESP_LABEL="${ESP_LABEL:-EFI}"
ESP_FS_TYPE="${ESP_FS_TYPE:-vfat}"
SWAPFILE_PATH="${SWAPFILE_PATH:-/swapfile}"
SWAPFILE_SIZE_GB="${SWAPFILE_SIZE_GB:-8}"
OS_TIMEZONE="${OS_TIMEZONE:-UTC}"
OS_LOCALE="${OS_LOCALE:-en_US.UTF-8}"
DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
MIRROR_URL="${MIRROR_URL:-http://deb.debian.org/debian}"
KERNEL_PACKAGE_NAME="${KERNEL_PACKAGE_NAME:-linux-image-amd64}"
KERNEL_CMDLINE_DEFAULT="${KERNEL_CMDLINE_DEFAULT:-quiet mitigations=auto pti=on}"

GRUB_SUPERUSER="${GRUB_SUPERUSER:-root}"
GRUB_PASSWORD_PLAINTEXT="${GRUB_PASSWORD_PLAINTEXT:-atomickitty}"

LUKS_CIPHER="${LUKS_CIPHER:-aes-xts-plain64}"
LUKS_KEY_SIZE="${LUKS_KEY_SIZE:-512}"
LUKS_HASH="${LUKS_HASH:-sha512}"
LUKS_PBKDF="${LUKS_PBKDF:-argon2id}"
LUKS_PBKDF_MEMORY="${LUKS_PBKDF_MEMORY:-524288}"
LUKS_PBKDF_PARALLEL="${LUKS_PBKDF_PARALLEL:-4}"
LUKS_PBKDF_FORCE_ITER="${LUKS_PBKDF_FORCE_ITER:-4}"

# Safety check: refuse to install to the current root disk
ROOTDEV="$(findmnt -no SOURCE / || true)"
if [ -n "$ROOTDEV" ]; then
  ROOTBASE="$ROOTDEV"
  # Strip partition suffix for simple cases
  case "$ROOTBASE" in
    /dev/*[0-9]) ROOTBASE="${ROOTBASE%[0-9]*}";;
    /dev/*p[0-9]) ROOTBASE="${ROOTBASE%p[0-9]*}";;
  esac
  if [ "$ROOTBASE" = "$TARGET_DISK" ]; then
    die "Refusing to partition $TARGET_DISK because it appears to contain the running system root ($ROOTDEV)"
  fi
fi

log "CONFIG_FILE:   $CONFIG_FILE"
log "TARGET_DISK:   $TARGET_DISK"
log "HOSTNAME:      $HOSTNAME"
log "ROOT_MOUNT:    $ROOT_MOUNTPOINT"
log "DEBIAN_SUITE:  $DEBIAN_SUITE"
log "MIRROR_URL:    $MIRROR_URL"

#############################
# 1) Partition the disk GPT #
#############################
log "Wiping existing partition table on $TARGET_DISK"
wipefs -a "$TARGET_DISK"

log "Creating GPT, ESP + LUKS root"
parted -s "$TARGET_DISK" mklabel gpt
parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB "${ESP_SIZE_MIB}MiB"
parted -s "$TARGET_DISK" set 1 esp on
parted -s "$TARGET_DISK" mkpart cryptroot "${ESP_SIZE_MIB}MiB" 100%

# Discover partitions by lsblk
mapfile -t PARTS < <(lsblk -ln -o NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}')
[ "${#PARTS[@]}" -ge 2 ] || die "Expected at least 2 partitions on $TARGET_DISK"

ESP_PART="/dev/${PARTS[0]}"
LUKS_PART="/dev/${PARTS[1]}"

log "ESP partition:  $ESP_PART"
log "LUKS partition: $LUKS_PART"

##################################
# 2) LUKS2 FDE setup (cryptroot) #
##################################
log "Formatting LUKS2 on $LUKS_PART"
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat \
  --type luks2 \
  --cipher "$LUKS_CIPHER" \
  --key-size "$LUKS_KEY_SIZE" \
  --hash "$LUKS_HASH" \
  --pbkdf "$LUKS_PBKDF" \
  --pbkdf-memory "$LUKS_PBKDF_MEMORY" \
  --pbkdf-parallel "$LUKS_PBKDF_PARALLEL" \
  --pbkdf-force-iterations "$LUKS_PBKDF_FORCE_ITER" \
  "$LUKS_PART"

log "Opening LUKS container as /dev/mapper/$LUKS_MAPPER_NAME"
echo -n "$LUKS_PASSPHRASE" | cryptsetup open "$LUKS_PART" "$LUKS_MAPPER_NAME"

LUKS_MAPPER_DEV="/dev/mapper/${LUKS_MAPPER_NAME}"
[ -b "$LUKS_MAPPER_DEV" ] || die "Mapper device not found: $LUKS_MAPPER_DEV"

################################
# 3) Filesystems + mount tree  #
################################
log "Creating $ROOT_FS_TYPE filesystem on $LUKS_MAPPER_DEV"
mkfs."$ROOT_FS_TYPE" -L "$ROOT_FS_LABEL" "$LUKS_MAPPER_DEV"

log "Creating $ESP_FS_TYPE filesystem on $ESP_PART"
mkfs.vfat -n "$ESP_LABEL" "$ESP_PART"

log "Creating mountpoint: $ROOT_MOUNTPOINT"
mkdir -p "$ROOT_MOUNTPOINT"

log "Mounting root filesystem"
mount "$LUKS_MAPPER_DEV" "$ROOT_MOUNTPOINT"

log "Mounting ESP partition"
mkdir -p "$ROOT_MOUNTPOINT/boot/efi"
mount "$ESP_PART" "$ROOT_MOUNTPOINT/boot/efi"

########################################
# 4) Bootstrap Debian into encrypted root
########################################
log "Bootstrapping Debian ($DEBIAN_SUITE) into $ROOT_MOUNTPOINT"
debootstrap --arch=amd64 "$DEBIAN_SUITE" "$ROOT_MOUNTPOINT" "$MIRROR_URL"

# Bind-mount runtime dirs
for fs in dev dev/pts proc sys run; do
  mkdir -p "$ROOT_MOUNTPOINT/$fs"
  mount --bind "/$fs" "$ROOT_MOUNTPOINT/$fs"
done

############################
# 5) Chroot configuration  #
############################
run_in_chroot() {
  chroot "$ROOT_MOUNTPOINT" /bin/bash -c "$*"
}

log "Configuring hostname, timezone, locale in chroot"
echo "$HOSTNAME" > "$ROOT_MOUNTPOINT/etc/hostname"

# /etc/hosts baseline
cat > "$ROOT_MOUNTPOINT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

run_in_chroot "ln -sf /usr/share/zoneinfo/$OS_TIMEZONE /etc/localtime && dpkg-reconfigure -f noninteractive tzdata"
run_in_chroot "sed -i 's/^# *$OS_LOCALE UTF-8/$OS_LOCALE UTF-8/' /etc/locale.gen || true"
run_in_chroot "locale-gen"
run_in_chroot "update-locale LANG=$OS_LOCALE"

log "Installing base packages, kernel, cryptsetup, GRUB, NetworkManager, XFCE, SSH"
run_in_chroot "export DEBIAN_FRONTEND=noninteractive; apt-get update"
run_in_chroot "export DEBIAN_FRONTEND=noninteractive; apt-get install -y \
  $KERNEL_PACKAGE_NAME cryptsetup initramfs-tools grub-efi-amd64 shim-signed \
  systemd-sysv sudo openssh-server network-manager xfce4 xfce4-terminal"

# Optional: install tor/i2p/mac randomization if scripts are present
if [ -x "$BASE_DIR/scripts/install_privacy_tools.sh" ]; then
  log "Running install_privacy_tools.sh inside target"
  cp "$BASE_DIR/scripts/install_privacy_tools.sh" "$ROOT_MOUNTPOINT/root/install_privacy_tools.sh"
  run_in_chroot "bash /root/install_privacy_tools.sh && rm -f /root/install_privacy_tools.sh"
fi

if [ -x "$BASE_DIR/scripts/setup_mac_randomization.sh" ]; then
  log "Running setup_mac_randomization.sh inside target"
  cp "$BASE_DIR/scripts/setup_mac_randomization.sh" "$ROOT_MOUNTPOINT/root/setup_mac_randomization.sh"
  run_in_chroot "bash /root/setup_mac_randomization.sh && rm -f /root/setup_mac_randomization.sh"
fi

#####################################
# 6) crypttab, fstab, swapfile      #
#####################################
log "Writing /etc/crypttab and /etc/fstab"

LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")
[ -n "$LUKS_UUID" ] || die "Failed to get UUID for $LUKS_PART"

cat > "$ROOT_MOUNTPOINT/etc/crypttab" <<EOF
cryptroot UUID=$LUKS_UUID none luks,discard
EOF

ROOT_UUID=$(blkid -s UUID -o value "$LUKS_MAPPER_DEV")
ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")

[ -n "$ROOT_UUID" ] || die "Failed to get UUID for $LUKS_MAPPER_DEV"
[ -n "$ESP_UUID" ] || die "Failed to get UUID for $ESP_PART"

cat > "$ROOT_MOUNTPOINT/etc/fstab" <<EOF
UUID=$ROOT_UUID  /          $ROOT_FS_TYPE  defaults,discard  0 1
UUID=$ESP_UUID   /boot/efi  vfat           umask=0077        0 1
EOF

# Swapfile
log "Creating swapfile at $SWAPFILE_PATH ($SWAPFILE_SIZE_GB GiB)"
run_in_chroot "fallocate -l ${SWAPFILE_SIZE_GB}G $SWAPFILE_PATH && chmod 600 $SWAPFILE_PATH && mkswap $SWAPFILE_PATH"
cat >> "$ROOT_MOUNTPOINT/etc/fstab" <<EOF
$SWAPFILE_PATH none swap sw 0 0
EOF

###################################
# 7) Sysctl hardening (sysctl.d)  #
###################################
if [ -f "$SYSCTL_TEMPLATE" ]; then
  log "Installing sysctl hardening from template"
  mkdir -p "$ROOT_MOUNTPOINT/etc/sysctl.d"
  cp "$SYSCTL_TEMPLATE" "$ROOT_MOUNTPOINT/etc/sysctl.d/90-hardened.conf"
else
  warn "Sysctl template not found at $SYSCTL_TEMPLATE; skipping."
fi

########################################
# 8) Initramfs and GRUB (encrypted)    #
########################################
log "Updating initramfs in chroot"
run_in_chroot "update-initramfs -u -k all"

log "Generating GRUB password hash"
GRUB_HASH=$(chroot "$ROOT_MOUNTPOINT" env GRUB_PWD="$GRUB_PASSWORD_PLAINTEXT" /bin/bash -c '
  printf "%s\n%s\n" "$GRUB_PWD" "$GRUB_PWD" | grub-mkpasswd-pbkdf2 2>/dev/null | awk "/PBKDF2 hash of your password is/ {print \$NF}"
')
[ -n "$GRUB_HASH" ] || die "Failed to derive GRUB password hash"

if [ -f "$GRUB_STUB_TEMPLATE" ]; then
  log "Installing /etc/grub.d/40_custom with encrypted GRUB user"
  mkdir -p "$ROOT_MOUNTPOINT/etc/grub.d"
  sed -e "s/__GRUB_SUPERUSER__/$GRUB_SUPERUSER/g" \
      -e "s|__GRUB_PASSWORD_HASH__|$GRUB_HASH|g" \
      "$GRUB_STUB_TEMPLATE" > "$ROOT_MOUNTPOINT/etc/grub.d/40_custom"
  chmod 755 "$ROOT_MOUNTPOINT/etc/grub.d/40_custom"
else
  warn "GRUB stub template not found at $GRUB_STUB_TEMPLATE; skipping custom GRUB user file."
fi

log "Setting GRUB defaults (cryptodisk + hardened cmdline)"
GRUB_DEFAULT_FILE="$ROOT_MOUNTPOINT/etc/default/grub"
{
  echo "GRUB_ENABLE_CRYPTODISK=y"
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$KERNEL_CMDLINE_DEFAULT\""
} >> "$GRUB_DEFAULT_FILE"

log "Installing GRUB (EFI) into /boot/efi"
run_in_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian-hardened --recheck"
run_in_chroot "update-grub"

##########################
# 9) Final cleanup       #
##########################
log "Syncing and unmounting target"
sync || true

for fs in dev/pts dev proc sys run; do
  if mountpoint -q "$ROOT_MOUNTPOINT/$fs"; then
    umount "$ROOT_MOUNTPOINT/$fs"
  fi
done

if mountpoint -q "$ROOT_MOUNTPOINT/boot/efi"; then
  umount "$ROOT_MOUNTPOINT/boot/efi"
fi

if mountpoint -q "$ROOT_MOUNTPOINT"; then
  umount "$ROOT_MOUNTPOINT"
fi

log "Closing LUKS mapper $LUKS_MAPPER_NAME"
cryptsetup close "$LUKS_MAPPER_NAME" || warn "Failed to close mapper (may already be closed)"

log "Installation complete. You can now reboot into your hardened, fully-encrypted system."
exit 0
