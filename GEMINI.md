# GEMINI.md

## Project Overview

This project contains a set of scripts to build and install a hardened Debian-based operating system. The goal is to automate the creation of a secure environment featuring full-disk encryption (LUKS2), a custom-tuned kernel, and various system-level security mitigations.

The installation process is managed by a simple Text User Interface (TUI) that guides the user through disk selection and passphrase setup. The configuration is highly customizable through the central `hardened-os.conf` file.

The main technologies used are shell scripting (`bash`), `dialog` for the TUI, `debootstrap` for creating the base Debian system, and `cryptsetup` for encryption.

## Key Files and Scripts

*   `hardened-os.conf`: The central configuration file. This is where you define all parameters for the build, including target disk, encryption settings, kernel version, hostname, and which hardening features to enable.
*   `scripts/tui-installer.sh`: The main entry point for the end-user. This script provides an interactive TUI to select the target device and set credentials. It orchestrates the installation by calling other build scripts.
*   `scripts/build_hardened_target.sh`: The core installation script (currently a stub). It is responsible for partitioning the disk, setting up LUKS encryption, de-bootstrapping the Debian base system, and applying all the hardening configurations from the `templates`.
*   `scripts/build_iso.sh`: A script (currently a stub) intended to package the entire installer and its components into a bootable `.iso` image.
*   `scripts/install_privacy_tools.sh` & `scripts/setup_mac_randomization.sh`: Scripts to install and configure additional privacy and security features like MAC address randomization and a TOR/I2P stack.
*   `templates/90-hardened.conf`: A sysctl configuration template that applies numerous kernel-level security settings to harden the system against various attacks.
*   `templates/grub-40_custom.stub`: A template for creating a password-protected GRUB bootloader configuration.

## Building and Running

The project is designed to be run from a live Linux environment (e.g., a Debian Live CD) to install the hardened OS onto a target machine.

While the build scripts are currently stubs, the intended workflow is as follows:

1.  **Build the Installer ISO (Hypothetical):**
    ```bash
    # This script is a stub and needs to be implemented
    sudo ./scripts/build_iso.sh
    ```
    This would produce a `hardened-debian.iso` file.

2.  **Run the Installer:**
    *   Boot a machine from the generated ISO.
    *   The system should automatically launch the TUI installer.
    *   Alternatively, to run the installer manually from a live environment where the scripts are present:
    ```bash
    # You must be root to run the installer
    sudo ./scripts/tui-installer.sh
    ```

## Development Conventions

*   All scripts are written in `bash` and should adhere to `set -Eeuo pipefail` for robust error handling.
*   Configuration is kept separate from logic. The `hardened-os.conf` file drives the behavior of the installation scripts.
*   The project uses a TUI based on the `dialog` utility, indicating a preference for simple, terminal-based interfaces.
*   Functionality is split into logical scripts (e.g., `build_iso`, `build_hardened_target`), even though some are currently stubs. This modular structure should be maintained.
