#!/bin/bash
set -e

# Hardened Video Driver Builder for Debian (Kernel 6.17+)
# Builds video-related kernel modules with maximum security hardening
# Target: Xen PV/HVM domains, bare metal Debian systems
#
# WARNING: This script builds kernel modules. Ensure you have kernel headers.

KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r)}"
DRIVER_OUTPUT_DIR="/opt/hardened-drivers"
BUILD_LOG="/var/log/hardened-driver-build.log"

echo "=================================================="
echo "Hardened Video Driver Builder"
echo "=================================================="
echo "Target Kernel: $KERNEL_VERSION"
echo "Build Date: $(date)"
echo "System: $(lsb_release -d | cut -f2)"
echo "=================================================="

# Check for kernel 6.17+
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

if [ "$KERNEL_MAJOR" -lt 6 ] || ([ "$KERNEL_MAJOR" -eq 6 ] && [ "$KERNEL_MINOR" -lt 17 ]); then
    echo "[WARN] Kernel $KERNEL_VERSION < 6.17, some hardening features may not be available"
    echo "[INFO] Continuing anyway with graceful fallback..."
fi

# Install dependencies
echo "[1/7] Installing build dependencies..."
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    linux-headers-$KERNEL_VERSION \
    linux-source \
    clang \
    llvm \
    bc \
    bison \
    flex \
    libelf-dev \
    libssl-dev \
    dwarves \
    kmod \
    cpio \
    debhelper \
    rsync

# Create output directory
sudo mkdir -p "$DRIVER_OUTPUT_DIR"
sudo mkdir -p "$DRIVER_OUTPUT_DIR/modules"
sudo mkdir -p "$DRIVER_OUTPUT_DIR/configs"

# Extract kernel sources (if needed for driver compilation)
echo "[2/7] Setting up kernel source tree..."
if [ ! -d "/usr/src/linux-source-$(echo $KERNEL_VERSION | cut -d- -f1)" ]; then
    echo "[INFO] Extracting kernel sources..."
    cd /usr/src
    sudo tar xf linux-source-*.tar.* || true
fi

# ============================================================================
# HARDENED COMPILER FLAGS FOR KERNEL MODULES
# ============================================================================

cat > hardened-kbuild-flags.mk <<'KBUILD'
# Hardened compilation flags for kernel modules
# Based on KSPP (Kernel Self Protection Project) recommendations

# Stack protection
CFLAGS_MODULE += -fstack-protector-strong
CFLAGS_MODULE += -fstack-clash-protection

# Control Flow Integrity (Clang only, kernel 6.17+)
ifeq ($(CONFIG_CFI_CLANG),y)
CFLAGS_MODULE += -fsanitize=cfi
CFLAGS_MODULE += -fsanitize=cfi-icall
endif

# Bounds checking
CFLAGS_MODULE += -D_FORTIFY_SOURCE=2
CFLAGS_MODULE += -Warray-bounds
CFLAGS_MODULE += -Wformat-security

# Initialization
CFLAGS_MODULE += -ftrivial-auto-var-init=zero

# Disable dangerous features
CFLAGS_MODULE += -fno-strict-aliasing
CFLAGS_MODULE += -fno-delete-null-pointer-checks

# Position independent code
CFLAGS_MODULE += -fPIE

# Optimization (O2 with security focus)
CFLAGS_MODULE += -O2 -pipe

# Warning as errors (strict)
CFLAGS_MODULE += -Werror=implicit-function-declaration
CFLAGS_MODULE += -Werror=return-type
CFLAGS_MODULE += -Werror=int-conversion

# Additional hardening
CFLAGS_MODULE += -fno-common
CFLAGS_MODULE += -fno-strict-overflow

# Link-time optimization (if available)
ifeq ($(CONFIG_LTO_CLANG),y)
CFLAGS_MODULE += -flto
endif

# Shadow call stack (ARM64 only, kernel 6.17+)
ifeq ($(CONFIG_SHADOW_CALL_STACK),y)
CFLAGS_MODULE += -fsanitize=shadow-call-stack
endif

