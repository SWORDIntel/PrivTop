# Hardened Debian Builder

This project provides a comprehensive set of scripts designed to **build and customize your own hardened Debian-based operating system**. It generates a bootable **ISO installer** that enables the **creation** of a secure computing environment. This environment features full-disk encryption (LUKS2), a custom-tuned kernel, CPU-optimized libraries, and various system-level security and privacy mitigations tailored to your needs.

The installation process on the target machine is guided by an interactive Text User Interface (TUI). This TUI allows you to select key options like the desktop environment, specific hardening features, and privacy tools. A core design principle is to offload heavy compilation tasks, such as kernel building and library optimization, to the ISO generation machine (your host), ensuring a significantly faster and more reliable installation experience on the target device.

---

## Features

*   **Full Disk Encryption (LUKS2):** Secure your entire system with robust encryption.
*   **Custom-Tuned Kernel:** Build a kernel optimized for specific hardware (e.g., Intel Comet Lake-H) with enhanced security toggles and compiler flags.
*   **CPU-Optimized Libraries:** Critical system libraries (crypto, compression, media codecs, GUI stack) are pre-compiled with optimal flags for the target CPU architecture, ensuring maximum performance.
*   **Hardened System Defaults:** Applies a comprehensive set of `sysctl` rules for kernel-level security hardening.
*   **Privacy Enhancements:** Includes options for MAC address randomization and installation of Tor/I2P anonymity tools.
*   **KDE Plasma Desktop (Optional):** Installs a KDE Plasma desktop environment with a dark theme by default, if selected.
*   **TUI-Guided Installation:** An interactive Text User Interface simplifies disk selection, passphrase setup, and feature choices for the end-user.
*   **Pre-built Artifacts:** Heavy compilation tasks (custom kernel, optimized libraries) are performed once on the ISO-generating machine, drastically speeding up the installation on the target laptop.

---

## Target Hardware Profile

This build is specifically tuned for:
*   **CPU:** Intel Core i5 H-series mobile CPU (quad-core, 8-thread, e.g., 10th-gen 10300H-class, Comet Lake-H)
*   **Integrated GPU:** Intel UHD Graphics (iGPU tied to that CPU family)
*   **Platform:** HP Pavilion consumer laptop
*   **Architecture:** 64-bit x86 (Intel)
*   **Firmware:** UEFI firmware

---

## Building the Installer ISO

The build process is designed to be run on a capable Linux machine (your host machine) to generate a bootable `.iso` file. This `.iso` will then be used to install the hardened Debian system onto your target laptop.

**Prerequisites on your host machine:**

*   A Debian-based Linux distribution (e.g., Debian, Ubuntu).
*   Root privileges (`sudo`).
*   Required tools: `debootstrap`, `xorriso`, `qemu-utils`, `git`, `wget`, `tar`, `gzip`, `bzip2`, `xz-utils`, `gcc`, `make`, `dpkg-dev`, `pkg-config`, `dialog`, `lsblk`, `cpio`, `bc`, `kmod`, `flex`, `bison`, `libssl-dev`, `libelf-dev`, `pahole`, `python3`, `python3-pyelftools`, `debianutils`, `firmware-linux-free`, `firmware-misc-nonfree`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`.
*   **Manual Step:** Before building, you must manually download the Google Chrome `.deb` package for Debian/Ubuntu (`google-chrome-stable_current_amd64.deb`) and place it in a `debs/` directory at the root of the project. This file is not tracked in the Git repository due to its large size.

**Steps to Build:**

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/your-username/hardened-debian-builder.git
    cd hardened-debian-builder
    ```
    (Replace `https://github.com/your-username/hardened-debian-builder.git` with the actual repository URL.)

2.  **Make the Build Script Executable:**
    ```bash
    chmod +x ./build.sh
    ```

3.  **Run the Build Script:**
    The `build.sh` script is the single entrypoint to generate the ISO. It will automatically handle pre-building the custom kernel and optimized libraries, and then package everything into a bootable ISO.

    ```bash
    sudo ./build.sh --config hardened-os.conf --output hardened-debian-installer.iso
    ```
    *   `--config hardened-os.conf`: Specifies the configuration file to use. You can customize `hardened-os.conf` to adjust kernel version, specific flags, etc.
    *   `--output hardened-debian-installer.iso`: Defines the name of the output ISO file.

    The build process will be verbose, providing real-time feedback on kernel compilation, library optimization, and ISO creation. This process can take a significant amount of time depending on your host machine's resources.

---

## Installing on the Target Laptop

1.  **Create a Bootable USB Drive:**
    Use a tool like `dd`, Rufus, or Etcher to write the generated `hardened-debian-installer.iso` to a USB flash drive.
    ```bash
    # Replace /dev/sdX with your USB drive (BE CAREFUL, DATA WILL BE ERASED!)
    sudo dd if=hardened-debian-installer.iso of=/dev/sdX bs=4M status=progress
    ```

2.  **Boot the Target Laptop:**
    Boot your HP Pavilion laptop from the newly created USB drive. Ensure UEFI boot mode is enabled in your BIOS/UEFI settings.

3.  **Follow the TUI Installer:**
    The system will boot directly into an interactive Text User Interface (TUI). Follow the on-screen prompts to:
    *   Select the target disk for installation (which will be completely wiped).
    *   Enter a strong LUKS passphrase for full disk encryption.
    *   Set the system hostname.
    *   Choose additional hardening features and your desired Desktop Environment (KDE Plasma by default).

4.  **Enjoy Your Hardened Debian System!**
    Once the installation is complete, reboot your laptop. You will be prompted for your LUKS passphrase at boot, followed by logging into your new, secure, and optimized Debian system.

---

## Customization

The `hardened-os.conf` file is the central place for customization. You can modify parameters such as:

*   `KERNEL_SOURCE_URL`: To use a different kernel version.
*   `KERNEL_CONFIG_TEMPLATE`: To point to a custom kernel `.config` file.
*   Compiler Flags (`CFLAGS_BASELINE`, `CFLAGS_HOT`, etc.): To adjust optimization levels or hardening flags.
*   `ACCEL_BUILD_*`: To select which specific accelerated libraries to build.
*   `DESKTOP_ENVIRONMENT`, `KDE_DEFAULT_THEME`: To change desktop options.
*   `PREBUILD_CUSTOM_KERNEL`, `PREBUILD_ACCEL_LIBS`: To switch between pre-building on host or building on target (though pre-building is recommended for ease of use).

---

## Development & Maintenance

*   All scripts are written in `bash` and adhere to `set -Eeuo pipefail`.
*   Configuration is separated from logic in `hardened-os.conf`.
*   The project uses `dialog` for TUI interactions.
*   Modular structure (e.g., `build_custom_kernel.sh`, `build_accel_libs.sh`) is maintained for clarity and reusability.
*   For any issues or contributions, please refer to the GitHub repository.
