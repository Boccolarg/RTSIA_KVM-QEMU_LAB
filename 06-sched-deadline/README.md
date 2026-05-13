# Experiment 06 — SCHED_DEADLINE: bandwidth-based scheduling for VMs

**Goal:** Use `SCHED_DEADLINE` to give a VM's vCPU thread a **guaranteed CPU
bandwidth** on the host, then do the same for a task **inside the guest**.
Finally, watch the kernel's **admission control** refuse an over-subscription.
**Prerequisites:** Setup complete. Experiment 05 strongly recommended — you
need to be comfortable with `chrt`, vCPU TIDs, and host vs guest scheduling.

---

## What this experiment demonstrates

`SCHED_FIFO` from Experiment 05 gives a task **priority** — it runs whenever
it wants and preempts everything below it. But it has no notion of "this
task is entitled to N% of the CPU and no more." A buggy or runaway FIFO task
can monopolize a CPU.

`SCHED_DEADLINE` is the Linux implementation of **Constant Bandwidth Server
(CBS)** over **Earliest Deadline First (EDF)**. You declare a tuple:

> *(runtime, deadline, period)* — "give me up to **runtime** ns of CPU
> within every **period** ns window; finish by **deadline** ns after my
> wake-up."

The kernel admits the task only if the total deadline bandwidth in the
system stays below a system-wide cap (default 95% of one CPU). Once
admitted, the task is **guaranteed** to receive its runtime in every
period — no more, no less. Even buggy code can't exceed its share, because
the kernel throttles it when the budget is exhausted.

For a VM, this is the cleanest way to say:
*"This RT VM gets 5 ms of CPU every 10 ms (50% bandwidth on one core).
Always. Forever."*

You'll do this in two sub-demos:

- **A (host side):** apply `SCHED_DEADLINE` to a QEMU vCPU thread. The VM
  itself becomes a deadline-scheduled entity.
- **B (in-guest side):** apply `SCHED_DEADLINE` to a task running inside
  the guest. See why this only works reliably if Sub-demo A is also in
  place.

Then the bonus moment: **admission control**. Ask for too much, get
`EBUSY`.

---

## Setup

Compile the small demo program (used for both sub-demos):

```bash
cd 06-sched-deadline
gcc -O2 -o deadline_demo deadline_demo.c
```

**What this is.** A tiny C program that calls `sched_setattr(2)` with the
`SCHED_DEADLINE` policy, then runs a busy-loop and reports what happens.
Usage:

```bash
sudo ./deadline_demo <runtime_ms> <deadline_ms> <period_ms> <total_seconds>
```

Read the comments at the top of [`deadline_demo.c`](deadline_demo.c) for the
gory details.

Boot the VM:

```bash
../scripts/vm1.sh
```

Capture the PID and the vCPU TIDs (this is the third time we're doing this —
the recipe should feel automatic by now):

```bash
PID=$(pgrep -nf 'name vm1')
../scripts/show-vcpu-threads.sh "$PID"

# Replace with the real TIDs from the output:
VCPU0=14220       # <-- TID of "CPU 0/KVM"
VCPU1=14221       # <-- TID of "CPU 1/KVM"
```

> Before we start, check the system-wide RT/deadline budget cap:
>
> ```bash
> cat /proc/sys/kernel/sched_rt_runtime_us /proc/sys/kernel/sched_rt_period_us
> ```
>
> Default is `950000` over `1000000` — i.e. **95% of one CPU** is the global
> ceiling shared by all `SCHED_FIFO`, `SCHED_RR`, and `SCHED_DEADLINE` tasks.
> This is what admission control will enforce.

---

## Sub-demo A — `SCHED_DEADLINE` on the vCPU thread (host side)

Goal: pin vCPU 0 to host CPU 1, give it a deadline budget, and measure RT
latency from inside the guest. Compare against the same setup without the
deadline guarantee.

### A.1 — Baseline: in-guest cyclictest under host stress, no deadline

Pin vCPU 0 to the isolated host CPU 1 (assumes `isolcpus=1` from setup):

```bash
sudo taskset -pc 1 "$VCPU0"
```

