#!/bin/bash
set -e

# Activate the Emscripten SDK
source ./emsdk/emsdk_env.sh

# Enter the FFmpeg directory
cd ffmpeg

# Configure FFmpeg for a minimal Wasm build
emconfigure ./configure \
    --cc="emcc" \
    --cxx="em++" \
    --ar="emar" \
    --ranlib="emranlib" \
    --prefix=$(pwd)/dist \
    --target-os=none \
    --arch=x86_32 \
    --enable-cross-compile \
    --disable-x86asm \
    --disable-inline-asm \
    --disable-programs \
    --disable-doc \
    --disable-network \
    --disable-everything \
    --enable-decoder=h264 \
    --enable-demuxer=mov \
    --enable-parser=h264

# Build FFmpeg
emmake make -j"$(nproc)"
emmake make install

# Copy the Wasm file to the root directory
cp dist/bin/ffmpeg.wasm ../ffmpeg.wasm

echo "FFmpeg has been successfully built to ffmpeg.wasm"
