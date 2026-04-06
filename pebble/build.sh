#!/bin/bash
#
# Trio CGM - Pebble Build Script
# Builds and optionally installs the Pebble watch app
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "================================"
echo "Trio CGM - Pebble Build Script"
echo "================================"
echo ""

# Check for Pebble SDK
if ! command -v pebble &> /dev/null; then
    echo "Pebble SDK not found!"
    echo ""
    echo "Install options:"
    echo "  macOS:  brew install pebble-sdk"
    echo "  Linux:  pip install pebble-sdk"
    echo "  Docker: docker run -v \$PWD:/app rebble/pebble-sdk pebble build"
    echo ""
    exit 1
fi

echo "Pebble SDK found: $(pebble --version 2>/dev/null || echo 'installed')"
echo ""

# Clean previous builds
echo "Cleaning previous builds..."
rm -rf build/
rm -f *.pbw

# Build the app
echo "Building Trio CGM..."
pebble build

if [ $? -eq 0 ]; then
    echo ""
    echo "Build successful!"
    echo ""

    PBW_FILE=$(find build -name "*.pbw" 2>/dev/null | head -1)

    if [ -n "$PBW_FILE" ]; then
        cp "$PBW_FILE" "./trio-cgm.pbw"
        echo "Package: trio-cgm.pbw"
        echo "Size: $(du -h trio-cgm.pbw | cut -f1)"
        echo ""
    fi
else
    echo ""
    echo "Build failed!"
    exit 1
fi

echo "================================"
echo "Install Options:"
echo "================================"
echo ""
echo "1. Install via phone IP:"
echo "   pebble install --phone <your-phone-ip>"
echo ""
echo "2. Install via Rebble cloud:"
echo "   pebble install --cloudpebble"
echo ""
echo "3. Side-load:"
echo "   Transfer trio-cgm.pbw to your phone and open with Pebble app"
echo ""

# Handle --install flag
if [ "$1" == "--install" ]; then
    echo "Installing to Pebble..."
    if [ -n "$2" ]; then
        pebble install --phone "$2"
    else
        pebble install --cloudpebble
    fi
fi

echo "Done!"