In a second terminal, start a **noisy neighbor** on the same host CPU 1 —
to simulate other host work fighting for the vCPU's CPU:

```bash
sudo taskset -c 1 stress-ng --cpu 1 --timeout 60s &
```

In a third terminal, run `cyclictest` inside the guest, pinned to vCPU 0:

```bash
../scripts/ssh-vm.sh 2222 'taskset -c 0 chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output.**

```
T: 0 (...) P:99 I:200 C:  50000 Min: 4 Act: 35 Avg: 28 Max: 4327
```

**What to look for.** `Max` is high — typically several **ms**. The reason:
the vCPU thread is `SCHED_OTHER`, so the host scheduler time-shares CPU 1
between the QEMU vCPU and the `stress-ng` thread. Whenever stress-ng runs,
the guest doesn't run, and from inside the guest it looks like a giant
latency spike — even though the guest itself is doing nothing wrong and has
its task at `SCHED_FIFO` 99.

This is the failure mode. The guest cannot diagnose it because the gap
happened *outside* of guest time.

Kill the stress:

```bash
pkill -f 'stress-ng --cpu'
```

### A.2 — With `SCHED_DEADLINE` on the vCPU thread

Now grant vCPU 0 a deadline budget of **5 ms of CPU every 10 ms** (i.e. 50%
of one core, guaranteed):

```bash
sudo chrt -d --sched-runtime 5000000 \
            --sched-deadline 10000000 \
            --sched-period 10000000 \
            -p 0 "$VCPU0"
```

**What this does, flag by flag.**

| Flag                             | Meaning                                                |
| -------------------------------- | ------------------------------------------------------ |
| `-d`                             | Set policy to `SCHED_DEADLINE`.                        |
| `--sched-runtime 5000000`        | 5 ms of CPU, in nanoseconds.                           |
| `--sched-deadline 10000000`      | Relative deadline = 10 ms from each release.           |
| `--sched-period 10000000`        | Period = 10 ms.                                        |
| `-p 0 <tid>`                     | "Priority 0" (unused for DEADLINE) on this TID.        |

Constraint: `runtime ≤ deadline ≤ period`. Here we set `deadline = period`
(implicit-deadline task — the common case).

Verify:

```bash
chrt -p "$VCPU0"
```

**Expected output:**

```
pid 14220's current scheduling policy: SCHED_DEADLINE
pid 14220's current scheduling priority: 0
pid 14220's current runtime/deadline/period parameters: 5000000/10000000/10000000
```

Now restart the noisy host neighbor:

```bash
sudo taskset -c 1 stress-ng --cpu 1 --timeout 60s &
```

And rerun cyclictest inside the guest:

```bash
../scripts/ssh-vm.sh 2222 'taskset -c 0 chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output.**

```
T: 0 (...) P:99 I:200 C:  50000 Min: 4 Act: 12 Avg: 8 Max: 47
```

**What to look for.**

- `Max` is now in the **tens of µs**, not milliseconds.
- The deadline-scheduled vCPU thread receives its 5 ms within every 10 ms
  window even though `stress-ng` is hammering the same CPU. EDF dispatches
  the vCPU at every period boundary; CBS throttles `stress-ng`
  (which is `SCHED_OTHER`) so it can only run in the gaps left over.
- This is the simplest production-quality RT VM recipe: pin the vCPU to an
  isolated host CPU, give it a deadline budget, done.

Kill the stress and revert:

```bash
pkill -f 'stress-ng --cpu'
sudo chrt -o -p 0 "$VCPU0"     # SCHED_OTHER again
```

---

## Sub-demo B — `SCHED_DEADLINE` inside the guest

Goal: use the same scheduling class for a task **inside** the guest. Show
that this works, but is **only meaningful** if the host has also granted
the underlying vCPU thread its bandwidth (Sub-demo A).

### B.1 — Copy the demo program into the guest

The base image has `build-essential` installed (see `setup/user-data`), so
we can compile inside the guest. Copy the source over via the SSH port-forward:

```bash
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    deadline_demo.c root@127.0.0.1:/root/
```

Build inside the guest:

