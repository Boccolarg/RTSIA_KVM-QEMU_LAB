# Experiment 01 — First VM with KVM (and the cost of pure emulation)

**Goal:** Boot the same guest image once with KVM and once with pure QEMU
emulation (TCG), and note the difference in boot time, host CPU
usage, and what `lsmod` reveals about the moving parts.
**Prerequisites:** Setup complete; `~/kvm-demo/debian-base.qcow2` exists. See
[`../setup/README.md`](../setup/README.md).

---

## What this experiment demonstrates

Three concepts from the lesson:

1. **KVM is a kernel module + a character device.** It is not a separate
   "hypervisor process"; it lives inside your running Linux kernel.
2. **QEMU is the user-space partner.** It is the process you launch; it talks
   to KVM through `/dev/kvm` via `ioctl`.
3. **The split matters in practice.** With KVM, guest instructions run
   natively on the CPU (using Intel VT-x or AMD-V). Without KVM, QEMU falls
   back to dynamic binary translation (TCG) — the same image still boots, but
   every guest instruction is translated to host instructions by QEMU. You'll
   see the cost directly.

---

## Step 1 — Boot the VM with KVM

```bash
time ../scripts/vm1.sh
```

**What this does.** Runs `qemu-system-x86_64` with `-enable-kvm -cpu host` and
the rest of the demo flags. The relevant short version is:

```
qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 1G \
    -drive file=~/kvm-demo/debian-base.qcow2,if=virtio,snapshot=on \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net,netdev=n0 \
    -nographic -serial mon:stdio -name vm1,debug-threads=on
```

`time` wraps the whole thing so you can see how long the boot took once you
exit. Keep the terminal in view while booting — the Debian boot messages
should scroll by quickly.

**Expected output (boot phase):**

```
[    0.000000] Linux version 6.1.0-... (debian-kernel@lists.debian.org)
[    0.000000] Command line: BOOT_IMAGE=...
...
Debian GNU/Linux 12 guest ttyS0
guest login:
```

You should reach the login prompt in roughly **10–20 seconds**.

**What to look for.**

