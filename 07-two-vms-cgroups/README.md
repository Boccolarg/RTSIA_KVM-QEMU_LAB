# Experiment 07 — Two VMs competing, and isolation with cgroups v2

**Goal:** Run two VMs simultaneously. Watch a "noisy" VM destroy a
"critical" VM's RT latency when they share host CPUs. Then progressively
restore isolation: first with CPU pinning, then with **cgroups v2** as
an extra safety net.
**Prerequisites:** Setup complete. Experiments 02 and 05 strongly
recommended.

> **What this experiment adds that the others don't.** Experiment 05
> showed how to pin and prioritize one VM. This one shows what happens when
> you have **two** VMs and finite host CPUs — the world your hypervisor
> actually runs in.

## Host CPUs used

This experiment uses **CPU 1** for the critical VM and **CPU 2** for the noisy
neighbor (across stages). Both should be isolated; the recommended cmdline in
[`../setup/README.md`](../setup/README.md) (`isolcpus=1-3`) covers this.

---

## What this experiment demonstrates

Pinning vCPUs to disjoint CPUs (Exp 05) is the first line of defense, but
it's not sufficient in real deployments where:

- You may want to overcommit (more vCPUs than physical CPUs).
- You may want to allow burst behavior but cap long-term usage.
- You may need to enforce policies that survive operator mistakes (someone
  ssh'ing in and starting a heavy job in the wrong VM).

**cgroups v2** (Linux Control Groups, version 2) provide hierarchical
accounting and limiting of resources. They are the same machinery that
Docker, systemd, and Kubernetes use under the hood. Libvirt also uses
cgroups internally to enforce `virsh schedinfo`-style limits.

You'll exercise:

1. The catastrophic case: two VMs sharing a core, one of them noisy.
2. CPU pinning to disjoint cores — fixes most of it.
3. **A cgroup v2 hierarchy** with `cpu.max` to cap the noisy VM's
   bandwidth regardless of where it runs.

---

## A 90-second primer on cgroups v2 (since the course hasn't covered them)

cgroups are a kernel feature for grouping processes and applying limits.
The "v2" version (mainstream since 2016, default on most modern distros)
exposes them as a single unified file hierarchy under `/sys/fs/cgroup/`:

```
/sys/fs/cgroup/                 <-- the root cgroup
├── cpu.max                     <-- "$MAX $PERIOD" — bandwidth cap
├── cpuset.cpus                 <-- which host CPUs are allowed
├── cgroup.procs                <-- one PID per line — which procs are in
├── cgroup.subtree_control      <-- which controllers are enabled below
├── group-A/                    <-- a child cgroup
│   ├── cpu.max
│   ├── cgroup.procs
│   ├── ...
│   └── subgroup-1/             <-- arbitrarily nested
└── group-B/
    ├── ...
```

The contract:

- **A process is in exactly one cgroup at a time.** To put a process into
  a cgroup, write its PID into that cgroup's `cgroup.procs`.
- **Each cgroup has files that set limits** on the resources its members
  consume. The most relevant here: `cpu.max` (CPU bandwidth) and
  `cpuset.cpus` (CPU affinity, but enforced for *new* threads too).
- **Limits compose hierarchically.** A child cgroup's effective limit is
  the more restrictive of its own and any ancestor's.
- **Threads of the same process can be in different cgroups** only with
  the "threaded" controller (advanced, not needed here). Normally, when
  you put a QEMU PID into a cgroup, **all its threads** go with it —
  exactly what we want.

For this experiment, we'll create a small tree:

```
/sys/fs/cgroup/rtdemo/
├── critical/      <-- vm1 lives here (the "RT" VM we want to protect)
└── noisy/         <-- vm2 lives here (the noisy neighbor we'll constrain)
```

---

## Setup

Pre-check the cgroup version on the host:

```bash
mount | grep -w cgroup
```

**Expected output (cgroup v2 unified):**

```
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate)
```

If you see multiple `cgroup` mounts (one per controller — `cpu`, `cpuset`,
`memory`, ...), you're on cgroup v1 hybrid mode. Modern Ubuntu/Debian/Mint
default to v2 unified, which is what we assume here.

Boot **both** VMs. In two separate terminals:

```bash
# Terminal 1
../scripts/vm1.sh
```

```bash
# Terminal 2
../scripts/vm2.sh
```

Wait for both to reach a login prompt.

In a host terminal:

```bash
PID1=$(pgrep -nf 'name vm1')
PID2=$(pgrep -nf 'name vm2')
echo "vm1 PID=$PID1, vm2 PID=$PID2"
```

---

## Stage 1 — The catastrophic baseline (no isolation)

Pin **both** VMs to the same single host CPU 1 (isolated by `isolcpus`):

```bash
sudo taskset -apc 1 "$PID1"
sudo taskset -apc 1 "$PID2"
```

In Terminal 3, inside vm2, start a noisy CPU load:

```bash
../scripts/ssh-vm.sh 2223 'stress-ng --cpu 2 --timeout 30s' &
```

In Terminal 4, inside vm1, run `cyclictest`:

```bash
../scripts/ssh-vm.sh 2222 'chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output:**

```
T: 0 (...) P:99 I:200 C:  50000 Min: 4 Act: 521 Avg: 287 Max: 12831
```

**What to look for.** **`Max` in the tens of milliseconds.** vm1's RT task
has FIFO priority 99 *inside its guest*, but on the host both QEMU
processes are `SCHED_OTHER` and share CPU 1 equally. When vm2's vCPU
thread is on the CPU, vm1's vCPU thread is not — and from vm1's
perspective, the world stops for ~10 ms at a time.

This is the catastrophic case. Wait for the stress and cyclictest to
finish (or `pkill -f stress-ng`).

---

## Stage 2 — Disjoint pinning (the Exp 05 fix)

Pin vm1 to host CPU 1 (isolated), vm2 to host CPU 2:

```bash
sudo taskset -apc 1 "$PID1"
sudo taskset -apc 2 "$PID2"
```

Rerun the experiment:

```bash
# Terminal 3: noise in vm2
../scripts/ssh-vm.sh 2223 'stress-ng --cpu 2 --timeout 30s' &

# Terminal 4: cyclictest in vm1
../scripts/ssh-vm.sh 2222 'chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output:**

```
T: 0 (...) P:99 I:200 C:  50000 Min: 3 Act: 14 Avg: 9 Max: 67
```

**What to look for.** `Max` is back to **tens of µs**. The vCPUs are on
different physical CPUs and don't time-share. Compute is isolated. We're
in good shape — for compute.

The residual jitter is from shared **other** resources: last-level cache,
memory bandwidth, IRQs not yet routed away from CPU 1. We don't fix those
here — Experiment 08 (memguard) addresses memory-bandwidth contention.

---

## Stage 3 — cgroups v2 as an extra safety belt

Pinning relies on the operator getting affinity right. cgroups give you a
**hard cap** that survives misconfiguration. Build the hierarchy:

```bash
sudo mkdir -p /sys/fs/cgroup/rtdemo/critical
sudo mkdir -p /sys/fs/cgroup/rtdemo/noisy
```

**What this does.** Creating a directory under `/sys/fs/cgroup/` *is*
creating a cgroup. The kernel populates the new directory with the
controller files (`cpu.max`, `cpu.weight`, `cpuset.cpus`, `cgroup.procs`,
etc.) automatically.

Enable the controllers we need (`cpu` and `cpuset`) in the parent:

```bash
# Enable for children of root
echo "+cpu +cpuset" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

# Enable for grandchildren (i.e. for critical/ and noisy/)
echo "+cpu +cpuset" | sudo tee /sys/fs/cgroup/rtdemo/cgroup.subtree_control
```

**What this does.** Each cgroup has a `subtree_control` file listing which
controllers its **children** may use. You enable controllers top-down. Now
`/sys/fs/cgroup/rtdemo/critical/` and `noisy/` have `cpu.*` and `cpuset.*`
files.

> If `tee` complains with `Invalid argument` on the second line, you have
> a process directly in the root or `rtdemo` cgroup; with v2's
> "no-internal-processes" rule, controllers can't be delegated while
> non-leaf cgroups have member procs. The simplest fix is to set
> `rtdemo`'s `cgroup.procs` empty (it should already be), or to use a
> structure where `rtdemo/` is itself empty and only its children hold
> processes — which is what we're doing.

### 3.1 — Set bandwidth limits

**Critical VM**: full bandwidth on its CPU.

```bash
echo "max 100000" | sudo tee /sys/fs/cgroup/rtdemo/critical/cpu.max
echo "1"          | sudo tee /sys/fs/cgroup/rtdemo/critical/cpuset.cpus
```

**Noisy VM**: capped at **30% of a CPU**, restricted to CPU 2.

```bash
echo "30000 100000" | sudo tee /sys/fs/cgroup/rtdemo/noisy/cpu.max
echo "2"            | sudo tee /sys/fs/cgroup/rtdemo/noisy/cpuset.cpus
```

**What this does.** `cpu.max` is two numbers: *(quota, period)* in
microseconds. `30000 100000` means *30 ms of CPU every 100 ms* — a hard
30% cap. The cgroup's processes will be **throttled** if they try to
exceed this. `cpuset.cpus` restricts which physical CPUs the cgroup's
threads may run on (cgroup-enforced affinity).

### 3.2 — Move the VMs into their cgroups

```bash
echo "$PID1" | sudo tee /sys/fs/cgroup/rtdemo/critical/cgroup.procs
echo "$PID2" | sudo tee /sys/fs/cgroup/rtdemo/noisy/cgroup.procs
```

**What this does.** Writing a PID into a cgroup's `cgroup.procs` moves
**all threads of that process** into the cgroup (because we did not enable
the `threaded` controller, which would allow split-threading). vm1's QEMU
process and all its vCPU threads are now in `critical`; vm2 is in `noisy`.

Verify:

```bash
cat /sys/fs/cgroup/rtdemo/critical/cgroup.procs
cat /sys/fs/cgroup/rtdemo/noisy/cgroup.procs
ls /sys/fs/cgroup/rtdemo/noisy/
```

**Expected output:** the PIDs you set, and a directory listing showing
`cpu.max`, `cpuset.cpus`, `cpu.stat`, etc.

### 3.3 — Verify the cap with deliberate overload

In vm2, try to use a **full CPU** of compute:

```bash
../scripts/ssh-vm.sh 2223 'stress-ng --cpu 1 --timeout 15s' &
```

On the host, watch what stress-ng actually gets:

```bash
top -bn1 -p "$PID2" -o '%CPU' | head
```

**Expected output:** the QEMU process for vm2 stays around **30 % CPU
total**, not 100 %, even though the guest is trying for 100 %. cgroup
throttling at work.

The `cpu.stat` file gives a quantitative view:

```bash
cat /sys/fs/cgroup/rtdemo/noisy/cpu.stat
```

**Expected output:**

```
usage_usec 4234567
user_usec 4123456
system_usec 111111
nr_periods 250
nr_throttled 248
throttled_usec 8567000
```

**What to look for.** `nr_throttled` is high — almost every period the
cgroup hit its cap and was throttled. `throttled_usec` is the cumulative
time the cgroup spent waiting at the boundary. The cap is being enforced
in real time.

Meanwhile, run cyclictest in vm1:

```bash
../scripts/ssh-vm.sh 2222 'chrt -f 80 cyclictest -p 99 -i 200 -D 10 -q'
```

**Expected output:**

```
T: 0 (...) P:99 I:200 C:  50000 Min: 3 Act: 12 Avg: 8 Max: 52
```

Still low. The critical VM is unaffected by vm2's hopeful attempts to
consume more CPU.

---

## Summary — what you should have observed

| Stage | Setup                                 | vm1 cyclictest Max | Lesson                                        |
|-------|---------------------------------------|--------------------|-----------------------------------------------|
| 1     | Both VMs on CPU 1, no other controls  | ~10s of ms         | Shared CPUs = no isolation                    |
| 2     | Disjoint pinning (vm1=CPU1, vm2=CPU2) | ~50 µs             | Pinning fixes compute interference            |
| 3     | + cgroups v2 cap on vm2 at 30%        | ~50 µs (held)      | cgroups guarantee the cap even on overload    |

The graceful interpretation: **pinning is a placement decision; cgroups
are a policy decision.** You need both. Pinning says "where"; cgroups say
"how much, no matter what."

---

## Things to note

- **`cpu.max` in cgroup v2 does NOT govern `SCHED_FIFO`/`SCHED_RR` tasks.**
  RT classes bypass CFS bandwidth control entirely. If our vCPU threads
  were in `SCHED_FIFO`, the `cpu.max` cap would not apply to them — they'd
  ignore it. In cgroup v1 there was a separate `cpu.rt_runtime_us` knob
  for RT bandwidth per cgroup; v2 dropped it. The practical implication
  for RT VMs: use `SCHED_DEADLINE` for vCPU threads (Exp 06, admission
  control is global) and cgroup `cpu.max` only for the `SCHED_OTHER` VMs
  you want to throttle.
- **`cpuset.cpus` is stronger than `taskset`.** It restricts the entire
  cgroup; tasks that newly enter the cgroup automatically inherit the
  restriction. With plain `taskset`, a task could change its own
  affinity. cgroups make the operator's policy stick.
- **Libvirt does all of this for you.** When you do `virsh schedinfo
  --set vcpu_quota=...`, libvirt is editing `cpu.max` of a per-VM cgroup
  it created. The XML element is `<cputune><quota>...</quota></cputune>`.
  This experiment is the layer underneath libvirt.
- The `nsdelegate` mount option (visible in the `mount` output earlier)
  affects unprivileged delegation of cgroups to namespaces, mostly
  relevant for container runtimes. Not relevant here.

## Cleanup

In reverse order of creation:

```bash
# Move VMs back to the root cgroup
echo "$PID1" | sudo tee /sys/fs/cgroup/cgroup.procs
echo "$PID2" | sudo tee /sys/fs/cgroup/cgroup.procs

# Remove the cgroups (must be empty)
sudo rmdir /sys/fs/cgroup/rtdemo/critical
sudo rmdir /sys/fs/cgroup/rtdemo/noisy
sudo rmdir /sys/fs/cgroup/rtdemo

# Power off both VMs
../scripts/ssh-vm.sh 2222 poweroff
../scripts/ssh-vm.sh 2223 poweroff
```

Verify the cleanup:

```bash
ls /sys/fs/cgroup/rtdemo 2>/dev/null && echo "still there" || echo "gone"
pgrep -af 'name vm[12]' || echo "all VMs stopped"
```

---

## Going further

- Read `Documentation/admin-guide/cgroup-v2.rst` in the kernel tree. It is
  the canonical reference and surprisingly readable.
- `cpu.weight` (default 100; range 1–10000) is the **proportional**
  CPU controller — instead of a hard cap, it sets a relative share when
  there is contention. Useful for "vm1 is twice as important as vm2"
  semantics without hard quotas.
- `memory.max` and `io.max` are the analogous controllers for memory and
  I/O. RAM caps for VMs via cgroups become interesting when you have
  many VMs and want to prevent one from OOM-killing the host.
- `systemd-run --slice=...` and `systemctl set-property` are the systemd
  way of doing the same; instead of editing files under
  `/sys/fs/cgroup/`, you set unit properties and systemd writes them.
  This is how systemd's `cpu.max=30%` shorthand maps to the cgroup
  filesystem.
- For multi-tenant RT-VM hosting, the typical stack is: `PREEMPT_RT`
  host + `SCHED_DEADLINE` on RT-VM vCPU threads + cgroup v2 `cpu.weight`
  on non-RT VMs + memguard (Exp 08) for memory-bandwidth isolation.