```bash
../scripts/ssh-vm.sh 2222 'gcc -O2 -o /root/deadline_demo /root/deadline_demo.c'
```

### B.2 — Run it under a reasonable budget

```bash
../scripts/ssh-vm.sh 2222 'sudo /root/deadline_demo 10 100 100 5'
```

**What this does.** Inside the guest, requests `SCHED_DEADLINE` with
runtime=10 ms, deadline=100 ms, period=100 ms (i.e. 10% bandwidth on one
guest vCPU). Runs for 5 wall seconds.

**Expected output:**

```
Requesting SCHED_DEADLINE: runtime=10 ms, deadline=100 ms, period=100 ms
Granted. Running for ~5 s of wall time...
[ 1.0s] iterations=10, max iter elapsed=12500 us
[ 2.0s] iterations=20, max iter elapsed=12500 us
[ 3.0s] iterations=30, max iter elapsed=12500 us
[ 4.0s] iterations=40, max iter elapsed=12500 us
[ 5.0s] iterations=50, max iter elapsed=12500 us
Done. 50 iterations completed in 5.0 s. Max iteration duration: 12500 us.
```

**What to look for.**

- One iteration of the busy loop takes ~12.5 ms of CPU on this host (your
  number will differ). The kernel grants 10 ms per 100 ms period.
- The program loops 50 times in 5 s — that is, **10 iterations per second**.
  Each iteration takes 10 ms of CPU, spaced one per 100 ms period. The
  iteration's *wall-clock* duration is `12.5 ms ≈ 10 ms run + ~2.5 ms throttle
  wait until the next period`.
- The kernel really is enforcing the budget. The task wanted to run
  continuously; the CBS server allowed it 10 ms per 100 ms period.

### B.3 — Why it only works with Sub-demo A

Re-apply the host-side deadline to the vCPU (Sub-demo A), restart noise on
the host CPU, and rerun B.2. The in-guest deadline task still meets its
budget — because the host is honoring its vCPU's budget.

Now **remove** the host-side deadline, leave noise on:

```bash
sudo chrt -o -p 0 "$VCPU0"
sudo taskset -c 1 stress-ng --cpu 1 --timeout 60s &
../scripts/ssh-vm.sh 2222 'sudo /root/deadline_demo 10 100 100 5'
```

**Expected output (degraded):**

```
[ 1.0s] iterations=4, max iter elapsed=247000 us
[ 2.0s] iterations=7, max iter elapsed=320000 us
...
```

**What to look for.** The in-guest deadline task is **still admitted**
(the guest kernel is happy: there's bandwidth available *in its own view*).
But it misses its periods — its iterations are 250+ ms wide. The guest's
view is a lie: the kernel running the guest's view is itself being
preempted by host-side noise that the guest can't see.

**This is the entire lesson on virtualized RT scheduling.** In-guest RT
guarantees are not enough. The host must also honor the vCPU's CPU
budget. The two layers must agree.

Clean up:

```bash
pkill -f 'stress-ng --cpu'
```

---

## Sub-demo C — Admission control rejection

`SCHED_DEADLINE` will refuse to admit a task that would push the total
deadline bandwidth above the system cap. Default cap: 95% of one CPU.
Try to grab 99% on a vCPU thread:

```bash
sudo chrt -d --sched-runtime 99000000 \
            --sched-deadline 100000000 \
            --sched-period 100000000 \
            -p 0 "$VCPU0"
```

**Expected output:**

```
chrt: failed to set pid 14220's policy: Device or resource busy
```

**What to look for.** `EBUSY` — admission control says no. The kernel
refused to grant 99% bandwidth because the total deadline budget would
exceed the system cap. This is the protective property of
`SCHED_DEADLINE`: **the system as a whole cannot be over-subscribed**.
Compare to `SCHED_FIFO`, which lets you create a deadlock by accident.

You can also trigger admission rejection inside the guest:

```bash
../scripts/ssh-vm.sh 2222 'sudo /root/deadline_demo 99 100 100 1'
```

**Expected output:**

```
Requesting SCHED_DEADLINE: runtime=99 ms, deadline=100 ms, period=100 ms
sched_setattr: EBUSY -- admission control rejected.
  The kernel refuses this allocation because the total deadline
  bandwidth (sum of runtime/period for all SCHED_DEADLINE tasks)
  would exceed the system limit. Default is 95% of one CPU.
