#!/bin/bash
# This script is designed to be run as init (PID 1)
# It sets up networking and execs into the lkvm guest VM

set -e

# Paths - adjust these as needed
LKVM="/lkvm-static"
KERNEL="/kernel"
DISK="/disk.img"

# Network configuration
TAP_DEVICE="tap0"
TAP_IP="10.0.0.1"
TAP_SUBNET="10.0.0.0/24"
GUEST_IP="10.0.0.2"
GATEWAY="10.0.0.1"

# Log helper
log() {
    echo "[init] $*"
}

error() {
    echo "[init] ERROR: $*" >&2
    # If we're PID 1, we can't exit, so sleep forever
    if [ $$ -eq 1 ]; then
        log "Sleeping forever (cannot exit as PID 1)"
        sleep infinity
    else
        exit 1
    fi
}

# Check if we're running as root
if [ "$(id -u)" -ne 0 ]; then
    error "Must run as root"
fi

log "Starting kvmtool init"

# Check for required files
if [ ! -f "$LKVM" ]; then
    error "lkvm binary not found at $LKVM"
fi

if [ ! -x "$LKVM" ]; then
    log "Making lkvm executable"
    chmod +x "$LKVM"
fi

if [ ! -f "$KERNEL" ]; then
    error "Kernel not found at $KERNEL"
fi

if [ ! -f "$DISK" ]; then
    error "Disk image not found at $DISK"
fi

# Detect total system RAM (in MB)
log "Detecting system resources..."
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
GUEST_RAM_MB=$((TOTAL_RAM_MB - 512))

if [ $GUEST_RAM_MB -lt 128 ]; then
    error "Not enough RAM (need at least 640MB total, have ${TOTAL_RAM_MB}MB)"
fi

log "Total RAM: ${TOTAL_RAM_MB}MB, Guest RAM: ${GUEST_RAM_MB}MB (reserving 512MB for host)"

# Detect number of CPUs
NCPU=$(nproc)
log "CPUs: $NCPU"

# Setup networking
log "Setting up TAP networking..."

# Load tun module if needed
if [ ! -e /dev/net/tun ]; then
    log "Loading tun module"
    modprobe tun 2>/dev/null || true
fi

# Create TAP device
if ! ip link show "$TAP_DEVICE" >/dev/null 2>&1; then
    log "Creating TAP device: $TAP_DEVICE"
    ip tuntap add dev "$TAP_DEVICE" mode tap
else
    log "TAP device $TAP_DEVICE already exists"
fi

# Configure TAP device
log "Configuring TAP device"
ip addr add "${TAP_IP}/24" dev "$TAP_DEVICE"
ip link set "$TAP_DEVICE" up

# Enable IP forwarding
log "Enabling IP forwarding"
echo 1 > /proc/sys/net/ipv4/ip_forward

# Setup NAT/masquerading for internet access
# Find the main network interface (not loopback or TAP)
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -n "$MAIN_IFACE" ]; then
    log "Setting up NAT on interface: $MAIN_IFACE"

    # Flush existing iptables rules (optional, comment out if you have existing rules)
    iptables -t nat -F 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true

    # Setup masquerading
    iptables -t nat -A POSTROUTING -o "$MAIN_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$TAP_DEVICE" -o "$MAIN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$MAIN_IFACE" -o "$TAP_DEVICE" -m state --state RELATED,ESTABLISHED -j ACCEPT

    log "NAT configured"
else
    log "Warning: Could not detect main network interface, NAT may not work"
fi

# Kernel command line parameters
KERNEL_CMDLINE="console=ttyAMA0 root=/dev/vda rw"

log "Configuration:"
log "  Kernel: $KERNEL"
log "  Disk: $DISK"
log "  RAM: ${GUEST_RAM_MB}M"
log "  CPUs: $NCPU"
log "  Network: $TAP_DEVICE (host: $TAP_IP, guest should use: $GUEST_IP)"
log "  Kernel cmdline: $KERNEL_CMDLINE"
log ""

# Build lkvm command
LKVM_ARGS=(
    "run"
    "--kernel" "$KERNEL"
    "--disk" "$DISK"
    "--network" "mode=tap,tapif=$TAP_DEVICE,guest_ip=$GUEST_IP,host_ip=$TAP_IP"
    "--console" "serial"
    "--mem" "$GUEST_RAM_MB"
    "--cpus" "$NCPU"
    "--params" "$KERNEL_CMDLINE"
    "--rtc" "base=utc"
    "--rng"
)

log "Executing into guest VM..."
log "Command: $LKVM ${LKVM_ARGS[*]}"
log ""

# Exec into lkvm - this replaces the current process
# If we're PID 1, lkvm becomes PID 1
exec "$LKVM" "${LKVM_ARGS[@]}"

# Should never reach here
error "Failed to exec into lkvm"
