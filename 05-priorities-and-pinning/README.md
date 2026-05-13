# Experiment 05 — Priorities and pinning: outside and inside the VM

**Goal:** Use `taskset` and `chrt` to control where the QEMU process runs and
at what priority: at the level of the entire process, of individual vCPU
threads, and of tasks inside the guest. See how the same operations look in
libvirt (`virsh vcpupin`).
**Prerequisites:** Setup complete. Experiment 02 strongly recommended (you
need to be comfortable identifying vCPU threads).

## Host CPUs used
This experiment pins **vCPU 0 → host CPU 2** and **vCPU 1 → host CPU 3**. For clean RT measurements, both CPUs should be isolated. The recommended cmdline in
[`../setup/README.md`](../setup/README.md) (`isolcpus=1-3`) already covers this.
Without isolation, expect `Max` latency up to 2–5× higher because the host scheduler may
place background tasks on the same CPUs.

---

## What this experiment demonstrates

VMs have **two levels of scheduling**:

1. **The host** schedules QEMU's vCPU threads onto physical CPUs.
2. **The guest kernel** schedules its own tasks onto the vCPUs it sees.

A real-time task inside the guest can have the highest in-guest priority, but if the host doesn't schedule its vCPU thread, none of that matters since the task simply doesn't run. This is the most common failure mode for RT VMs and the reason host-side controls (`taskset`, `chrt`, cgroups, the PREEMPT_RT kernel) are mandatory.

You'll exercise:

- `taskset` to set CPU affinity on the whole QEMU process and on individual
  vCPU threads.
- `chrt` to move QEMU's threads to `SCHED_FIFO`.
- The same controls inside the guest, applied to `cyclictest`.
- The libvirt equivalents (`virsh vcpupin`, `virsh emulatorpin`, the
  `<cputune>` XML stanza).

---

## Setup

Boot the demo VM:

```bash
../scripts/vm1.sh
```

In another terminal, capture the PID and the vCPU TIDs (see Exp 02):

```bash
PID=$(pgrep -nf 'name vm1')
echo "QEMU PID = $PID"
../scripts/show-vcpu-threads.sh "$PID"
```

**Expected output:**

```
QEMU PID: 14215

All threads (TID  CPU  CLS  PRI  NICE  COMMAND):
    PID    TID PSR CLS PRI  NI COMMAND
  14215  14215   5  TS  19   0 qemu-system-x86
  14215  14217   3  TS  19   0 call_rcu
  14215  14219   9  TS  19   0 IO mon_iothread
  14215  14220   1  TS  19   0 CPU 0/KVM
  14215  14221  11  TS  19   0 CPU 1/KVM
  ...

vCPU threads only:
    TID PSR CLS PRI COMMAND
  14220   1  TS  19 CPU 0/KVM
  14221  11  TS  19 CPU 1/KVM
```

Note the TIDs of the vCPU threads; we'll need them. The `CLS` column is
`TS` (TimeSharing, i.e. `SCHED_OTHER`), the default.

For this experiment we'll need these two values; replace them in the
commands below:

```bash
VCPU0=14220       # <-- replace with the real TID of "CPU 0/KVM"
VCPU1=14221       # <-- replace with the real TID of "CPU 1/KVM"
```

---

## Step 1 — Affinity at the process level

By default the host scheduler is free to move the QEMU process across all
cores. Pin the whole process (every thread) to host CPUs 2 and 3:

```bash
sudo taskset -apc 2,3 "$PID"
```

**What this does.** `taskset -p` operates on a process; `-a` extends to all
threads; `-c 2,3` is a CPU-list mask. Every thread of the QEMU process can
now only be scheduled on host CPUs 2 or 3.

**Expected output:**

```
pid 14215's current affinity list: 0-15
pid 14215's new affinity list: 2,3
pid 14217's current affinity list: 0-15
pid 14217's new affinity list: 2,3
...
```

Verify:

```bash
../scripts/show-vcpu-threads.sh "$PID"
```

The `PSR` column may take a moment to reflect the move (it shows the last
CPU each thread ran on). Force some guest activity to make it visible:

```bash
../scripts/ssh-vm.sh 2222 'yes > /dev/null' &
sleep 1
../scripts/show-vcpu-threads.sh "$PID"
pkill -f 'yes > /dev/null'
```

**Expected output:** the vCPU threads now have `PSR` 2 or 3. They will
never run on any other CPU.

---

## Step 2 — Affinity at the vCPU thread level

