# Experiment 02 — A VM is a process, a vCPU is a thread

**Goal:** Use ordinary Linux process tooling (`ps`, `top`, `htop`, signals)
to inspect a running VM. Internalize the single most important KVM concept:
**there is nothing magical about a VM at the host level**.
**Prerequisites:** Setup complete. No prior experiment required, but
Experiment 01 motivates this one.

---

## What this experiment demonstrates

The slide put it succinctly: *"Each VM is a process on the host. The vCPU is
a thread inside that process."* This experiment makes that statement tangible.

You'll observe:

1. The QEMU process and its threads, including the **named vCPU threads** that
   the `debug-threads=on` flag exposes (`CPU 0/KVM`, `CPU 1/KVM`).
2. Per-thread CPU usage, watching the vCPU threads light up under guest load.
3. The host can `kill -STOP` the VM, freezing the guest's wall clock: a
   sharp demonstration of why host-side scheduling matters for RT VMs.

---

## Step 1 — Boot the VM, identify its process and threads

```bash
../scripts/vm1.sh
```

Wait for the login prompt. **Leave this terminal open**; the VM is the
foreground job here. Open a second terminal for the rest of the experiment.

In the second terminal:

```bash
PID=$(pgrep -nf 'name vm1')
echo "QEMU PID = $PID"
```

**What this does.** `pgrep -nf` finds the **n**ewest process whose **f**ull
command line matches `name vm1`, which uniquely identifies our QEMU
instance because of the `-name vm1,debug-threads=on` flag in `vm1.sh`.

Now list all threads of that process:

```bash
ps -L -p "$PID" -o pid,tid,psr,pri,nice,comm
```