```

> If you really need more than 95% (e.g. a fully dedicated RT machine
> with no userspace), raise the cap:
>
> ```bash
> sudo sysctl kernel.sched_rt_runtime_us=990000
> ```
>
> Setting it to `-1` removes the cap entirely. **Don't do that on a shared
> system** — without the cap, an RT task can starve everything including
> ssh, your shell, and kernel housekeeping.

---

## Summary — what you should have observed

- `SCHED_DEADLINE` is the way to give a VM a **guaranteed CPU bandwidth**
  on the host: runtime ns per period ns, enforced by the kernel through
  CBS over EDF.
- Applied to a vCPU thread (Sub-demo A), it makes the VM immune to
  host-side noisy neighbors on the same CPU — RT latency from inside the
  guest stays bounded.
- Applied to a task inside the guest (Sub-demo B), it works, but only
  delivers real guarantees if the host has *also* granted the underlying
  vCPU its bandwidth. In-guest RT and host-side RT must agree.
- Admission control (Sub-demo C) rejects allocations that would
  oversubscribe the deadline-bandwidth pool, returning `EBUSY`. The default
  ceiling is 95% of one CPU, shared with `SCHED_FIFO`/`SCHED_RR`.

---

## Things to note

- `chrt`'s long-form deadline flags are `--sched-runtime`, `--sched-deadline`,
  `--sched-period`, in **nanoseconds**. The order of magnitude is the most
  common mistake — `5` means 5 ns, not 5 ms.
- Constraint: `runtime ≤ deadline ≤ period`, all > 0. The kernel enforces
  this.
- A `SCHED_DEADLINE` task **cannot fork** by default (`SCHED_FLAG_RESET_ON_FORK`
  is set on it). Children come back as `SCHED_OTHER`.
- `SCHED_DEADLINE` tasks may not change CPU affinity to a smaller set after
  admission (the admission decision is per the affinity set at the time).
- For the kernel docs, see `Documentation/scheduler/sched-deadline.rst` in
  the kernel tree. The original CBS paper (Abeni & Buttazzo, 1998) is the
  ancestor; the Linux implementation is by Faggioli & Lelli and was merged
  in 3.14 (2014).

## Cleanup

```bash
# Restore default scheduling on the vCPU
sudo chrt -o -p 0 "$VCPU0"

# Kill any leftover stress
pkill -f 'stress-ng --cpu' 2>/dev/null

# Power off the VM
../scripts/ssh-vm.sh 2222 poweroff
```

---

## Going further

- **CONFIG_RT_GROUP_SCHED**: enables per-cgroup RT bandwidth in cgroup v1.
  cgroup v2 lacks it for `SCHED_FIFO`/`SCHED_RR`. This affects how you
  isolate RT VMs in production: with v2 you usually rely on
  `SCHED_DEADLINE` (which is admission-controlled globally and thus
  doesn't need per-cgroup accounting) plus `cpu.max` for non-RT VMs.
- **libvirt + SCHED_DEADLINE**: libvirt added support for setting deadline
  on vCPU threads via `<vcpusched scheduler='deadline' ...>` only recently
  and in a limited way. In practice, many production RT-VM setups apply
  the deadline outside libvirt with a wrapper script that runs `chrt -d`
  on the vCPU TIDs after the VM is started.
- **PREEMPT_RT + SCHED_DEADLINE** is the canonical "real-time as a service"
  setup — PREEMPT_RT bounds kernel-mode latencies (e.g., spinlocks become
  rt_mutex, interrupts become threaded), and SCHED_DEADLINE bounds
  scheduling-mode latencies. Both are needed for sub-100 µs worst-case
  latency on a virtualized RT guest.
- The OSADL latency plots include comparisons of stock, PREEMPT_RT, and
  PREEMPT_RT + SCHED_DEADLINE on the same hardware:
  https://www.osadl.org/Latency-plots.0.html
