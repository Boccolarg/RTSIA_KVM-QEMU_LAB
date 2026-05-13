# Experiment 08 — Memory-bandwidth contention and Memguard

**Goal:** See that even with **perfect CPU isolation** (disjoint pinning,
cgroups, RT priorities), one VM can still wreck another's latency by
saturating the **memory bandwidth**, a resource shared at the
DRAM-controller level, invisible to the scheduler. Then mitigate it with
**Memguard**, a kernel module that throttles per-core memory bandwidth.
**Prerequisites:** Setup complete. Experiments 05 and 07 strongly
recommended. Memguard is research-grade
software and building a kernel module requires kernel headers.

> **Caveat.** Memguard's official kernel support is 5.15+. It has been
> verified to compile and load cleanly on 6.15 (and on the kernels this
> lab was developed on: 6.8 and 6.17 stock plus 6.17.5-rt7 PREEMPT_RT).
> Newer kernels may need a small patch; see the GitHub issues page.

## Host CPUs used
This experiment pins the **critical VM to CPU 1** and the **memory-bandwidth
attacker VM to CPU 3**, on different physical cores, so any remaining interference
must come from a shared resource other than CPU time (which is exactly the point of
the experiment). The recommended cmdline in
[`../setup/README.md`](../setup/README.md) (`isolcpus=1-3`) covers both.

---

## What this experiment demonstrates

Pinning two VMs to disjoint physical CPUs (Exp 07 Stage 2) gives each
VM its own compute. But CPUs are not the only shared resource:

- **Last-level cache (LLC)**: shared across all cores of a socket.
- **Memory controller / DRAM bandwidth**: shared across all cores.
- **PCIe bandwidth**: shared.
- **Power/thermal budget**: shared (frequency scaling).

A VM running heavily on a different physical CPU can flood the memory
controller, causing every other VM's memory accesses to stall. The
guest experiences this as additional latency that is not attributable to
"my CPU being preempted", because it isn't preempted at all. Its CPU
just runs slower because it's waiting on memory.

