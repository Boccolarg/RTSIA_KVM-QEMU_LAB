#!/usr/bin/env bash
# ssh-vm.sh — SSH into one of the running demo VMs.
# Usage: ./ssh-vm.sh           # connects to vm1 (port 2222)
#        ./ssh-vm.sh 2223      # connects to vm2 on port 2223
#        ./ssh-vm.sh 2222 date # connects to vm1, runs 'date', and exits
#
# Disables host-key checking because every snapshot run uses a fresh host key.

PORT="${1:-2222}"

# Shift the arguments so $1 (the port) is removed, 
# leaving only the command (if any) in "$@"
if [ $# -gt 0 ]; then
    shift
fi

exec sshpass -p 'demo' ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p "$PORT" root@127.0.0.1 "$@"