Process-level pinning forces all threads onto a shared pool. For an RT VM
you typically want **each vCPU on its own dedicated CPU**, so that two
vCPUs don't time-share a single host CPU.

```bash
sudo taskset -pc 2 "$VCPU0"      # vCPU 0 → host CPU 2 only
sudo taskset -pc 3 "$VCPU1"      # vCPU 1 → host CPU 3 only
```

**What this does.** `taskset -p` (without `-a`) operates on one thread.
The vCPU thread `$VCPU0` can now run only on host CPU 2; `$VCPU1` only on
host CPU 3. They cannot interfere with each other on the same physical
core.

Verify:

```bash
ps -L -p "$PID" -o tid,psr,cls,comm | awk 'NR==1 || /CPU [0-9]+\/KVM/'
```

Force activity and re-check `PSR`:

```bash
../scripts/ssh-vm.sh 2222 'taskset -c 0 yes > /dev/null & taskset -c 1 yes > /dev/null &' 
sleep 1
ps -L -p "$PID" -o tid,psr,cls,comm | awk 'NR==1 || /CPU [0-9]+\/KVM/'
../scripts/ssh-vm.sh 2222 'pkill yes'
```

**Expected output:** `CPU 0/KVM` shows `PSR = 2`, `CPU 1/KVM` shows
`PSR = 3`. Both consistently.

> If your host kernel has `isolcpus=1` and you want the maximum-isolation
> placement, pin one of the vCPUs to CPU 1 (the isolated one): nothing else
> on the host will land there.

---

## Step 3 — Real-time priority for the QEMU process

`SCHED_FIFO` is the classic POSIX real-time scheduling class. Tasks in it
preempt every `SCHED_OTHER` task and run until they voluntarily yield or
are preempted by an equal-or-higher-priority RT task.

Move every thread of the QEMU process to `SCHED_FIFO` priority 50:

```bash
sudo chrt -f -a -p 50 "$PID"
```

**What this does, flag by flag.**

| Flag    | Meaning                                                    |
| ------- | ---------------------------------------------------------- |
| `-f`    | Set policy to **`SCHED_FIFO`**.                            |
| `-a`    | Apply to **all** threads of the process.                   |
| `-p 50` | Operate on PID, set priority to 50.                        |
| `$PID`  | The target process.                                        |

Verify:

```bash
ps -L -p "$PID" -o tid,cls,rtprio,pri,comm | head
```

**Expected output:**

```
   TID CLS RTPRIO PRI COMMAND
 14215  FF     50  90 qemu-system-x86
 14217  FF     50  90 call_rcu
 14220  FF     50  90 CPU 0/KVM
 14221  FF     50  90 CPU 1/KVM
 ...
```

`CLS` is `FF` (SCHED_FIFO), `RTPRIO` is 50. **Every thread of the VM** is
now an RT task.

> **Why apply to all threads (`-a`).** If you only set FIFO on the main
> thread, the vCPU threads remain `SCHED_OTHER` and any
> ordinary host task can preempt them, defeating the purpose. Always use
> `-a` for VM RT priority.

> **Why 50.** It's a typical mid-range RT priority that leaves room for
> system tasks above (kernel threads, IRQ handlers under `PREEMPT_RT`) and
> for user RT tasks below. Adjust to your scheme.

---

## Step 4 — The same controls *inside* the guest

The host has handed the vCPUs a generous slice. Now we set in-guest
priorities the same way.

SSH into the guest:

```bash
../scripts/ssh-vm.sh 2222
```

Inside the guest, run `cyclictest` at `SCHED_FIFO` priority 80:

```bash
chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q
```

**What this does.**

- `chrt -f 80` runs the next command (`cyclictest`) at `SCHED_FIFO` 80.
- `cyclictest` itself **also** sets `-p 99`, which is the priority of its measurement
  thread, set internally via `pthread_setschedparam`.
- `-i 200` is a 200 µs sleep target between iterations.
- `-D 10` runs for 10 seconds.
- `-q` is quiet: only print the final summary.

**Expected output:**

```
T: 0 (   234) P:99 I:200 C:  50000 Min:      2 Act:    4 Avg:    3 Max:      18
```

**What to look for.**

- **Max** is the worst-case latency observed in µs.
- On a well-configured host with `isolcpus=1` and the vCPU pinned to it,
  expect **Max** in the range of 10–50 µs on a stock 6.x kernel, and
  3–10 µs on a `PREEMPT_RT` kernel.
- Without the pinning and FIFO priorities we set, Max would be 100s of
  µs or even ms.

Note the number, exit the guest (`exit`).

