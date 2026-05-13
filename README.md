# KVM/QEMU Lab — Real-Time Systems and Industrial Applications

A practical companion to the KVM/QEMU theory lesson of the course **Real-Time Systems and Industrial Applications**.

This is a sequence of hands-on experiments that you can replicate. Each experiment is **a standalone directory with its own README**, written so that you can reproduce it later on your own machine.

---

## Prerequisites

You need:

- A Linux host (Mint/Ubuntu/Debian/Fedora/Arch, kernel ≥ 5.15) on bare metal
- A CPU with VT-x or AMD-V enabled in BIOS, at least 4 cores
- About 8 GiB of free disk space
- ~15 minutes for one-time environment setup

**Start here:** [`setup/README.md`](setup/README.md). It walks through host packages, group memberships, the (optional) RT kernel command line, and the one-shot script that bakes the demo guest image.

When the setup is done, you should be able to run:

```bash
./scripts/vm1.sh
# log in as root / demo, then 'poweroff' or Ctrl-A X
```

and see a Debian guest boot in ~15 seconds.

---

## Lesson map

Six experiments, in suggested order. Each experiment builds on concepts from earlier ones but is self-contained enough to read in isolation.

| # | Directory                                          | Topic                                                            |
|---|----------------------------------------------------|------------------------------------------------------------------|
| 1 | [`01-first-vm-kvm-vs-tcg/`](01-first-vm-kvm-vs-tcg/)             | KVM hardware acceleration vs pure QEMU emulation (TCG)            
| 2 | [`02-vm-as-process/`](02-vm-as-process/)                         | A VM is a process; a vCPU is a thread                            
| 3 | [`03-libvirt-virsh-virt-install/`](03-libvirt-virsh-virt-install/) | Production management: virt-install, virsh, virt-viewer           
| 4 | [`04-device-emulation-virtio/`](04-device-emulation-virtio/)     | Emulated `e1000` vs paravirtualized `virtio-net`; VM-exit cost    
| 5 | [`05-priorities-and-pinning/`](05-priorities-and-pinning/)       | `taskset`, `chrt`, and the two levels of scheduling in a VM       
| 6 | [`06-sched-deadline/`](06-sched-deadline/)                       | `SCHED_DEADLINE` on vCPU threads and inside the guest

What you will learn, in a nutshell:

1. **The basics**: what KVM and QEMU actually are, what they do, and how they relate to the Linux kernel (Exp 1 and 2).
2. **The production view**: how real-world tools (libvirt and its CLI `virsh`) manage VMs without changing the underlying machinery (Exp 3).
3. **I/O paths**: where virtualization overhead comes from at the device level, and how `virtio` reduces it (Exp 4).
4. **Scheduling for RT**: how a VM is a process that can be pinned and prioritized, how `SCHED_DEADLINE` provides bandwidth-based guarantees (Exp 5 and 6).
---

## Repository layout

```
rtis-kvm-qemu-lab/
├── README.md                          # this file
├── setup/                             # one-time host setup
│   ├── README.md
│   ├── build-image.sh                 # cloud-init image baker
│   ├── user-data
│   └── meta-data
├── scripts/                           # helpers used across experiments
│   ├── vm1.sh                         # boot the demo VM (port 2222 → SSH)
│   ├── vm2.sh                         # second VM (port 2223 → SSH)
│   ├── ssh-vm.sh                      # SSH into a VM by port
│   └── show-vcpu-threads.sh           # print vCPU host TIDs
├── 01-first-vm-kvm-vs-tcg/
├── 02-vm-as-process/
├── 03-libvirt-virsh-virt-install/
├── 04-device-emulation-virtio/
├── 05-priorities-and-pinning/
└── 06-sched-deadline/
```

The base image lives **outside** the repo at `~/kvm-demo/debian-base.qcow2`, so that someone who clones the repo doesn't accidentally commit a 5 GiB qcow2.

---

## AMD vs Intel notes

