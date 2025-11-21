#!/usr/bin/env bash
set -Eeuo pipefail

# This script sets the ImageHarden applications as the default handlers for various media MIME types.

log_mime(){
  echo "[MIME-UPDATE] $1"
}

MIME_CONFIG="/etc/xdg/mimeapps.list"

log_mime "Updating MIME type associations in ${MIME_CONFIG}..."

# Ensure the [Default Applications] section exists
if ! grep -q "\[Default Applications\]" "${MIME_CONFIG}"; then
  echo -e "\n[Default Applications]" >> "${MIME_CONFIG}"
fi

# Associate image types
sed -i '/\[Default Applications\]/a \
image/png=imageharden-image.desktop\
image/jpeg=imageharden-image.desktop\
image/gif=imageharden-image.desktop\
image/bmp=imageharden-image.desktop\
image/svg+xml=imageharden-image.desktop\
' "${MIME_CONFIG}"

# Associate audio types
sed -i '/\[Default Applications\]/a \
audio/mpeg=imageharden-audio.desktop\
audio/ogg=imageharden-audio.desktop\
audio/vorbis=imageharden-audio.desktop\
audio/x-flac=imageharden-audio.desktop\
audio/opus=imageharden-audio.desktop\
' "${MIME_CONFIG}"

# Associate video types
sed -i '/\[Default Applications\]/a \
video/mp4=imageharden-video.desktop\
video/webm=imageharden-video.desktop\
video/x-matroska=imageharden-video.desktop\
video/x-msvideo=imageharden-video.desktop\
' "${MIME_CONFIG}"

log_mime "MIME type associations updated."

# Update the MIME database
if command -v update-mime-database &> /dev/null; then
  log_mime "Updating MIME database..."
  update-mime-database /usr/share/mime
fi
