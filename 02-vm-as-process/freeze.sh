#!/usr/bin/env bash
# freeze.sh — Automates the Step 3 STOP/CONT demonstration

# Define the SSH command using the path and port you use
SSH_CMD="../scripts/ssh-vm.sh 2222"

echo "=== VM Time Freeze Demonstration ==="

# 1. Find the QEMU PID
PID=$(pgrep -nf 'name vm1')
if [ -z "$PID" ]; then
    echo "Error: Could not find QEMU process 'name vm1'. Is the VM running?"
    exit 1
fi
echo "Found QEMU PID: $PID"

# 2. Check the clock before freezing
echo -e "\n[1/5] Getting guest's clock BEFORE freeze..."
$SSH_CMD date

# 3. Freeze the VM
echo -e "\n[2/5] Freezing the entire VM (sudo kill -STOP $PID)..."
sudo kill -STOP "$PID"

# 4. Attempt to connect while frozen
echo -e "\n[3/5] Trying to talk to the guest (timeout 3s)..."
echo "      (This will hang and time out because the VM is frozen)"
timeout 3 $SSH_CMD date
if [ $? -eq 124 ]; then
    echo "      -> SSH timed out, as expected."
fi

echo -e "\n[4/5] Sleeping for 9 seconds on the host..."
sleep 9

# 5. Resume the VM
echo -e "\n[5/5] Resuming the VM (sudo kill -CONT $PID)..."
sudo kill -CONT "$PID"

# 6. Check the clock after resuming
echo -e "\nGetting guest's clock AFTER resume..."
$SSH_CMD date
echo -e "\nDone! Compare the first and second date outputs to see the jump."