# Experiment 04 — Device emulation: e1000 vs virtio, and the cost of VM-exits

**Goal:** Compare a fully-emulated network card (`e1000`) with a
paravirtualized one (`virtio-net`) in throughput and host CPU usage, then
**see the underlying mechanism**, the VM-exits, using `perf kvm stat`.
**Prerequisites:** Setup complete. Experiment 04 needs the e1000 driver, which the cloud kernel doesn't include. Build the derivative image once: `./build-e1000-image.sh`. It creates ~/kvm-demo/debian-e1000.qcow2 (~200 MB) as a qcow2 overlay on top of the base image with only the kernel diff stored. All other experiments keep using debian-base.qcow2 with the fast cloud kernel.

---

## What this experiment demonstrates

From the lesson: QEMU emulates many devices. Some (the `e1000` Intel
gigabit NIC, the Cirrus VGA, the i440FX bridge, IDE controllers, ...) are
**full emulations** of real hardware; every register access by the guest
driver traps to QEMU, which then simulates the device behavior. Others
(the `virtio-*` family) are **paravirtualized**: the guest knows it's a
VM and uses a shared-memory ring protocol with batched notifications.

The two have very different VM-exit profiles. Each VM-exit is a transition
from guest mode back to host kernel mode (and possibly out to user-space
QEMU), a context switch that's not free. **Fewer exits means more
throughput and less jitter.** For RT VMs, that's directly latency.

You'll measure:

1. Throughput of `iperf3` over `e1000` and over `virtio-net`.
2. VM-exit counts with `perf kvm stat`, comparing the two NICs.

---

## Setup

Make sure no leftover VMs are running:

```bash
pkill -f 'name vm1' 2>/dev/null
sleep 1
```

In one terminal, start an `iperf3` server on the host:

```bash
iperf3 -s
```

It will listen on TCP port 5201 and wait. Leave it running.

---

## Step 1 — Boot with the fully-emulated `e1000` NIC

In a **second** terminal:

```bash
qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 2 -m 1G \
    -drive file=$HOME/kvm-demo/debian-e1000.qcow2,if=virtio,snapshot=on \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -device e1000,netdev=n0 \
    -nographic -serial mon:stdio -name vm1,debug-threads=on
```

**What's different from `vm1.sh`.** The `-device virtio-net,netdev=n0` line
is replaced by `-device e1000,netdev=n0`. Also, we need the new image with e1000 drivers built in, everything else is the same but the virtual NIC is different.

In a **third** terminal, SSH into the guest:

```bash
../scripts/ssh-vm.sh 2222
```

Inside the guest, verify what NIC the guest sees:

```bash
lspci | grep -i ether
```

**Expected output (inside the guest):**

```
00:03.0 Ethernet controller: Intel Corporation 82540EM Gigabit Ethernet Controller (rev 03)
```

That's an actual real-world Intel NIC model from ~2002. The guest's `e1000`
kernel driver thinks it's talking to one.

Now run an `iperf3` client to the host:

```bash
iperf3 -c 10.0.2.2 -t 10
```

**What this does.** `10.0.2.2` is the host as seen from inside QEMU's
user-mode network. We push TCP for 10 seconds and measure throughput.

**Expected output:**

```
Connecting to host 10.0.2.2, port 5201
[  5] local 10.0.2.15 port 38120 connected to 10.0.2.2 port 5201
[ ID] Interval           Transfer     Bitrate         Retr  Cwnd
[  5]   0.00-1.00   sec   80.0 MBytes   671 Mbits/sec    0   ...
[  5]   1.00-2.00   sec   75.6 MBytes   634 Mbits/sec    0   ...
...
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00  sec   780 MBytes   654 Mbits/sec    1             sender
[  5]   0.00-10.00  sec   775 MBytes   650 Mbits/sec                  receiver
```

**What to look for.** Throughput in the range of **~0.5–1 Gbit/s**, with
noticeable host CPU usage on the QEMU process. Note your number and call it
**B(e1000)**.

While the test is running, in a fourth terminal:

```bash
top -bn1 -p "$(pgrep -nf 'name vm1')"
```

Note the QEMU CPU%. The vCPU threads are busy *and* the QEMU main thread is
busy, because every `e1000` register write traps to QEMU and is emulated
in user-space.

Stop `iperf3` (it ends automatically after 10s). Power off the guest:

```bash
poweroff
```

---

## Step 2 — Boot the same image with `virtio-net`

```bash
IMAGE=~/kvm-demo/debian-e1000.qcow2 ../scripts/vm1.sh
```

(`vm1.sh` uses `-device virtio-net,netdev=n0` by default, so this is the
virtio case.)

SSH in:

```bash
../scripts/ssh-vm.sh 2222
```

Verify what NIC the guest sees now:

```bash
lspci | grep -i ether
```

**Expected output:**

```
00:03.0 Ethernet controller: Red Hat, Inc. Virtio network device
```

A different vendor and a different model. The guest's `virtio_net` kernel
driver knows this is a VM device and uses a paravirtualized protocol.

Run the same iperf3:

```bash
iperf3 -c 10.0.2.2 -t 10
```

**Expected output:** noticeably better throughput.

```
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00  sec   2.45 GBytes   2.10 Gbits/sec  ...
```

The exact numbers depend on your CPU and the limits of user-mode
networking (which is itself a bottleneck), but **virtio is typically
2–5× faster than e1000** at less host CPU per Gbit. Note the number and
call it **B(virtio)**.

---

## Step 3 — Quantify the difference with `perf kvm stat`

This is where the "fewer VM-exits" story becomes a number, not a slogan.

With the virtio VM still running and idle (no iperf3 client active), in a
host terminal:

```bash
sudo perf kvm stat live
```

