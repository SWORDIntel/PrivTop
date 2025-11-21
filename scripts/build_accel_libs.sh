#!/usr/bin/env bash
set -Eeuo pipefail

# Helper function for logging
log() {
  local level="${1}"
  local message="${2}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] [ACCEL] [${level}] ${message}"
}

error_exit() {
  log "ERROR" "${1}" >&2
  exit 1
}

# Configuration file passed as argument, default to current directory
CONFIG_FILE="${1:-./hardened-os.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
  error_exit "Config file not found: $CONFIG_FILE"
fi

# shellcheck source=/dev/null
. "$CONFIG_FILE"

log "INFO" "Starting accelerated library build."
log "INFO" "Target install prefix: ${ACCEL_PREFIX}"

# Create working directory
BUILD_DIR="/tmp/accel_build_$(date +%s)"
mkdir -p "${BUILD_DIR}" || error_exit "Failed to create build directory ${BUILD_DIR}"
cd "${BUILD_DIR}" || error_exit "Failed to change to build directory ${BUILD_DIR}"

install_build_deps() {
  log "INFO" "Installing common build dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || error_exit "apt-get update failed"
  apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    ca-certificates \
    wget \
    tar \
    gzip \
    bzip2 \
    xz-utils \
    git \
    cmake \
    autopoint \
    autoconf \
    libtool \
    nasm \
    yasm \
    python3 \
    texinfo \
    perl \
    patch \
    libnuma-dev \
    libssl-dev || error_exit "Failed to install common build dependencies"
  apt-get clean
}

install_build_deps

log "INFO" "Using CFLAGS_BASELINE: ${CFLAGS_BASELINE}"
log "INFO" "Using LDFLAGS_BASELINE: ${LDFLAGS_BASELINE}"
log "INFO" "Using CFLAGS_HOT: ${CFLAGS_HOT}"
log "INFO" "Using LDFLAGS_HOT: ${LDFLAGS_HOT}"


# --- Function to build a library ---
build_library() {
  local lib_name="$1"
  local download_url="$2"
  local extract_cmd="$3"
  local configure_cmd="$4"
  local custom_cflags="$5"
  local custom_ldflags="$6"
  local custom_build_cmd="${7:-make -j$(nproc)}"
  local expected_sha256sum="$8" # New parameter for SHA256 sum
  
  log "INFO" "Building ${lib_name} with CFLAGS='${custom_cflags}' LDFLAGS='${custom_ldflags}'..."
  local src_dir_name
  src_dir_name=$(basename "$(echo "${download_url}" | sed -E 's/\.tar(\.[gx]z|\.bz2|\.zip)?$//' | sed 's/\.git$//')") # Handle .git too
  local src_dir="${BUILD_DIR}/${src_dir_name}"
  
  mkdir -p "${src_dir}"

  log "INFO" "Downloading ${lib_name} from ${download_url}..."
  if [[ "${download_url}" == *.git ]]; then
    log "WARN" "Checksum verification skipped for git repository: ${lib_name}."
    git clone --depth 1 "${download_url}" "${src_dir}" || error_exit "Failed to clone ${lib_name} git repo"
  else
    local downloaded_file="${BUILD_DIR}/$(basename "${download_url}")" # Use original filename for downloaded file
    wget -q -O "${downloaded_file}" "${download_url}" || error_exit "Failed to download ${lib_name} from ${download_url}"

    # Verify SHA256 sum
    if [ -n "${expected_sha256sum}" ] && [ "${expected_sha256sum}" != "<PLACEHOLDER_${lib_name^^}_SHA256SUM>" ]; then
      log "INFO" "Verifying SHA256 sum of ${lib_name}..."
      echo "${expected_sha256sum}  ${downloaded_file}" | sha256sum -c || error_exit "SHA256 sum verification failed for ${lib_name}."
    else
      log "WARN" "${lib_name} SHA256 sum is not set or is a placeholder. Skipping SHA256 verification."
    fi

    ${extract_cmd} -f "${downloaded_file}" -C "${src_dir}" --strip-components=1 || error_exit "Failed to extract ${lib_name}"
    rm "${downloaded_file}" # Clean up downloaded tarball
  fi

  cd "${src_dir}" || error_exit "Failed to change to ${src_dir}"

  # Set compiler flags for this build
  export CFLAGS="${custom_cflags}"
  export CXXFLAGS="${custom_cflags}"
  export LDFLAGS="${custom_ldflags} -L${ACCEL_PREFIX}/lib -Wl,-rpath=${ACCEL_PREFIX}/lib"
  export PKG_CONFIG_PATH="${ACCEL_PREFIX}/lib/pkgconfig" # For finding installed libs

  log "INFO" "Configuring ${lib_name}..."
  # Handle different configure commands (autotools, cmake)
  if [[ "${configure_cmd}" == *cmake* ]]; then
    mkdir -p build && cd build || error_exit "Failed to create/cd into build directory"
    # Pass custom CFLAGS/LDFLAGS explicitly for CMake
    cmake -DCMAKE_C_FLAGS="${CFLAGS}" -DCMAKE_CXX_FLAGS="${CXXFLAGS}" -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" "-DCMAKE_INSTALL_PREFIX=${ACCEL_PREFIX}" .. || error_exit "Failed to configure ${lib_name} with CMake"
    custom_build_cmd="cmake --build . -- -j$(nproc)" # Adjust build command for CMake
  else
    ${configure_cmd} --prefix="${ACCEL_PREFIX}" || error_exit "Failed to configure ${lib_name}"
  fi

  log "INFO" "Compiling ${lib_name}..."
  ${custom_build_cmd} || error_exit "Failed to compile ${lib_name}"

  log "INFO" "Installing ${lib_name}..."
  if [[ "${configure_cmd}" == *cmake* ]]; then
    cmake --install . || error_exit "Failed to install ${lib_name} with CMake"
  else
    make install || error_exit "Failed to install ${lib_name}"
  fi

  # Cleanup
  log "INFO" "Cleaning up ${lib_name} build artifacts..."
  cd "${BUILD_DIR}" || error_exit "Failed to change back to build directory"
  rm -rf "${src_dir}" || log "WARN" "Failed to remove ${src_dir}"
}