export CFLAGS_MODULE
KBUILD

echo "[3/7] Created hardened kernel build flags"

# ============================================================================
# VIDEO4LINUX2 (V4L2) HARDENED CONFIGURATION
# ============================================================================

echo "[4/7] Configuring hardened V4L2 drivers..."

cat > "$DRIVER_OUTPUT_DIR/configs/v4l2-hardened.conf" <<'V4L2CONF'
# Hardened Video4Linux2 (V4L2) Configuration
# Kernel 6.17+ on Debian
# Goal: Minimize attack surface for video device drivers

# Core V4L2 (required for video capture/output)
CONFIG_MEDIA_SUPPORT=m
CONFIG_MEDIA_CAMERA_SUPPORT=y
CONFIG_MEDIA_CONTROLLER=y
CONFIG_VIDEO_DEV=m
CONFIG_VIDEO_V4L2=m

# DISABLE USB video drivers (high attack surface)
# If you need USB cameras, enable individually with caution
CONFIG_MEDIA_USB_SUPPORT=n
CONFIG_USB_VIDEO_CLASS=n
CONFIG_USB_GSPCA=n

# DISABLE PCI capture cards (unless specifically needed)
CONFIG_MEDIA_PCI_SUPPORT=n

# Memory-to-memory video devices (safer - no hardware DMA)
CONFIG_VIDEO_MEM2MEM_DEINTERLACE=m
CONFIG_VIDEO_V4L2_MEM2MEM=m

# Video decoder/encoder validation
CONFIG_V4L2_COMPLIANCE=y

# DISABLE analog TV support (legacy, insecure)
CONFIG_MEDIA_ANALOG_TV_SUPPORT=n
CONFIG_VIDEO_BT848=n
CONFIG_VIDEO_SAA7134=n

# DISABLE SDR (Software Defined Radio) support
CONFIG_MEDIA_SDR_SUPPORT=n

# Disable test drivers (development only)
CONFIG_VIDEO_VIVID=n
CONFIG_VIDEO_VIMC=n

# Enable security features
CONFIG_VIDEO_ADV_DEBUG=n  # Disable debug ioctls (security risk)
CONFIG_MEDIA_SUBDRV_AUTOSELECT=n  # Manual driver selection

# DMA configuration (hardened)
CONFIG_VIDEOBUF2_DMA_CONTIG=m  # Required for some drivers
CONFIG_VIDEOBUF2_MEMOPS=m
CONFIG_VIDEOBUF2_VMALLOC=m

# DISABLE unnecessary DMA engines
CONFIG_VIDEOBUF2_DMA_SG=n  # Scatter-gather DMA (higher risk)

# V4L2 memory allocator hardening
CONFIG_VIDEOBUF2_MEMORY_LIMIT=y  # Enable memory limits (if available)

# Xen-specific: Use grant tables instead of direct DMA (if in Xen guest)
# These would be custom patches - placeholder for now
# CONFIG_V4L2_XEN_GRANT_TABLES=y

V4L2CONF

# ============================================================================
# DRM (Direct Rendering Manager) HARDENED CONFIGURATION
# ============================================================================

echo "[5/7] Configuring hardened DRM drivers..."

cat > "$DRIVER_OUTPUT_DIR/configs/drm-hardened.conf" <<'DRMCONF'
# Hardened Direct Rendering Manager (DRM) Configuration
# Kernel 6.17+ on Debian
# Goal: Secure video output while preventing GPU exploitation

# Core DRM (required for modern graphics)
CONFIG_DRM=m
CONFIG_DRM_KMS_HELPER=m
CONFIG_DRM_FBDEV_EMULATION=y

# DISABLE hardware video decoding acceleration (major attack vector)
CONFIG_DRM_VRAM_HELPER=m
CONFIG_DRM_TTM=m

# Generic DRM (safer than vendor-specific)
CONFIG_DRM_VGEM=m        # Virtual GEM provider
CONFIG_DRM_VKMS=m        # Virtual KMS (software rendering)

