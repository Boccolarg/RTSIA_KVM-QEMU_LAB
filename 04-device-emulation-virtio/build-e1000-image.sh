#!/usr/bin/env bash
# build-e1000-image.sh — Build a derivative image with the generic Debian
# kernel (which includes the e1000 driver) on top of debian-base.qcow2.
# The overlay stores only the kernel diff (~200 MB) thanks to qcow2 backing files.

set -euo pipefail

WORKDIR="$HOME/kvm-demo"
BASE="$WORKDIR/debian-base.qcow2"
OVERLAY="$WORKDIR/debian-e1000.qcow2"
SEED="$WORKDIR/seed-e1000.iso"

[[ -f "$BASE" ]] || { echo "ERROR: $BASE not found. Run setup/build-image.sh first."; exit 1; }

if [[ -f "$OVERLAY" ]]; then
    echo "$OVERLAY already exists. Delete it to rebuild."
    exit 0
fi

# A NEW instance-id makes cloud-init re-run its per-instance modules.
cat > /tmp/meta-data-e1000 <<EOF
instance-id: iid-rtis-e1000-01
local-hostname: guest
EOF

#  - [ apt-get, -y, purge, linux-image-cloud-amd64 ]

cat > /tmp/user-data-e1000 <<'EOF'
#cloud-config
package_update: true
packages:
  - linux-image-amd64
runcmd:
  - [ apt-get, update ]
  - [ apt-get, -y, install, linux-image-amd64 ]
  - [ bash, -c, "rm -f /boot/vmlinuz-*cloud-amd64 /boot/initrd.img-*cloud-amd64" ]
  - [ update-grub ]
power_state:
  delay: now
  mode: poweroff
  message: e1000-capable kernel installed, powering off
EOF

echo "==> Building seed-e1000.iso..."
cloud-localds "$SEED" /tmp/user-data-e1000 /tmp/meta-data-e1000

echo "==> Creating overlay with $BASE as backing file..."
qemu-img create -f qcow2 -b "$BASE" -F qcow2 "$OVERLAY"

echo "==> Booting overlay (writable) with new cloud-init seed."
echo "    cloud-init installs linux-image-amd64, purges the cloud kernel,"
echo "    and powers off. Takes ~2-3 minutes; QEMU exits on its own."
echo

qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 2 -m 2G \
    -drive file="$OVERLAY",if=virtio \
    -drive file="$SEED",if=virtio,format=raw \
    -netdev user,id=n0 -device virtio-net,netdev=n0 \
    -nographic -serial mon:stdio

rm -f /tmp/user-data-e1000 /tmp/meta-data-e1000

echo
echo "==> Done."
echo "    Overlay:      $OVERLAY ($(du -h "$OVERLAY" | cut -f1))"
echo "    Backing file: $BASE"
echo
qemu-img info "$OVERLAY" | grep -E 'virtual size|disk size|backing file'