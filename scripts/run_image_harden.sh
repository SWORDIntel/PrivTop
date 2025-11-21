#!/usr/bin/env bash
set -Eeuo pipefail

# This script is a wrapper for image_harden_cli that detects if it's running
# in a Xen environment and passes the appropriate profile.

IMAGE_HARDEN_CLI="/usr/local/bin/image_harden_cli"
DEFAULT_PROFILE="hardened-debian-media"
XEN_DOM0_PROFILE="hardened-debian-media-dom0" # Assumes a separate profile for dom0
XEN_DOMU_PROFILE="hardened-debian-media-domU" # Assumes a separate profile for domU

if [ -d /proc/xen ]; then
  # We are in a Xen environment. Check if we are dom0.
  if [ -f /proc/xen/capabilities ] && grep -q "control_d" /proc/xen/capabilities; then
    echo "Running in Xen Dom0. Using ${XEN_DOM0_PROFILE} profile."
    exec "${IMAGE_HARDEN_CLI}" --daemon --profile "${XEN_DOM0_PROFILE}" "$@"
  else
    echo "Running in Xen DomU. Using ${XEN_DOMU_PROFILE} profile."
    exec "${IMAGE_HARDEN_CLI}" --daemon --profile "${XEN_DOMU_PROFILE}" "$@"
  fi
else
  echo "Not running in Xen. Using default profile."
  exec "${IMAGE_HARDEN_CLI}" --daemon --profile "${DEFAULT_PROFILE}" "$@"
fi