The lab was developed on AMD (Ryzen 7 8845HS), but every experiment works unchanged on Intel. The only places you'll see a difference:

| Concept                              | AMD                | Intel               |
|--------------------------------------|--------------------|---------------------|
| HW virtualization flag in cpuinfo    | `svm`              | `vmx`               |
| KVM arch-specific kernel module      | `kvm_amd`          | `kvm_intel`         |
| Marketing name                       | AMD-V (SVM)        | Intel VT-x          |
| Nested page tables                   | NPT                | EPT                 |
| QEMU / KVM / libvirt commands        | identical          | identical           |

For everything else (`taskset`, `chrt`, `cyclictest`, `virsh`, perf events, cgroups, memguard), the commands are the same on both vendors.

---

## Conventions used in the experiment READMEs

Each experiment's `README.md` follows the same template:

- **Goal**: one sentence, what you'll see by the end.
- **What this experiment demonstrates**: the underlying concept.
- **Setup**: anything to do before starting.
- **Step N: <action>**, numbered steps, each with:
  - The command(s) to run.
  - **What this does**: what the command actually does, line by line.
  - **Expected output**: a sample of what you should see (your numbers will differ, but the shape should match).
  - **What to look for / things to note**: annotations on the output.
- **Summary — what you should have observed**: bullet list of takeaways.
- **Cleanup**: how to stop everything cleanly before the next experiment.
- **Going further**: optional pointers if you want to dig deeper.

The commands are copy-pasteable. Where a command needs `sudo`, it's written with `sudo`; where it doesn't, it isn't.

---

## Quick reference: starting and stopping VMs

```bash
# Start vm1 in the foreground (Ctrl-A X to quit, or 'poweroff' from inside)
./scripts/vm1.sh

# In another terminal: log in to it
./scripts/ssh-vm.sh 2222

# Find its PID and its vCPU threads
PID=$(pgrep -nf 'name vm1')
./scripts/show-vcpu-threads.sh $PID

# Stop it cleanly from the host:
sudo kill -TERM "$PID"      # asks QEMU to power off
# or, ungentle:
sudo kill -9 "$PID"
```

For experiments that use two VMs, run `./scripts/vm2.sh` in another terminal; it forwards SSH to port 2223 and uses its own monitor socket.

---

## Cleanup between experiments

Most experiments leave nothing behind because the base image is used with `-snapshot` (changes are discarded at shutdown) and no host-side state is persisted. The things that do persist:

| State                              | How to clear                                              |
| ---------------------------------- | --------------------------------------------------------- |
| A still-running QEMU process       | `pkill -f 'name vm1'` / `pkill -f 'name vm2'`             |
| Affinity changes on host CPUs      | Disappear when QEMU exits                                 |
| `chrt` scheduling-class changes    | Disappear when the process exits                          |                                 |
| libvirt domains defined in Exp 03  | `virsh destroy <name>; virsh undefine <name>`             |

The experiment READMEs have a **Cleanup** section that lists what to undo.

---

## Going further

Some pointers for after the lesson:

- **KVM documentation**: https://www.linux-kvm.org/page/Documents
- **QEMU documentation**: https://www.qemu.org/docs/master/
- **libvirt domain XML reference**: https://libvirt.org/formatdomain.html
- **The PREEMPT_RT wiki**: https://wiki.linuxfoundation.org/realtime/start
- **OSADL Latency Plots** for real numbers across many platforms: https://www.osadl.org/Latency-plots.0.html
- **`perf kvm`** for tracing VM-exit reasons in detail: `man 1 perf-kvm-stat`
- **Project Mu** and **vfio-pci** for hardware passthrough (the "extreme" path to low-latency I/O in VMs)

For curiosity: the QEMU source has a `docs/devel/` directory full of high-quality deep-dives, including [the migration protocol](https://www.qemu.org/docs/master/devel/migration/main.html) and [the virtio specification implementations](https://www.qemu.org/docs/master/devel/virtio-net-failover.html).
