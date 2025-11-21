#!/bin/bash
set -e

# Clone the emsdk repository if it doesn't exist
if [ ! -d "emsdk" ]; then
  git clone https://github.com/emscripten-core/emsdk.git
fi

# Enter the emsdk directory
cd emsdk

# Install the latest version of the SDK
./emsdk install latest

# Activate the latest version of the SDK
./emsdk activate latest

echo "Emscripten SDK is set up and activated."
