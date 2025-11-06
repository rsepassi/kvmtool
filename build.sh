#!/bin/bash
set -e

echo "=== kvmtool Static Build Script ==="
echo

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
TARGET_ARCH=""
SHOW_HELP=0

usage() {
    echo "Usage: $0 [ARCH]"
    echo
    echo "Build static lkvm binary for specified architecture."
    echo
    echo "Supported architectures:"
    echo "  x86_64, x86-64, amd64    - x86 64-bit"
    echo "  arm64, aarch64           - ARM 64-bit"
    echo "  riscv64                  - RISC-V 64-bit"
    echo
    echo "Examples:"
    echo "  $0 arm64       # Build for ARM64"
    echo "  $0 x86_64      # Build for x86_64"
    echo "  $0             # Build for host architecture"
    echo
    exit 0
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

TARGET_ARCH="${1:-$(uname -m)}"

# Normalize architecture names
case "$TARGET_ARCH" in
    x86_64|x86-64|amd64)
        KVMTOOL_ARCH="x86"
        ARCH_NAME="x86_64"
        CLANG_TARGET="x86_64-linux-gnu"
        CONSOLE_TYPE="ttyS0"
        NEEDS_LIBFDT=0
        ;;
    arm64|aarch64)
        KVMTOOL_ARCH="arm64"
        ARCH_NAME="arm64"
        CLANG_TARGET="aarch64-linux-gnu"
        CONSOLE_TYPE="ttyAMA0"
        NEEDS_LIBFDT=1
        ;;
    riscv64|riscv)
        KVMTOOL_ARCH="riscv"
        ARCH_NAME="riscv64"
        CLANG_TARGET="riscv64-linux-gnu"
        CONSOLE_TYPE="ttyS0"
        NEEDS_LIBFDT=1
        RISCV_XLEN=64
        ;;
    *)
        echo -e "${RED}Error: Unsupported architecture '$TARGET_ARCH'${NC}"
        echo "Supported: x86_64, arm64, riscv64"
        echo "Run '$0 --help' for more information"
        exit 1
        ;;
esac

echo "Target architecture: $ARCH_NAME"
echo "kvmtool ARCH: $KVMTOOL_ARCH"
echo "Clang target: $CLANG_TARGET"
echo

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
check_package "Clang compiler" "clang" || MISSING_DEPS=1
check_package "GNU Make" "make" || MISSING_DEPS=1
check_package "binutils (ld)" "ld" || MISSING_DEPS=1

# Check for clang target support
if command_exists "clang"; then
    if clang --target=$CLANG_TARGET --print-targets >/dev/null 2>&1 || \
       clang --target=$CLANG_TARGET -x c - -o /dev/null 2>/dev/null <<< "int main(){return 0;}"; then
        echo -e "${GREEN}✓${NC} Clang supports target $CLANG_TARGET"
    else
        echo -e "${YELLOW}!${NC} Warning: Could not verify clang target support for $CLANG_TARGET"
        echo "    Build may fail if target is not supported"
    fi
fi

# Check for static libc for target architecture
LIBC_PATHS=(
    "/usr/lib/$CLANG_TARGET/libc.a"
    "/usr/$CLANG_TARGET/lib/libc.a"
    "/usr/lib/libc.a"
)

LIBC_FOUND=0
for path in "${LIBC_PATHS[@]}"; do
    if [ -f "$path" ]; then
        echo -e "${GREEN}✓${NC} Static libc found: $path"
        LIBC_FOUND=1
        break
    fi
done

if [ $LIBC_FOUND -eq 0 ]; then
    # Try to compile a test
    if clang --target=$CLANG_TARGET -static -x c - -o /tmp/test.$$ 2>/dev/null <<< "int main(){return 0;}"; then
        echo -e "${GREEN}✓${NC} Static libc available for $CLANG_TARGET"
        rm -f /tmp/test.$$
    else
        echo -e "${RED}✗${NC} Static libc not found for $CLANG_TARGET"
        echo "    Install the appropriate libc-dev package for your target"
        MISSING_DEPS=1
    fi