**What this does.** `perf kvm stat live` reads the kernel's KVM tracepoints
and prints a live histogram of VM-exit reasons (EPT_VIOLATION, IO_INSTRUCTION,
MSR_WRITE, EXTERNAL_INTERRUPT, HLT, …) per second.

**Expected output (idle, virtio NIC, refreshes every second):**

```
Analyze events for all VMs, all VCPUs:

           VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time         Avg time

       MSR_WRITE        180    50.42%     0.10%      0.40us      8.42us      0.71us ( +-   2.5% )
             HLT         95    26.61%    99.65%   1010.00us  10003.71us   8410.00us ( +-   2.4% )
   EXTERNAL_INTERRUPT     61    17.09%     0.13%      0.50us     19.20us      1.71us ( +-   8.9% )
   PREEMPTION_TIMER       10     2.80%     0.00%      0.30us      1.10us      0.61us ( +-   8.6% )
   IO_INSTRUCTION          7     1.96%     0.00%      0.50us      4.30us      1.71us ( +-  31.2% )
              ...
```

> If your perf doesn't have `--live`, use the alternative invocation:
> `sudo perf kvm stat record -p $(pgrep -nf 'name vm1') -- sleep 5` then
> `sudo perf kvm stat report`.

Now, **with `perf kvm stat live` still running**, from the guest:

```bash
iperf3 -c 10.0.2.2 -t 10
```

Watch the host's perf output update.

**What to look for.** Under virtio + iperf3 load you'll see:

- **EXTERNAL_INTERRUPT** climbs (incoming packets cause interrupts).
- **EPT_VIOLATION** appears (guest accessing new memory).
- **IO_INSTRUCTION** stays low since virtio uses MMIO sparingly.

Press **Ctrl-C** to stop `perf kvm stat live`. Power off the guest. Boot the
**e1000** VM from Step 1 again and repeat:

```bash
# In one terminal:
sudo perf kvm stat live

# In another:
iperf3 -c 10.0.2.2 -t 10        # inside the guest
```

**Now look at the numbers.** Under load, the e1000 VM shows:

- Far higher total exits/sec.
- A much larger fraction of **IO_INSTRUCTION** exits (one per `e1000`
  register access).
- Lots of **EXTERNAL_INTERRUPT** for delivered packets.

**Expected comparison (rough orders of magnitude under saturating iperf3
load):**

| Metric                          | e1000          | virtio-net    | Ratio  |
| ------------------------------- | -------------- | ------------- | ------ |
| iperf3 throughput               | ~0.6 Gbit/s    | ~2 Gbit/s     | ~3×    |
| Total VM-exits per second       | ~100,000+      | ~20,000–40,000| ~3×    |
| IO_INSTRUCTION fraction         | high (>40%)    | very low (<5%)| N/A    |

Numbers vary a lot by host, but **the direction is invariant**: virtio
delivers more bytes for fewer exits. That's the whole point.

---

## Summary — what you should have observed

- The same Debian image, two virtual NICs, very different performance.
- `e1000` is faithful to real hardware: every guest driver register access
  causes a VM-exit and is emulated by QEMU in user-space.
- `virtio-net` uses a paravirtualized shared-memory ring protocol with
  batched notifications. Far fewer VM-exits per byte transferred.
- For RT VMs, this matters twice: virtio gives higher throughput **and**
  much lower per-packet jitter, because each VM-exit is an unbounded
  excursion through the host kernel and possibly user-space QEMU.

The general lesson: **use virtio for everything you can.** virtio-net for
networking, virtio-blk or virtio-scsi for storage, virtio-rng for entropy,
virtio-balloon for memory ballooning. The fully-emulated devices exist for
guest compatibility such as old Windows or Linux. For new VMs you control:
virtio everywhere.

---

## Things to note

- `iperf3 -c 10.0.2.2` uses QEMU's user-mode networking SLIRP. SLIRP itself
  is a bottleneck; its peak throughput is well below line rate. For higher
  absolute numbers (and more realistic measurements), use a `tap` bridge.
  For comparing **e1000 vs virtio** the SLIRP bottleneck affects both, so
  the relative ratio is still meaningful.
- `-cpu host` is required for some virtio-net features (large segment
  offload, multiqueue). Without it, throughput drops.
- You can take this further: add `vhost=on` to the netdev (`-netdev
  user,id=n0,vhost=on` doesn't work because vhost needs tap; with tap:
  `-netdev tap,id=n0,vhost=on`). vhost-net moves the virtio backend into
  the host kernel resulting in even fewer exits.

## Cleanup

```bash
poweroff                          # inside guest, or:
pkill -f 'name vm1'               # from host

# Stop the iperf3 server (Ctrl-C in its terminal)
```

---

## Going further

- The exit reasons reported by `perf kvm stat` are documented in the Intel
  SDM (vol 3, "VM-Exit Information") and the AMD APM (vol 2,
  "VMCB Layout"). Each reason corresponds to a specific guest instruction
  or event that requires hypervisor intervention.
- `virtio-net` has many tuning knobs: `mrg_rxbuf=on`, `mq=on`, `vectors=N`,
  `rx_queue_size`. For RT, **disable** features that add buffering or
  coalescing (the goal is low latency, not max throughput).
- For storage: repeat this experiment with `if=ide` vs `if=virtio` and a
  `fio` benchmark inside the guest. The ratio is even more dramatic for
  small random I/O.
- The next level beyond paravirtualization is **device passthrough** via
  VFIO/IOMMU: hand a real PCI device directly to the guest. Zero VM-exits
  for device access, at the cost of losing the host's view of the device.
  This is how real-time industrial NICs and PROFINET cards are typically
  used in virtualized PLCs.
