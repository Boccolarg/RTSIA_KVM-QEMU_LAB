#!/usr/bin/env bash
# vm1.sh — boot the demo VM with KVM, serial console, and a monitor socket.
#
# Why each flag matters:
#   -enable-kvm           use KVM (hardware-assisted virtualization)
#   -cpu host             expose host CPU model to guest (max performance)
#   -smp 2                two vCPUs (= two threads in the QEMU process)
#   -m 1G                 1 GiB of RAM
#   -drive ...,snapshot=on  changes are discarded at shutdown (keeps base image clean)
#   -netdev user + virtio-net   paravirtualized NIC, user-mode networking
#   hostfwd=tcp::2222-:22 host port 2222 -> guest port 22 (SSH)
#   -nographic            no GUI; serial console on stdio
#   -serial mon:stdio     multiplex monitor + serial on stdio (Ctrl-A C to toggle)
#   -monitor unix:...     also expose QEMU monitor on a Unix socket for scripting
#   -name vm1,debug-threads=on  name VM and name vCPU threads so 'ps -L' shows
#                               "CPU 0/KVM", "CPU 1/KVM" etc.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-$HOME/kvm-demo/debian-base.qcow2}"
echo "Using image: $IMAGE"

if [[ ! -f "$IMAGE" ]]; then
  echo "ERROR: image not found at $IMAGE"
  echo "Run setup/build-image.sh first, or set IMAGE=... in the environment."
  exit 1
fi

qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 2 -m 1G \
  -drive file="$IMAGE",if=virtio,snapshot=on \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=n0 \
  -nographic -serial mon:stdio \
  -monitor unix:/tmp/vm1.mon,server,nowait \
  -name vm1,debug-threads=on