fi

# Check for libfdt if needed (ARM64, RISC-V)
if [ $NEEDS_LIBFDT -eq 1 ]; then
    LIBFDT_FOUND=0

    if pkg-config --exists libfdt 2>/dev/null; then
        echo -e "${GREEN}✓${NC} libfdt found (via pkg-config)"
        LIBFDT_FOUND=1
    else
        # Check for static library in target-specific paths
        LIBFDT_PATHS=(
            "/usr/lib/$CLANG_TARGET/libfdt.a"
            "/usr/$CLANG_TARGET/lib/libfdt.a"
            "/usr/lib/libfdt.a"
        )

        for path in "${LIBFDT_PATHS[@]}"; do
            if [ -f "$path" ]; then
                echo -e "${GREEN}✓${NC} libfdt found: $path"
                LIBFDT_FOUND=1
                break
            fi
        done

        if [ $LIBFDT_FOUND -eq 0 ] && [ -f /usr/include/libfdt.h ]; then
            echo -e "${GREEN}✓${NC} libfdt headers found"
            LIBFDT_FOUND=1
        fi
    fi

    if [ $LIBFDT_FOUND -eq 0 ]; then
        echo -e "${RED}✗${NC} libfdt not found (required for $ARCH_NAME)"
        echo "    Install with:"
        echo "      Debian/Ubuntu: apt-get install libfdt-dev"
        echo "      RHEL/CentOS:   yum install libfdt-devel"
        echo "      Alpine:        apk add dtc-dev"
        MISSING_DEPS=1
    fi
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
    echo "  apt-get install clang lld make libfdt-dev"
    echo
    echo "For cross-compilation, you may also need:"
    echo "  apt-get install libc6-dev-\${ARCH}-cross"
    echo
    echo "On Alpine Linux, install with:"
    echo "  apk add clang lld make dtc-dev musl-dev"
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
echo "Building static lkvm for $ARCH_NAME..."
echo

# Set up build environment
export CC="clang --target=$CLANG_TARGET"
export ARCH="$KVMTOOL_ARCH"

# Add RISC-V specific flags if needed
if [ "$KVMTOOL_ARCH" = "riscv" ]; then
    export RISCV_XLEN=64
fi

# Build with explicit architecture
echo "Build command: ARCH=$KVMTOOL_ARCH CC=\"$CC\" make lkvm-static -j$(nproc)"
echo

ARCH="$KVMTOOL_ARCH" CC="$CC" make lkvm-static -j$(nproc)

echo
if [ -f lkvm-static ]; then
    # Rename to include architecture
    OUTPUT_NAME="lkvm-static-${ARCH_NAME}"
    mv lkvm-static "$OUTPUT_NAME"

    echo -e "${GREEN}✓ Build successful!${NC}"
    echo

    # Show binary info
    ls -lh "$OUTPUT_NAME"
    echo

    # Show file type
    file "$OUTPUT_NAME"
    echo

    # Verify it's statically linked
    if file "$OUTPUT_NAME" | grep -q "statically linked"; then
        echo -e "${GREEN}✓ Binary is statically linked${NC}"
    else
        echo -e "${YELLOW}! Warning: Binary may not be fully static${NC}"
    fi

    # Show size
    SIZE=$(stat -c%s "$OUTPUT_NAME" 2>/dev/null || stat -f%z "$OUTPUT_NAME" 2>/dev/null)
    SIZE_MB=$(echo "scale=2; $SIZE / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
    echo "Binary size: $SIZE_MB MB"

    echo
    echo -e "${GREEN}Build complete!${NC}"
    echo "Static binary: ./$OUTPUT_NAME"
    echo "Console device: $CONSOLE_TYPE"
else
    echo -e "${RED}✗ Build failed!${NC}"
    exit 1
fi