---

## Step 5 — Same operations through libvirt

This step assumes Experiment 03 is done and you remember `virsh`. The
purpose is to show that everything we did with `taskset` and `chrt` has a
libvirt equivalent, more idiomatic for production:

```bash
# (Assume a libvirt-managed VM called 'demo' is running, as in Exp 03)

# Pin vCPUs (equivalent to 'taskset -pc N $VCPUx' above)
virsh vcpupin demo 0 2
virsh vcpupin demo 1 3

# Pin the *emulator* (non-vCPU) threads to other CPUs
virsh emulatorpin demo 0,4-7

# CPU bandwidth cap via cgroups
virsh schedinfo demo --live \
    --set vcpu_period=1000000 --set vcpu_quota=500000

# View the current settings
virsh vcpupin demo
virsh emulatorpin demo
virsh schedinfo demo
```

**What to look for.** The same outcomes as Steps 1–3, but persisted in the
domain XML so they survive reboots. In production:

```xml
<cputune>
  <vcpupin vcpu='0' cpuset='2'/>
  <vcpupin vcpu='1' cpuset='3'/>
  <emulatorpin cpuset='0,4-7'/>
  <vcpusched vcpus='0-1' scheduler='fifo' priority='50'/>
</cputune>
```

Notice the `<vcpusched>` element: that's the libvirt way to set
`SCHED_FIFO` priority on vCPU threads. Same effect as `chrt -f`.

---

## Summary — what you should have observed

- `taskset -apc` pins an entire VM to a set of host CPUs; `taskset -pc` on
  individual TIDs pins specific vCPUs to specific CPUs.
- `chrt -f -a -p PRIO PID` moves all threads of the QEMU process to
  `SCHED_FIFO`. The `-a` flag is essential; without it, vCPU threads stay
  in `SCHED_OTHER`.
- In-guest priorities (`chrt -f 80 cyclictest …`) only matter if the host
  also schedules the vCPU thread promptly. The two layers must agree.
- libvirt exposes the same controls declaratively in the domain XML
  (`<cputune>`, `<vcpusched>`) and via `virsh vcpupin`,
  `virsh emulatorpin`, `virsh schedinfo`.

---

## Things to note

- `SCHED_FIFO` tasks that loop without yielding can **lock up** their CPU
  (no preemption by lower-priority work). The kernel guards against
  complete starvation via `/proc/sys/kernel/sched_rt_runtime_us` (default
  950000 of every 1000000 µs = 95%). The remaining 5% is left to
  `SCHED_OTHER`, which is what keeps `ssh` and friends usable.
- On a non-`PREEMPT_RT` kernel, the host can still introduce latency
  through long sections of non-preemptable kernel code (locks, work
  queues, soft IRQs). `PREEMPT_RT` shortens these. For the very lowest
  latencies, both `PREEMPT_RT` on the host **and** pinning + RT priorities
  on the vCPU are needed.
- `taskset` accepts a CPU **list** (`-c 2,3`) or a **mask** (`-p 0x0c`,
  same thing in hex). The list form is friendlier; both work.
- Affinity does not commute with `SCHED_DEADLINE` cleanly (Experiment 06):
  set affinity first if you need a restricted set, otherwise use
  the system as one global pool.

## Cleanup

Restore the QEMU process to `SCHED_OTHER`:

```bash
sudo chrt -o -a -p 0 "$PID"      # SCHED_OTHER, priority 0 (nice 0)
```

Restore default affinity (all CPUs):

```bash
sudo taskset -apc 0-15 "$PID"    # or whatever 0-N your CPU count is
```

Power off:

```bash
../scripts/ssh-vm.sh 2222 poweroff
```

---

## Going further

- `nice` and `renice` work too; they adjust the `SCHED_OTHER` priority
  (the `NI` column). Useful for non-RT VMs you just want to deprioritize.
- `cpuset.cpus` and `cpuset.mems` in cgroups v2 give you stronger isolation
  than `taskset`; they're the cgroup-equivalent of affinity, plus they
  exclude tasks from being moved into the cgroup by other means.
- The kernel docs `Documentation/scheduler/sched-rt-group.rst` and
  `Documentation/scheduler/sched-deadline.rst` are good references. The
  next experiment (06) goes into `SCHED_DEADLINE` in depth.
- `tuned-adm profile realtime-virtual-host` (and the matching `-guest`)
  applies a curated set of these settings as a one-shot RT-friendly
  configuration. Read what it does before using it: it's a long list and
  not all of it may suit your case.