Memguard ([github.com/heechul/memguard](https://github.com/heechul/memguard))
addresses this. It is a kernel module that uses CPU performance counters
to count **last-level-cache misses** per core in fixed time windows.
When a core exceeds its assigned memory-access budget within a window,
Memguard parks it with a high-priority RT throttler thread until the
next window. Net effect: a hard per-core memory-bandwidth cap, enforced
in hardware via the PMU.

You'll measure:

1. The attack: vm1 runs `cyclictest`, vm2 runs `stress-ng --vm` (memory-
   intensive). They are on disjoint cores. vm1's latency degrades anyway.
2. The mitigation: load Memguard, cap the attacker's core, watch vm1's
   latency recover.

---

## Setup

Install and load Memguard:

```bash
cd 08-memguard
./install-memguard.sh
```

**What this does.** Installs build deps, clones
[github.com/heechul/memguard](https://github.com/heechul/memguard), builds
the kernel module against your running kernel's headers, and `insmod`s it.
On success it shows the debugfs interface under
`/sys/kernel/debug/memguard/`.

Verify:

```bash
lsmod | grep memguard
ls /sys/kernel/debug/memguard/
```

**Expected output:**

```
memguard               24576  0
```

```
limit  read_limit  reservation  status  write_limit  ...
```

The exact files depend on the Memguard version, but you should see at
least `read_limit` (or `limit`) and `status`.

Boot both VMs (as in Exp 07):

```bash
# Terminal 1
../scripts/vm1.sh

# Terminal 2
../scripts/vm2.sh
```

In a host terminal, get the PIDs and pin them to disjoint cores:

```bash
PID1=$(pgrep -nf 'name vm1')
PID2=$(pgrep -nf 'name vm2')

sudo taskset -apc 1 "$PID1"     # vm1 on isolated CPU 1
sudo taskset -apc 3 "$PID2"     # vm2 on CPU 3
```

---

## Step 1 — Establish a baseline (no memory pressure)

In Terminal 3, inside vm1, run cyclictest:

```bash
../scripts/ssh-vm.sh 2222 'chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output (clean, no attacker active):**

```
T: 0 (...) P:99 I:200 C: 50000 Min: 4 Act: 12 Avg: 9 Max: 47
```

Note this Max: call it **L_baseline** (typically tens of µs on a
well-configured host).

---

## Step 2 — Launch the memory-bandwidth attacker

In Terminal 3, **inside vm2**, start `stress-ng` doing massive memory churn:

```bash
../scripts/ssh-vm.sh 2223 'stress-ng --vm 1 --vm-bytes 1G --vm-method all --timeout 60s' &
```

**What this does.** `--vm 1` starts one VM-stressor worker. `--vm-bytes 1G`
allocates a 1 GiB buffer (much larger than any cache; every access misses
to DRAM). `--vm-method all` cycles through many memory access patterns
designed to thrash caches and TLBs.

Before checking cyclictest, let's confirm the attack is real by counting
LLC misses on the host (vm2 is the only thing on CPU 3):

```bash
sudo perf stat -e LLC-load-misses,LLC-loads -C 3 -- sleep 5
```

**What this does.** Sample the LLC counters on CPU 3 for 5 s.

**Expected output (under attack):**

```
 Performance counter stats for 'CPU(s) 3':

   312,456,789      LLC-load-misses
   478,123,456      LLC-loads

       5.001234567 seconds time elapsed
```

That's hundreds of millions of LLC misses per second, i.e. memory traffic
in the multi-GB/s range. **On AMD Ryzen Zen4** (Ryzen 7 8845HS), the L3 is
~16 MiB; a 1 GiB working set spills entirely to DRAM. Every miss is a
DRAM access. This is the entire DRAM bandwidth on this core, going to
useless thrashing.

Now rerun cyclictest in vm1 **while the attacker is active**:

```bash
../scripts/ssh-vm.sh 2222 'chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output (under attack):**

```
T: 0 (...) P:99 I:200 C: 50000 Min: 4 Act: 47 Avg: 27 Max: 312
```

**What to look for.** **`Max` has grown roughly 5–10×** despite vm1 being
on a different physical CPU. The extra latency is from vm1's vCPU
stalling on memory while the DRAM controller services vm2's wave of
cache misses. No scheduler preemption happened; the CPU was running
guest code the whole time, just running it slower.

This is a hardware-level interference channel that pinning cannot fix.

Leave the attacker running (or restart it; `stress-ng` will exit after
its 60 s timeout).

---

## Step 3 — Apply the Memguard mitigation

Memguard's interface is a set of files under `/sys/kernel/debug/memguard/`.
The exact filenames vary across releases; the most common is `limit` or
`read_limit`, which takes one value per **logical CPU** in your system.

The unit is **megabytes per second** of LLC misses on that core.

Check what your installation has:

```bash
ls /sys/kernel/debug/memguard/
```

For the version in use here (release branch), the file is `limit`. **Set
all cores to "unlimited" except the attacker's core**, which we cap at
**500 MB/s**:

```bash
# Build a per-core list of N entries, one per logical CPU.
# 16000 = effectively unlimited; 500 = the cap for CPU 3 (our attacker).
NCPU=$(nproc)
LIMITS=""
for cpu in $(seq 0 $((NCPU-1))); do
    if [[ $cpu -eq 3 ]]; then
        LIMITS+="500 "
    else
        LIMITS+="16000 "
    fi
done
echo "Writing limits: $LIMITS"
echo "$LIMITS" | sudo tee /sys/kernel/debug/memguard/limit
```

**What this does.** Tells Memguard: cap CPU 3's memory-access bandwidth at
roughly 500 MB/s; leave the others uncapped. Memguard's periodic
throttler thread will park CPU 3 once it has burned its budget within
the current ~1 ms window, until the next window.

Verify:

```bash
cat /sys/kernel/debug/memguard/limit
cat /sys/kernel/debug/memguard/status 2>/dev/null || \
    cat /sys/kernel/debug/memguard/usage 2>/dev/null
```

**Expected output (the status file):** a live readout of recent
bandwidth usage per core. CPU 3 should be banging up against its cap;
other cores should be way below their (16000) ceiling.

> If `limit` is not the right filename for your Memguard build, try
> `read_limit` (some versions split read and write budgets). The
> debugfs files are self-documenting:
> `cat /sys/kernel/debug/memguard/<file>` shows the current value;
> `echo <values> > <file>` updates it.

Now restart the attack (if it timed out):

```bash
../scripts/ssh-vm.sh 2223 'stress-ng --vm 1 --vm-bytes 1G --vm-method all --timeout 60s' &
```

And rerun cyclictest in vm1:

```bash
../scripts/ssh-vm.sh 2222 'chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output (under attack, with Memguard capping the attacker):**

```
T: 0 (...) P:99 I:200 C: 50000 Min: 4 Act: 14 Avg: 10 Max: 71
```

**What to look for.** `Max` is back close to **L_baseline**. The attacker
inside vm2 can still allocate and touch its 1 GiB buffer, but it can no
longer monopolize the memory controller; Memguard parks its core
whenever it tries to exceed 500 MB/s of LLC misses. The bandwidth left
over for vm1's memory accesses is sufficient to keep its RT loop on time.

---

## Step 4 — Confirm the throttle is doing real work

While the attacker is running with Memguard active, on the host:

```bash
sudo perf stat -e LLC-load-misses,LLC-loads -C 3 -- sleep 5
```

**Expected output:** the LLC-load-misses rate on CPU 3 is dramatically
**lower** than in Step 2, capped near 500 MB/s of misses. The throttle
is provably enforced at the hardware-counter level.

```bash
top -bn1 -p "$PID2" -o '%CPU' | head
```

The vm2 QEMU process's CPU usage is no longer 100% of CPU 3; Memguard's
throttler thread is interleaving with it, so its real utilization drops
to whatever fraction of bandwidth Memguard allows it to occupy.

---

## Summary — what you should have observed

| Stage | Setup                                            | vm1 cyclictest Max  | Mechanism                       |
|-------|--------------------------------------------------|---------------------|---------------------------------|
| 1     | Disjoint pinning, no attacker                    | ~50 µs              | Baseline                        |
| 2     | Disjoint pinning, vm2 thrashes memory            | ~300 µs (5–10× up)  | Memory-bandwidth contention     |
| 3     | + Memguard cap of 500 MB/s on attacker's core    | ~70 µs (close to baseline) | PMU-based bandwidth throttling |

The take-away: **CPU isolation is necessary but not sufficient for RT
VMs on modern multi-core SoCs.** Cores share a memory controller;
contention there is invisible to the scheduler and shows up as
mysterious latency spikes. Tools like Memguard, Intel's MBA (Memory
Bandwidth Allocation), and AMD's PQE / Platform QoS Extensions are
the family of solutions; Memguard is the most accessible because it's
free software and works on any CPU with the LLC-miss performance
counter.

---

## Things to note

- **Memguard depends on the PMU.** If your CPU doesn't expose
  LLC-load-misses (rare on x86, common on some embedded ARM), Memguard
  won't work or will report bogus numbers.
- **In a VM, you typically cannot run Memguard inside the guest.** The
  PMU is host-only by default; `-cpu host,+pmu` exposes a virtual PMU but
  the accuracy and supported events depend on KVM and CPU. Memguard
  belongs on the **host**, capping the host CPUs that run the VMs.
- **The right cap depends on your DRAM.** A high-end DDR5 system has
  tens of GB/s total bandwidth; carving out 500 MB/s for an attacker
  core is conservative. Measure your platform with `perf stat` under a
  representative load, then choose caps that protect your critical core
  with margin.
- **Intel RDT MBA** is the hardware-native version of this idea, present
  on Xeon and newer i7/i9. It's also exposed via `resctrl`; for a
  production deployment on Intel, prefer MBA. Memguard is the portable
  software fallback.
- **AMD QoS Extensions** (since Zen3) provide similar facilities but the
  Linux kernel support is less mature; Memguard remains a good choice
  on Zen-family CPUs (which is what this lab was developed on).
- The Memguard authors (Heechul Yun et al.) have a series of papers on
  this approach: "Memguard: Memory Bandwidth Reservation System for
  Efficient Performance Isolation in Multi-core Platforms" (RTAS 2013)
  is the original. Worth reading for the rationale.

## Cleanup

```bash
# Power off both VMs
../scripts/ssh-vm.sh 2222 poweroff
../scripts/ssh-vm.sh 2223 poweroff

# Unload memguard
sudo rmmod memguard

# Verify
lsmod | grep memguard && echo "still loaded" || echo "unloaded"
```

The Memguard sources stay in `~/memguard/`; delete the directory if you
want to remove them entirely. Re-running `install-memguard.sh` is
idempotent and will work as long as the build still applies cleanly to
your kernel.

---

## Going further

- The Memguard repository has more advanced modes: per-core reservation
  with **periodic refilling**, **work-conservation** (give unused bandwidth
  to other cores), and **memory-aware DVFS**. See
  [github.com/heechul/memguard](https://github.com/heechul/memguard).
- **MARACAS** (the authors' follow-up paper) extends the idea with
  *multi-resource* arbitration, covering caches, memory channels, and prefetchers.
- **`perf c2c`** (cache-to-cache) is a powerful tool to **diagnose**
  false sharing and inter-socket cache traffic before deciding what to
  throttle. Run it on a workload that misbehaves to see exactly which
  cache lines are bouncing around.
- The **Linux `resctrl` interface** (under `/sys/fs/resctrl/`) is the
  cgroup-like API to Intel CAT (Cache Allocation Technology) and MBA.
  Same conceptual problem, hardware solution; no kernel module needed.
- For the truly paranoid: **hardware passthrough** (`vfio-pci`) of a
  real NIC, real storage, real timer to the RT guest, eliminating
  every shared software path. This is how some industrial PLC
  hypervisor products work.