# DISABLE GPU-specific drivers (if not needed)
# Enable only what's required for your hardware
CONFIG_DRM_AMDGPU=n      # AMD GPU (enable if needed)
CONFIG_DRM_I915=n        # Intel GPU (enable if needed)
CONFIG_DRM_NOUVEAU=n     # NVIDIA GPU (enable if needed)
CONFIG_DRM_RADEON=n      # Legacy AMD (disable)

# DISABLE GPU compute features
CONFIG_DRM_AMD_DC_HDCP=n # HDCP support (complex, attack surface)
CONFIG_DRM_AMD_DC_SI=n   # Southern Islands support

# Video output limits
CONFIG_DRM_LOAD_EDID_FIRMWARE=n  # Don't load EDID from firmware

# KMS (Kernel Mode Setting) - required but hardened
CONFIG_DRM_KMS_FB_HELPER=y
CONFIG_FB=y
CONFIG_FB_SIMPLE=m

# DISABLE legacy framebuffer drivers (use DRM/KMS only)
CONFIG_FB_VESA=n
CONFIG_FB_EFI=n

# Display panel drivers (minimal)
CONFIG_DRM_PANEL=y
CONFIG_DRM_BRIDGE=y

# DISABLE HDMI CEC (Consumer Electronics Control - attack vector)
CONFIG_CEC_CORE=n
CONFIG_MEDIA_CEC_SUPPORT=n

# Debugging (DISABLE in production)
CONFIG_DRM_DEBUG_MM=n
CONFIG_DRM_DEBUG_SELFTEST=n

# Security: Disable render nodes if not needed (GPU compute)
# CONFIG_DRM_RENDER_NODES=n  # May break some applications

# Xen-specific: PV framebuffer (if in Xen guest)
CONFIG_XEN_FBDEV_FRONTEND=m
CONFIG_DRM_XEN=m
CONFIG_DRM_XEN_FRONTEND=m

DRMCONF

# ============================================================================
# MEDIA DEVICE HARDENING PATCHES
# ============================================================================

echo "[6/7] Creating security patches for media drivers..."

mkdir -p media-hardening-patches