**What this does.** `ps -L` shows threads (the "L" = LWPs, Light Weight
Processes, Linux's name for threads). Columns:
- `pid`: process ID (same for every thread).
- `tid`: **thread** ID, different per thread.
- `psr`: the CPU on which this thread last ran ("processor").
- `pri`: kernel priority.
- `nice`: nice value.
- `comm`: thread name (this is the column that makes everything readable).

**Expected output:**

```
   PID    TID PSR PRI  NI COMMAND
 14215  14215   5  19   0 qemu-system-x86
 14215  14217   3  19   0 call_rcu
 14215  14219   9  19   0 IO mon_iothread
 14215  14220   1  19   0 CPU 0/KVM
 14215  14221  11  19   0 CPU 1/KVM
 14215  14222   0  19   0 SPICE Worker
 14215  14223   7  19   0 vnc_worker
```

**What to look for.**

- The lines with `comm = "CPU 0/KVM"` and `"CPU 1/KVM"` are the **vCPU
  threads**, one per `-smp N` value. These are the threads that the host
  kernel schedules in and out of the physical CPU. When one of them is
  running, your guest is running.
- The line with `comm = "qemu-system-x86"` is the main thread; it ran QEMU's
  startup code and now mostly handles signals and the monitor.
- Other threads (`IO mon_iothread`, `call_rcu`, `SPICE Worker`, etc.) are
  QEMU's worker threads for I/O, monitor, and graphical output.
- The `PSR` column changes between runs; the host scheduler moves threads
  across cores. We'll constrain this in Experiment 05.

> **Without `debug-threads=on`** every thread shows `comm = qemu-system-x86`
> and you can't tell which is which. The flag is set in `vm1.sh` for this
> reason.

You can also use the helper script:

```bash
../scripts/show-vcpu-threads.sh "$PID"
```

which prints both the full thread list and a filtered view of just the vCPUs.

---

## Step 2 — Watch the vCPU threads under guest load

In a **third** terminal, log into the guest:

```bash
../scripts/ssh-vm.sh 2222    # password: demo
```

Then open htop to monitor the processes active inside the VM:

```bash
htop
```

Inside the guest (terminal 1), start two CPU-bound tasks (one per vCPU):

```bash
yes > /dev/null &
yes > /dev/null &
```

Back in the second host terminal, watch the per-thread CPU usage:

```bash
htop -p "$PID"
```

Then **press `H`** inside htop to enable per-thread view (the title bar
shows "Display threads"). You'll see one row per thread of the QEMU process.

**Expected output:**

In htop's CPU column, you'll see both `CPU 0/KVM` and `CPU 1/KVM` near
**100 %** each, while the other QEMU threads stay near 0 %.

**What to look for.**

- The vCPU thread CPU usage **matches** what `top` inside the guest shows
  for the `yes` processes. Same physical work, two viewpoints:
    - **Guest view**: two CPUs at 100 %, with `yes` consuming them.
    - **Host view**: two threads of one QEMU process at 100 %.
- The host's other (idle) cores are free. The guest is not "magically
  consuming the whole host"; it consumes exactly what its vCPU threads do.

Stop the load inside the guest:

```bash
pkill yes
```

---

## Step 3 — `kill -STOP` the entire VM

From the host (second terminal):

```bash
# Look at the guest's clock first
../scripts/ssh-vm.sh 2222 date

# Freeze the entire VM at the host level
sudo kill -STOP "$PID"

# Try to talk to the guest now — it will hang
timeout 3 ../scripts/ssh-vm.sh 2222 date
# expected: nothing comes back, then 'timeout' kills the ssh

sleep 5

# Resume
sudo kill -CONT "$PID"

# Look at the clock again
../scripts/ssh-vm.sh 2222 date
```
Alternatively you can use the provided freeze script to do the same thing:

```bash
./freeze.sh
```

**What this does.**

- `kill -STOP` sends `SIGSTOP` to every thread of the process. The Linux
  kernel forcibly suspends them all. The VM, as far as the host is concerned,
  is frozen in time.
- From the **guest's** point of view, **nothing happens**, its vCPU threads
  simply do not run, so its kernel doesn't tick, its scheduler doesn't run,
  network interrupts go unprocessed.
- `kill -CONT` sends `SIGCONT` and the threads resume.

**Expected output.**

The first `date` (before STOP):

```
Tue May 12 13:42:17 UTC 2026
```

While stopped: the second `date` hangs because SSH can't get a response;
`timeout` kills it after 3 seconds.

After CONT: the third `date` returns immediately, but the **wall clock has
jumped**:

```
Tue May 12 13:42:23 UTC 2026     # ~6 seconds later (3 s of timeout + 5 s sleep, minus possible skew)
```

**What to look for.**

The guest had no idea it was stopped. From its perspective, time skipped
forward. Any periodic real-time task running inside the guest would have
missed every deadline during that interval, not because it was preempted
inside the guest, but because **the host did not give it CPU**.

> This is exactly the failure mode an RT virtualization stack must prevent.
> Subsequent experiments (05, 06, 07) build the tools to make sure it doesn't
> happen: pinning, real-time scheduling classes, deadline-based bandwidth
> guarantees, and isolation.

---

## Step 4 — Bonus: signals and other process tools work normally

Try a few:

```bash
# Renice the entire VM (every thread) to a lower priority
sudo renice -n 10 -p "$PID"

# Then look at it
ps -L -p "$PID" -o tid,nice,comm | head

# Restore
sudo renice -n 0 -p "$PID"
```

```bash
# Use perf to count host-level events while the VM is running
sudo perf stat -p "$PID" sleep 5
```

```bash
# Attach gdb to the QEMU process (don't run guest code, just inspect)
sudo gdb -p "$PID"    # then 'info threads', 'bt', 'detach', 'quit'
```

**What to look for.** These tools (`renice`, `perf`, `gdb`) were not
written with virtualization in mind, but they work because QEMU is just a
Linux process. This is the deep point of the whole experiment.

---

## Summary — what you should have observed

- The QEMU process has one thread per vCPU (`CPU 0/KVM`, `CPU 1/KVM`),
  plus a handful of worker threads.
- When a guest CPU is busy, the corresponding **host thread** is busy.
- All standard Linux process tooling (`ps`, `top`, `htop`, `kill`,
  `renice`, `perf`, `gdb`) works unchanged on a VM.
- `kill -STOP` freezes the guest's wall clock. The guest is not aware of the
  freeze; it perceives time skipping forward. **This is the canonical
  noisy-neighbor failure mode.**

---

## Things to note

- The thread name `CPU N/KVM` is set by QEMU at vCPU creation time when
  `debug-threads=on` is given. Without it, identifying vCPUs requires walking
  `/proc/$PID/task/` and parsing each thread's status, though possible but tedious.
- `kill -STOP $PID` stops all threads of the process. Stopping an individual
  thread (`kill -STOP $TID`) also works but only stops that one thread, which
  is rarely what you want for a VM.
- Inside the guest, the **TSC** (Time Stamp Counter) and several wall-clock
  sources advance with host wall time, so the guest sees the jump after a
  STOP/CONT. Some guest kernels print warnings like *"clocksource: timekeeping
  watchdog on CPU0: ..."* after a long stop.

## Cleanup

```bash
# Inside the guest
poweroff

# Or, from the host
pkill -f 'name vm1'
```

---

## Going further

- Compare the per-thread view between a guest doing pure CPU work (`yes`)
  and one doing I/O work (`dd if=/dev/zero of=/tmp/x bs=1M count=1000`).
  The I/O case lights up the `IO mon_iothread` and main threads more, not
  just the vCPU threads.
- Investigate `/proc/$PID/sched`: it shows scheduler statistics for the
  process (run time, wait time, voluntary/involuntary switches). These
  numbers also work as a quality-of-service indicator for an RT VM.
- The `vmtouch`, `pmap`, and `numastat` tools also work on QEMU processes
  and give insight into the guest's memory footprint on the host.
