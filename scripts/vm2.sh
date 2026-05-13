#!/usr/bin/env bash
# vm2.sh — second instance of the same VM, used in multi-VM experiments.
#
# Differences from vm1.sh:
#   - SSH forwarded to host port 2223 (not 2222)
#   - Monitor socket at /tmp/vm2.mon
#   - Name vm2

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-$HOME/kvm-demo/debian-base.qcow2}"

if [[ ! -f "$IMAGE" ]]; then
  echo "ERROR: image not found at $IMAGE"
  echo "Run setup/build-image.sh first, or set IMAGE=... in the environment."
  exit 1
fi

qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 2 -m 1G \
  -drive file="$IMAGE",if=virtio,snapshot=on \
  -netdev user,id=n0,hostfwd=tcp::2223-:22 \
  -device virtio-net,netdev=n0 \
  -nographic -serial mon:stdio \
  -monitor unix:/tmp/vm2.mon,server,nowait \
  -name vm2,debug-threads=on