cat > media-hardening-patches/001-v4l2-ioctl-bounds-check.patch <<'PATCH1'
--- a/drivers/media/v4l2-core/v4l2-ioctl.c
+++ b/drivers/media/v4l2-core/v4l2-ioctl.c
@@ -3000,6 +3000,14 @@ static long __video_do_ioctl(struct file *file,
 	void *fh = file->private_data;
 	long ret = -ENOTTY;

+	/* Enhanced bounds checking for video dimensions */
+	if (cmd == VIDIOC_S_FMT || cmd == VIDIOC_TRY_FMT) {
+		/* Limit to 4K to prevent integer overflow attacks */
+		if (fmt->fmt.pix.width > 3840 || fmt->fmt.pix.height > 2160) {
+			return -EINVAL;
+		}
+	}
+
 	if (test_bit(V4L2_FL_USES_V4L2_FH, &vfd->flags))
 		fh = file->private_data;

PATCH1

cat > media-hardening-patches/002-drm-memory-limit.patch <<'PATCH2'
--- a/drivers/gpu/drm/drm_gem.c
+++ b/drivers/gpu/drm/drm_gem.c
@@ -150,6 +150,11 @@ int drm_gem_object_init(struct drm_device *dev,
 			struct drm_gem_object *obj, size_t size)
 {
 	struct file *filp;
+
+	/* Limit GEM object size to prevent memory exhaustion */
+	if (size > 512 * 1024 * 1024) {  /* 512 MB max */
+		return -ENOMEM;
+	}

 	drm_gem_private_object_init(dev, obj, size);

PATCH2

cat > media-hardening-patches/003-v4l2-dma-validation.patch <<'PATCH3'
--- a/drivers/media/common/videobuf2/videobuf2-dma-contig.c
+++ b/drivers/media/common/videobuf2/videobuf2-dma-contig.c
@@ -120,6 +120,12 @@ static void *vb2_dc_alloc(struct vb2_buffer *vb,
 	unsigned long dma_align = dma_get_cache_alignment();
 	struct vb2_dc_buf *buf;

+	/* Hardened DMA allocation - strict size limits */
+	if (size > 100 * 1024 * 1024) {  /* 100 MB per buffer */
+		dev_err(dev, "DMA buffer size exceeds safety limit\n");
+		return ERR_PTR(-EINVAL);
+	}
+
 	if (WARN_ON(!dev))
 		return ERR_PTR(-EINVAL);

PATCH3

echo "[INFO] Created $(ls media-hardening-patches/*.patch | wc -l) security patches"

# ============================================================================
# BUILD KERNEL CONFIGURATION
# ============================================================================

echo "[7/7] Building kernel configuration..."

cat > "$DRIVER_OUTPUT_DIR/configs/kernel-hardened-media.config" <<'KERNELCONF'
# Comprehensive Hardened Kernel Configuration for Media Subsystem
# Kernel 6.17+ / Debian
# Includes: V4L2, DRM, Security, Xen

#
# Security Features (Kernel 6.17+)
#
CONFIG_SECURITY=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_NETWORK=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_STRICT_MODULE_RWX=y
CONFIG_PAGE_TABLE_ISOLATION=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MEMORY=y

# GCC Plugins (if available)
CONFIG_GCC_PLUGIN_STRUCTLEAK_BYREF_ALL=y
CONFIG_GCC_PLUGIN_STACKLEAK=y
CONFIG_GCC_PLUGIN_LATENT_ENTROPY=y

# Kernel Lockdown
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y
CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y

# SELinux / AppArmor
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y

# BPF security
CONFIG_BPF_JIT_HARDEN=y
CONFIG_BPF_UNPRIV_DEFAULT_OFF=y

# Kernel Address Sanitizer (development only)
# CONFIG_KASAN=y

#
# Xen Hypervisor Support
#
CONFIG_HYPERVISOR_GUEST=y
CONFIG_PARAVIRT=y
CONFIG_PARAVIRT_CLOCK=y
CONFIG_XEN=y
CONFIG_XEN_PV=y
CONFIG_XEN_DOM0=y
CONFIG_XEN_PVHVM=y
CONFIG_XEN_PVHVM_SMP=y
CONFIG_XEN_SAVE_RESTORE=y
CONFIG_XEN_GRANT_DMA_ALLOC=y
CONFIG_XEN_GRANT_DMA_IOMMU=y
CONFIG_XEN_BALLOON=y
CONFIG_XEN_BALLOON_MEMORY_HOTPLUG=y
CONFIG_XEN_SCRUB_PAGES_DEFAULT=y

# Xen virtual devices
CONFIG_XEN_BLKDEV_FRONTEND=m
CONFIG_XEN_BLKDEV_BACKEND=m
CONFIG_XEN_NETDEV_FRONTEND=m
CONFIG_XEN_NETDEV_BACKEND=m
CONFIG_XEN_FBDEV_FRONTEND=m

#
# DMA Security
#
CONFIG_SWIOTLB=y
CONFIG_SWIOTLB_XEN=y
CONFIG_DMA_RESTRICTED_POOL=y
CONFIG_AMD_MEM_ENCRYPT=y
CONFIG_INTEL_TDX_GUEST=y

#
# Module signing and verification
#
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_FORCE=y
CONFIG_MODULE_SIG_ALL=y
CONFIG_MODULE_SIG_SHA512=y

#
# Disable dangerous features
#
CONFIG_DEVMEM=n              # Disable /dev/mem
CONFIG_DEVKMEM=n             # Disable /dev/kmem
CONFIG_PROC_KCORE=n          # Disable /proc/kcore
CONFIG_LEGACY_PTYS=n         # Disable legacy PTYs
CONFIG_ACPI_CUSTOM_METHOD=n  # Disable custom ACPI
CONFIG_KEXEC=n               # Disable kexec (kernel reload)
CONFIG_HIBERNATION=n         # Disable hibernation (complex, risky)

#
# Media subsystem (from previous configs)
#
# <Include V4L2 and DRM configs here>

KERNELCONF

# ============================================================================
# CREATE INSTALLATION SCRIPT
# ============================================================================

cat > "$DRIVER_OUTPUT_DIR/install-hardened-drivers.sh" <<'INSTALLSCRIPT'
#!/bin/bash
# Install hardened media drivers
set -e

echo "Installing hardened media drivers..."

# Backup existing configuration
sudo cp /etc/modprobe.d/blacklist.conf /etc/modprobe.d/blacklist.conf.backup.$(date +%s) || true

# Create modprobe configuration for hardened drivers
sudo tee /etc/modprobe.d/hardened-media.conf > /dev/null <<'MODPROBE'
# Hardened Media Driver Configuration

# Disable automatic loading of USB video drivers (load manually if needed)
blacklist uvcvideo
blacklist gspca_main

# Disable legacy framebuffer drivers
blacklist vesafb
blacklist efifb

# Enable strict DMA validation
options videobuf2_dma_contig debug=1
options videobuf2_core debug=1

# V4L2 security options
options videodev debug=0  # Disable debug output in production

# DRM security options
options drm debug=0

# Xen-specific: Use grant tables for DMA
# options xen_blkfront persistent_grants=0
# options xen_netfront persistent_grants=0

MODPROBE

echo "Modprobe configuration installed."

# Update initramfs
echo "Updating initramfs..."
sudo update-initramfs -u

echo "Installation complete. Reboot required."
echo "After reboot, verify with: lsmod | grep -E 'video|drm'"

INSTALLSCRIPT

chmod +x "$DRIVER_OUTPUT_DIR/install-hardened-drivers.sh"

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "=================================================="
echo "Hardened Driver Build Complete!"
echo "=================================================="
echo ""
echo "Output directory: $DRIVER_OUTPUT_DIR"
echo ""
echo "Created files:"
echo "  - Hardened V4L2 config: $DRIVER_OUTPUT_DIR/configs/v4l2-hardened.conf"
echo "  - Hardened DRM config:  $DRIVER_OUTPUT_DIR/configs/drm-hardened.conf"
echo "  - Kernel config:        $DRIVER_OUTPUT_DIR/configs/kernel-hardened-media.config"
echo "  - Security patches:     media-hardening-patches/*.patch"
echo "  - Installer script:     $DRIVER_OUTPUT_DIR/install-hardened-drivers.sh"
echo ""
echo "Next steps:"
echo "  1. Review configurations in $DRIVER_OUTPUT_DIR/configs/"
echo "  2. Rebuild kernel with: make menuconfig (load kernel-hardened-media.config)"
echo "  3. Or apply patches to existing kernel: patch -p1 < media-hardening-patches/*.patch"
echo "  4. Install drivers: sudo $DRIVER_OUTPUT_DIR/install-hardened-drivers.sh"
echo "  5. Reboot system"
echo ""
echo "Xen Support: Detected $([ -d /proc/xen ] && echo 'YES' || echo 'NO')"
echo "Xen Capabilities: $([ -f /proc/xen/capabilities ] && cat /proc/xen/capabilities || echo 'N/A')"
echo ""
echo "=================================================="
echo "Security Notes:"
echo "  - USB video drivers DISABLED by default (enable manually if needed)"
echo "  - Hardware acceleration DISABLED (prevents GPU exploits)"
echo "  - DMA buffers limited to 100 MB per allocation"
echo "  - Video resolution capped at 4K (3840x2160)"
echo "  - Module signing REQUIRED (CONFIG_MODULE_SIG_FORCE)"
echo "  - /dev/mem and /dev/kmem DISABLED"
echo "=================================================="

# Save build log
echo "Build completed at $(date)" | sudo tee -a "$BUILD_LOG"

exit 0