- Log in as `root` / `demo`.
- In another terminal (don't close this one):

  ```bash
  top -bn1 -p "$(pgrep -nf 'name vm1')"
  ```

  The QEMU process is using **modest CPU** — typically a few percent on idle,
  a brief spike during boot. The host kernel is doing most of the work via
  KVM, and the host CPU is running guest instructions natively.

Now power off cleanly from inside the guest:

```bash
poweroff
```

You'll see the `time` summary line, something like:

```
real    0m15.123s
user    0m2.456s
sys     0m1.789s
```

---

## Step 2 — Boot the same image without KVM (pure TCG emulation)

```bash
time qemu-system-x86_64 \
    -accel tcg -cpu max -smp 2 -m 1G \
    -drive file=$HOME/kvm-demo/debian-base.qcow2,if=virtio,snapshot=on \
    -nographic -serial mon:stdio
```
Alternatively you can use the script provided in this folder:
```bash
./vm1-tcg.sh
```

**What this does.** Same image, same VM size, but the `-accel tcg` flag forces
QEMU to use its **Tiny Code Generator** — the dynamic binary translator the
slides described. Every guest instruction is now translated into host
instructions by QEMU itself, in user-space, with no hardware help. `-cpu max`
gives the guest as rich a virtual CPU as TCG can emulate (without it, you
get a generic `qemu64` CPU).

**Expected output.**

The same Debian boot, but **much slower**. Where KVM reached the login prompt
in ~15 seconds, TCG typically takes **2–10× longer**, depending on CPU.

**What to look for.**

While it's booting, run `top` on the host:

```bash
top -bn1 -p "$(pgrep -n qemu-system-x86)"
```

The QEMU process is using **close to 100% of one CPU**, sometimes more if
multiple guest cores are active. **This is the cost of dynamic translation.**
Every guest basic block gets translated to host instructions and cached in
QEMU's translation cache (32 MB by default);
re-executions of the same block hit the cache, but the first execution and
every cache eviction pay full translation cost.

When you've seen enough, log in (eventually) and `poweroff`, or hit
**Ctrl-A then X** to terminate QEMU forcefully.

---

## Step 3 — Look at what KVM physically *is*

While no VM is running (or with vm1 running again — your choice):

```bash
ls -l /dev/kvm
lsmod | grep kvm
cat /sys/module/kvm/version 2>/dev/null || echo "(version file not exported on this kernel)"
```

**What this does.** Inspects the kernel-side surface of KVM.

**Expected output:**

```
crw-rw---- 1 root kvm 10, 232 May 12 13:25 /dev/kvm
kvm_amd               212992  0
kvm                  1331200  1 kvm_amd
ccp                   147456  1 kvm_amd
```

(or `kvm_intel` instead of `kvm_amd` on Intel hardware.)

**What to look for.**

- **`/dev/kvm`** is a character device (`c` in the first column), group `kvm`,
  mode `0660`. This is the "userspace entry point" the slides referred to. It
  is the file descriptor through which QEMU asks KVM "make me a VM," "create
  a vCPU," "run that vCPU," etc.
- **Two modules**: the generic `kvm` module (architecture-independent core)
  and the architecture-specific module `kvm_amd` (or `kvm_intel`). This is
  exactly the split the slides described:
    - `kvm.ko` — the **kernel module** that implements vCPU and MMU, exposing
      `/dev/kvm`.
    - `kvm-amd.ko` / `kvm-intel.ko` — the **arch-specific module** that knows
      how to talk to AMD-V / VT-x.
- The user-space side — the **QEMU process** — was what you ran in Steps 1 and
  2. It's the third piece of the slide's three-piece architecture.

---

## Summary — what you should have observed

- A VM is launched with a single `qemu-system-x86_64` command. There is no
  "hypervisor service" running in the background.
- With `-enable-kvm`, guest instructions execute natively on the host CPU
  via Intel VT-x / AMD-V. The QEMU process consumes little host CPU.
- Without KVM (`-accel tcg`), QEMU translates every guest basic block to host
  code in user-space. The same boot takes much longer; the QEMU process
  consumes ~100 % of a host CPU during heavy guest activity.
- The three components from the slide are concretely visible:
    - `kvm` and `kvm_amd`/`kvm_intel` kernel modules → in `lsmod`.
    - The `/dev/kvm` character device → in `ls -l /dev/kvm`.
    - The QEMU user-space process → in `ps aux | grep qemu`.

---

## Things to note

- The flag is `-enable-kvm` (long form) or `-accel kvm` (newer form, both
  work). Some distributions ship `qemu-kvm` as an alias that has it on by
  default — on Debian/Mint it's not aliased, so we set it explicitly.
- `-cpu host` exposes the host's full CPU model to the guest, which is the
  best performance choice when migration to a different CPU is not required.
  Alternatives are `-cpu qemu64` (a small portable subset) or named models
  like `-cpu Skylake-Server`.
- `-snapshot` is doing real work: the on-disk `debian-base.qcow2` is opened
  read-only and writes go to an in-memory overlay that is discarded on exit.
  Run multiple boots in parallel without worrying about disk corruption.
- The `time` command measures the entire lifespan of the process, meaning your human reaction time and the time you spend logged in get mixed into the results. You can use the command ` systemd-analyze` to print a precise summary of the boot time:

```
root@guest:~# systemd-analyze # using KVM
Startup finished in 1.794s (kernel) + 1.829s (userspace) = 3.624s 
graphical.target reached after 1.790s in userspace.

root@guest:~# systemd-analyze # using TCG
Startup finished in 4.878s (kernel) + 7.620s (userspace) = 12.499s 
graphical.target reached after 7.479s in userspace.
```

## Cleanup

If a VM is still running, either:

```bash
poweroff       # from inside the guest
```

or from the host:

```bash
pkill -f 'name vm1'
```

To exit QEMU when the guest is hung: **Ctrl-A then X**.

---

## Going further

- Run `qemu-system-x86_64 --help | head -40` and skim the accelerator section.
  Besides `kvm` and `tcg`, you'll see `xen`, `hax`, `whpx`, `nvmm`, `hvf` —
  these are the analogous mechanisms on other hypervisors / operating systems.
- For an even more dramatic TCG-vs-KVM comparison, try a CPU-intensive
  benchmark inside the guest, e.g. `openssl speed` or `stress-ng --cpu 2`.
  TCG will be a *lot* slower than KVM on these.
