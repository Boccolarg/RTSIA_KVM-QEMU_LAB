#!/usr/bin/env bash
# show-vcpu-threads.sh — print the host TIDs of all vCPU threads for a given QEMU process.
# Usage: ./show-vcpu-threads.sh <PID>
#        ./show-vcpu-threads.sh $(pgrep -nf 'name vm1')

set -euo pipefail

PID="${1:-}"
if [[ -z "$PID" ]]; then
  echo "Usage: $0 <PID-of-qemu-process>"
  echo "Hint:  ./show-vcpu-threads.sh \$(pgrep -nf 'name vm1')"
  exit 1
fi

if [[ ! -d "/proc/$PID" ]]; then
  echo "ERROR: no process with PID $PID"
  exit 2
fi

echo "QEMU PID: $PID"
echo
echo "All threads (TID  CPU  CLS  PRI  NICE  COMMAND):"
ps -L -p "$PID" -o tid,psr,cls,pri,nice,comm
echo
echo "vCPU threads only:"
ps -L -p "$PID" -o tid,psr,cls,pri,comm | awk 'NR==1 || /CPU [0-9]+\/KVM/'
