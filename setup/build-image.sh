#!/usr/bin/env bash
# build-image.sh — build the reusable demo guest image with cloud-init.
#
# Idempotent: skips steps that have already been done.
# Output: ~/kvm-demo/debian-base.qcow2  (referenced by scripts/vm1.sh and vm2.sh)
#
# Usage: ./setup/build-image.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$HOME/kvm-demo"
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "==> Working directory: $WORKDIR"
echo "==> Repository root: $REPO_ROOT"

# Step 1: download the cloud image if not already present
if [[ ! -f debian.qcow2 ]]; then
  echo "==> Downloading Debian 12 cloud image (~350 MB)..."
  wget -O debian.qcow2 "$DEBIAN_URL"
else
  echo "==> debian.qcow2 already present, skipping download."
fi

# Step 2: resize for headroom (no-op if already resized)
echo "==> Resizing image to 5 GiB..."
qemu-img resize debian.qcow2 5G

# Step 3: copy the cloud-init seed material into place
echo "==> Copying user-data / meta-data..."
cp "$REPO_ROOT/setup/user-data" user-data
cp "$REPO_ROOT/setup/meta-data" meta-data

# Step 4: build the seed ISO that cloud-init will read at first boot
if [[ ! -f seed.iso ]]; then
  echo "==> Building seed.iso with cloud-localds..."
  cloud-localds seed.iso user-data meta-data
else
  echo "==> seed.iso already present, rebuilding..."
  rm -f seed.iso
  cloud-localds seed.iso user-data meta-data
fi

# Step 5: first boot with the seed attached. cloud-init runs, installs packages, then we power off.
if [[ -f debian-base.qcow2 ]]; then
  echo "==> debian-base.qcow2 already exists, skipping first-boot bake."
  echo "    Delete it and re-run if you want to rebuild from scratch."
else
  echo "==> First boot with cloud-init. This takes 2-3 minutes for package install."
  echo "    When you see the 'guest login:' prompt, log in as root / demo, then 'poweroff'."
  echo "    Press Ctrl-A X to exit if cloud-init hangs (unlikely)."
  echo
  read -rp "Press Enter to continue..."

  qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 2 -m 2G \
    -drive file=debian.qcow2,if=virtio \
    -drive file=seed.iso,if=virtio,format=raw \
    -netdev user,id=n0 -device virtio-net,netdev=n0 \
    -nographic -serial mon:stdio

  echo "==> Snapshotting baked image to debian-base.qcow2..."
  cp debian.qcow2 debian-base.qcow2
fi

echo
echo "==> Done."
echo "    Base image: $WORKDIR/debian-base.qcow2"
echo "    All experiment scripts use this image in -snapshot mode."
