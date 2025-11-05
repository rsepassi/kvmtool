#!/bin/bash
set -e

echo "=== kvmtool Static Build Script ==="
echo

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running on arm64
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo -e "${YELLOW}Warning: Detected architecture '$ARCH', but building for arm64${NC}"
    echo "Cross-compilation may require additional setup."
fi

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check for package
check_package() {
    local pkg=$1
    local cmd=$2

    if command_exists "$cmd"; then
        echo -e "${GREEN}✓${NC} $pkg found"
        return 0
    else
        echo -e "${RED}✗${NC} $pkg not found"
        return 1
    fi
}

# Check for required dependencies
echo "Checking build dependencies..."
echo

MISSING_DEPS=0

# Essential build tools
check_package "GCC compiler" "gcc" || MISSING_DEPS=1
check_package "GNU Make" "make" || MISSING_DEPS=1
check_package "binutils (ld)" "ld" || MISSING_DEPS=1

# Check for static libc
if [ -f /usr/lib/aarch64-linux-gnu/libc.a ] || \
   [ -f /usr/lib/arm64-linux-gnu/libc.a ] || \
   [ -f /usr/lib/libc.a ] || \
   gcc -static -x c - -o /dev/null 2>/dev/null <<< "int main(){return 0;}"; then
    echo -e "${GREEN}✓${NC} Static libc found"
else
    echo -e "${RED}✗${NC} Static libc not found (required for static linking)"
    MISSING_DEPS=1
fi

# Check for libfdt (device tree library - required for ARM64)
if pkg-config --exists libfdt 2>/dev/null; then
    echo -e "${GREEN}✓${NC} libfdt found (via pkg-config)"
elif [ -f /usr/lib/aarch64-linux-gnu/libfdt.a ] || \
     [ -f /usr/lib/arm64-linux-gnu/libfdt.a ] || \
     [ -f /usr/lib/libfdt.a ]; then
    echo -e "${GREEN}✓${NC} libfdt found (static library)"
elif [ -f /usr/include/libfdt.h ]; then
    echo -e "${GREEN}✓${NC} libfdt headers found"
else
    echo -e "${RED}✗${NC} libfdt not found (required for ARM64)"
    echo "    Install with: apt-get install libfdt-dev (Debian/Ubuntu)"
    echo "                  yum install libfdt-devel (RHEL/CentOS)"
    MISSING_DEPS=1
fi

# Optional but recommended
if command_exists "objcopy"; then
    echo -e "${GREEN}✓${NC} objcopy found"
else
    echo -e "${YELLOW}!${NC} objcopy not found (optional)"
fi

echo

# Exit if missing critical dependencies
if [ $MISSING_DEPS -eq 1 ]; then
    echo -e "${RED}Error: Missing required dependencies${NC}"
    echo
    echo "On Debian/Ubuntu, install with:"
    echo "  apt-get install build-essential libfdt-dev"
    echo
    echo "On Alpine Linux, install with:"
    echo "  apk add build-base dtc-dev"
    echo
    exit 1
fi

echo -e "${GREEN}All dependencies satisfied${NC}"
echo

# Clean previous builds
echo "Cleaning previous builds..."
make clean 2>/dev/null || true
echo

# Build static lkvm
echo "Building static lkvm for arm64..."
echo

# Force ARM64 architecture and build static version
ARCH=arm64 make lkvm-static -j$(nproc)

echo
if [ -f lkvm-static ]; then
    echo -e "${GREEN}✓ Build successful!${NC}"
    echo

    # Show binary info
    ls -lh lkvm-static
    echo

    # Verify it's statically linked
    if file lkvm-static | grep -q "statically linked"; then
        echo -e "${GREEN}✓ Binary is statically linked${NC}"
    else
        echo -e "${YELLOW}! Warning: Binary may not be fully static${NC}"
        file lkvm-static
    fi

    # Show size
    SIZE=$(stat -c%s lkvm-static 2>/dev/null || stat -f%z lkvm-static 2>/dev/null)
    SIZE_MB=$(echo "scale=2; $SIZE / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
    echo "Binary size: $SIZE_MB MB"

    echo
    echo -e "${GREEN}Build complete!${NC}"
    echo "Static binary: ./lkvm-static"
else
    echo -e "${RED}✗ Build failed!${NC}"
    exit 1
fi
