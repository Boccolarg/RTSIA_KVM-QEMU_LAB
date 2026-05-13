#!/usr/bin/env bash
# install-memguard.sh — clone, build, and load the Memguard kernel module.
#
# Memguard (http://github.com/heechul/memguard) is a per-core memory-bandwidth
# regulator implemented as a Linux kernel module. It uses the CPU's performance
# counter for last-level-cache misses to count off-chip memory accesses, then
# throttles a core that exceeds its assigned bandwidth budget.
#
# Official support: kernel 5.15+. Empirically: builds and runs cleanly on 6.15
# (and on this lab's 6.8 / 6.17 hosts). If your kernel is newer than what
# memguard has been tested against and the build fails, the fix is usually a
# small API rename — see the GitHub issues for hints.
#
# Usage: ./install-memguard.sh
#
# What this script does:
#   1. Installs build dependencies.
#   2. Clones https://github.com/heechul/memguard into ~/memguard (if absent).
#   3. Builds the kernel module against the running kernel's headers.
#   4. Loads it with insmod.
#   5. Verifies the debugfs interface at /sys/kernel/debug/memguard/ is present.

set -euo pipefail

WORKDIR="$HOME/memguard"
REPO_URL="https://github.com/heechul/memguard.git"

echo "==> Installing build dependencies..."
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    linux-headers-"$(uname -r)" \
    git

if [[ ! -d "$WORKDIR" ]]; then
    echo "==> Cloning Memguard into $WORKDIR..."
    git clone "$REPO_URL" "$WORKDIR"
else
    echo "==> $WORKDIR already exists, pulling latest..."
    (cd "$WORKDIR" && git pull --ff-only)
fi

cd "$WORKDIR"

echo "==> Building against kernel $(uname -r)..."
make clean || true
make

if [[ ! -f memguard.ko ]]; then
    echo "ERROR: memguard.ko not built. Check the make output above."
    exit 2
fi

# Unload any previous version
if lsmod | grep -qw memguard; then
    echo "==> Unloading previous memguard..."
    sudo rmmod memguard
fi

echo "==> Loading memguard.ko..."
sudo insmod ./memguard.ko

# Mount debugfs if not already mounted
if [[ ! -d /sys/kernel/debug ]] || ! mountpoint -q /sys/kernel/debug; then
    sudo mount -t debugfs none /sys/kernel/debug
fi

if [[ ! -d /sys/kernel/debug/memguard ]]; then
    echo "ERROR: /sys/kernel/debug/memguard not created."
    echo "       Loading probably failed silently. Check 'dmesg | tail'."
    exit 3
fi

echo
echo "==> Memguard loaded successfully."
echo "    Debugfs interface: /sys/kernel/debug/memguard/"
ls -1 /sys/kernel/debug/memguard/
echo
echo "    To unload later: sudo rmmod memguard"