# --- Build individual libraries based on config ---

# Crypto / TLS
if [ "${ACCEL_BUILD_OPENSSL}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_OPENSSL is enabled. Building OpenSSL."
  build_library "OpenSSL" \
    "${OPENSSL_SOURCE_URL}" \
    "tar -xzf -" \
    "./config no-shared zlib --prefix=${ACCEL_PREFIX}" \
    "${CFLAGS_BASELINE}" "${LDFLAGS_BASELINE}" \
    "" \
    "${OPENSSL_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_LIBSODIUM}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_LIBSODIUM is enabled. Building libsodium."
  build_library "libsodium" \
    "${LIBSODIUM_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure" \
    "${CFLAGS_BASELINE}" "${LDFLAGS_BASELINE}" \
    "" \
    "${LIBSODIUM_SOURCE_SHA256SUM}"
fi

# Compression / archiving
if [ "${ACCEL_BUILD_ZSTD}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_ZSTD is enabled. Building zstd."
  build_library "zstd" \
    "${ZSTD_SOURCE_URL}" \
    "tar -xzf -" \
    "make -C build/cmake" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "cmake --build build/cmake --target install" \
    "${ZSTD_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_LZMA}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_LZMA is enabled. Building liblzma (xz)."
  build_library "xz" \
    "${LZMA_SOURCE_URL}" \
    "tar -xJf -" \
    "./configure --disable-doc --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-shared --enable-static" \
    "${CFLAGS_BASELINE}" "${LDFLAGS_BASELINE}" \
    "" \
    "${LZMA_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_ZLIBNG}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_ZLIBNG is enabled. Building zlib-ng."
  build_library "ZLIBNG" \
    "${ZLIBNG_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --zlib-compat" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${ZLIBNG_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_BROTLI}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_BROTLI is enabled. Building brotli."
  build_library "brotli" \
    "${BROTLI_SOURCE_URL}" \
    "tar -xzf -" \
    "cmake -S . -B out -DCMAKE_BUILD_TYPE=Release" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${BROTLI_SOURCE_SHA256SUM}"
fi

# Media / codecs
if [ "${ACCEL_BUILD_FFMPEG}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_FFMPEG is enabled. Building FFmpeg."
  # FFmpeg build is complex, requires many dependencies.
  # For simplicity, we'll aim for a basic build with common codecs.
  build_library "FFmpeg" \
    "${FFMPEG_SOURCE_URL}" \
    "tar -xJf -" \
    "./configure --enable-shared --disable-static --enable-pic \
      --enable-gpl --enable-version3 \
      --disable-doc --disable-programs --disable-avdevice \
      --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom \
      --enable-libopus --enable-libvorbis --enable-libflac --enable-libmp3lame \
      --extra-cflags='${CFLAGS_HOT}' --extra-ldflags='${LDFLAGS_HOT}'" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${FFMPEG_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_X264}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_X264 is enabled. Building x264."
  build_library "x264" \
    "${X264_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --enable-static --disable-cli --enable-pic" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${X264_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_X265}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_X265 is enabled. Building x265."
  build_library "x265" \
    "${X265_SOURCE_URL}" \
    "tar -xzf -" \
    "cmake -G \"Unix Makefiles\" -DCMAKE_INSTALL_PREFIX=${ACCEL_PREFIX}/x265 -DENABLE_SHARED=OFF -DENABLE_CLI=OFF ../source" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${X265_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_LIBVPX}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_LIBVPX is enabled. Building libvpx."
  build_library "libvpx" \
    "${LIBVPX_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --enable-vp8 --enable-vp9 --enable-vp9-postproc --enable-pic --disable-docs --enable-shared --disable-static" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${LIBVPX_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_LIBAOM}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_LIBAOM is enabled. Building libaom."
  build_library "libaom" \
    "${LIBAOM_SOURCE_URL}" \
    "tar -xzf -" \
    "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${LIBAOM_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_OPUS}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_OPUS is enabled. Building libopus."
  build_library "opus" \
    "${OPUS_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --disable-static --enable-shared --disable-doc" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${OPUS_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_VORBIS}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_VORBIS is enabled. Building libvorbis."
  build_library "libvorbis" \
    "${VORBIS_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --disable-static --enable-shared --disable-docs" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${VORBIS_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_FLAC}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_FLAC is enabled. Building libFLAC."
  build_library "flac" \
    "${FLAC_SOURCE_URL}" \
    "tar -xJf -" \
    "./configure --disable-static --enable-shared --disable-docs" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${FLAC_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_MP3LAME}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_MP3LAME is enabled. Building libmp3lame."
  build_library "lame" \
    "${MP3LAME_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --disable-static --enable-shared --disable-gtktest --disable-frontend" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${MP3LAME_SOURCE_SHA256SUM}"
fi

# Images / GUI stack
if [ "${ACCEL_BUILD_LIBPNG}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_LIBPNG is enabled. Building libpng."
  build_library "libpng" \
    "${LIBPNG_SOURCE_URL}" \
    "tar -xJf -" \
    "./configure" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${LIBPNG_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_LIBJPEG_TURBO}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_LIBJPEG_TURBO is enabled. Building libjpeg-turbo."
  build_library "libjpeg-turbo" \
    "${LIBJPEG_TURBO_SOURCE_URL}" \
    "tar -xzf -" \
    "cmake -S . -B build -DWITH_JPEG8=ON -DCMAKE_INSTALL_LIBDIR=lib" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${LIBJPEG_TURBO_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_LIBWEBP}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_LIBWEBP is enabled. Building libwebp."
  build_library "libwebp" \
    "${LIBWEBP_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --enable-libwebpmux --enable-libwebpdemux" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${LIBWEBP_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_PIXMAN}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_PIXMAN is enabled. Building pixman."
  build_library "pixman" \
    "${PIXMAN_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --enable-shared --disable-static" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "" \
    "${PIXMAN_SOURCE_SHA256SUM}"
fi

# System / misc
if [ "${ACCEL_BUILD_SQLITE}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_SQLITE is enabled. Building SQLite."
  build_library "sqlite" \
    "${SQLITE_SOURCE_URL}" \
    "tar -xzf -" \
    "./configure --enable-shared --disable-static --disable-editline" \
    "${CFLAGS_BASELINE}" "${LDFLAGS_BASELINE}" \
    "" \
    "${SQLITE_SOURCE_SHA256SUM}"
fi

if [ "${ACCEL_BUILD_OPENBLAS}" -eq 1 ]; then
  log "INFO" "ACCEL_BUILD_OPENBLAS is enabled. Building OpenBLAS."
  build_library "OpenBLAS" \
    "${OPENBLAS_SOURCE_URL}" \
    "tar -xzf -" \
    "make TARGET=SKYLAKEX DYNAMIC_ARCH=1 CFLAGS='${CFLAGS_HOT}' FCFLAGS='${CFLAGS_HOT}'" \
    "${CFLAGS_HOT}" "${LDFLAGS_HOT}" \
    "make install" \
    "${OPENBLAS_SOURCE_SHA256SUM}"
fi

log "INFO" "Accelerated library build process finished."

# Cleanup working directory
cd /tmp || error_exit "Failed to change to /tmp" # Ensures we are not in BUILD_DIR when trying to remove it
rm -rf "${BUILD_DIR}" || log "WARN" "Failed to remove build directory ${BUILD_DIR}"

exit 0
