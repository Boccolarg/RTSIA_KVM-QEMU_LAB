# Experiment 03 — The same VM, but managed by libvirt

**Goal:** Boot the same Debian image through **libvirt** instead of raw
`qemu-system-x86_64`. Tour the production-grade management interface
(`virt-install`, `virsh`, `virt-viewer`) and verify that under the hood it's
still the QEMU/KVM machinery from Experiments 01 and 02.
**Prerequisites:** Setup complete, including `libvirtd` running and the user
in the `libvirt` group. See [`../setup/README.md`](../setup/README.md). The
base image at `~/kvm-demo/debian-base.qcow2` must exist.

---

## What this experiment demonstrates

From the theory: *"Libvirt (external to KVM) allows KVM to securely
manage different VMs (used in management tools)."* This experiment unpacks
this.

- **libvirt is not a hypervisor.** It's a daemon (`libvirtd`) that translates
  a declarative XML domain definition into the `qemu-system-x86_64`
  command-line you would have typed by hand.
- **virsh is the CLI** to libvirtd. It's the standard language of production VM
  management; every higher tool (Cockpit, virt-manager, oVirt, OpenStack
  Nova) sits on libvirt.
- **virt-install** creates a new domain definition by querying you (or
  arguments) and writing the XML.
- **virt-viewer** is a graphical console for SPICE/VNC.

Critically, you'll verify: **the QEMU process under a libvirt-managed VM is
indistinguishable** from the one in Experiment 02. Same threads, same
behavior, same observability, just managed declaratively.

---

## Setup

Make sure the libvirt daemon is running and the default network is up:

```bash
sudo systemctl start libvirtd
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default 2>/dev/null || true
```

**Expected output:** silence on success. `net-start default` may say *"network
default is already active"* and that's fine. The `default` network is libvirt's
NAT network (192.168.122.0/24) with built-in DHCP.

Verify:

```bash
virsh net-list --all
```

**Expected output:**

```
 Name      State    Autostart   Persistent
--------------------------------------------
 default   active   yes         yes
```

---

## Step 1 — Provision a VM with `virt-install`

We'll point `virt-install` at the existing base image (so we don't reinstall
the OS) and let it generate a domain definition.

First, make a **copy** of the base image so the libvirt VM has its own
writable disk in the standard libvirt image directory:

```bash
sudo cp ~/kvm-demo/debian-base.qcow2 /var/lib/libvirt/images/demo.qcow2
```

Now provision:

```bash
virt-install \
    --name demo \
    --memory 1024 \
    --vcpus 2 \
    --cpu host-passthrough \
    --osinfo debian12 \
    --disk path=/var/lib/libvirt/images/demo.qcow2,bus=virtio \
    --network network=default,model=virtio \
    --graphics spice,listen=127.0.0.1 \
    --import \
    --noautoconsole
```

**What this does, flag by flag.**

| Flag                                    | Effect                                                                                        |
| --------------------------------------- | --------------------------------------------------------------------------------------------- |
| `--name demo`                           | The libvirt-internal name for the domain.                                                     |
| `--memory 1024`                         | RAM in MiB.                                                                                   |
| `--vcpus 2`                             | Two vCPUs (two `CPU N/KVM` host threads, just like Exp 02).                                   |
| `--cpu host-passthrough`                | Same as raw QEMU's `-cpu host`: expose the host CPU 1:1.                                      |
| `--osinfo debian12`                     | Tells libvirt which OS this is, so it picks sensible defaults (timers, devices).              |
| `--disk path=...,bus=virtio`            | Attach our qcow2 as a virtio-blk disk (paravirtualized).                                      |
| `--network network=default,model=virtio`| Connect to libvirt's `default` NAT network with a virtio-net NIC.                             |
| `--graphics spice,listen=127.0.0.1`     | Expose a SPICE console (graphical), bound to localhost only.                                  |
| `--import`                              | Use the existing disk image as the boot disk; do not start an installer.                      |
| `--noautoconsole`                       | Don't open virt-viewer automatically; return to the shell once the VM is started.             |

**Expected output:**

```
Starting install...
Creating domain...                                                  0 B  00:00:00
Domain creation completed.
```

The VM is now running. List it:

```bash
virsh list --all
```

**Expected output:**

```
 Id   Name   State
----------------------
 1    demo   running
```

---

## Step 2 — Look at the libvirt-managed VM with the tools from Exp 02

This is the key point: a libvirt-managed VM is **the same machinery** as a raw-QEMU VM.

```bash
ps -ef | grep -E '[q]emu-system-x86' | head
```

**What this does.** Lists the QEMU processes. The `[q]` trick avoids matching the `grep` itself.

**Expected output:**

```
libvirt+ 14821    1 26 13:50 ?    00:00:08 /usr/bin/qemu-system-x86_64 -name guest=demo,debug-threads=on \
  -S -object {"qom-type":"secret","id":"..."} \
  -machine pc-q35-7.2,usb=off,vmport=off,... -accel kvm -cpu host \
  -m 1024 -overcommit mem-lock=off -smp 2,sockets=2,cores=1,threads=1 \
  -uuid ... -display none -vga none ... [much longer]
```

**What to look for.**

- The user is `libvirt+` (libvirt's worker user), not your user. libvirt runs
  QEMU processes under a dedicated unprivileged user for security.
- This is `qemu-system-x86_64` with `-accel kvm` (libvirt's idiom for what we
  wrote `-enable-kvm`), `-cpu host`, `-smp 2`. **Same thing as in Exp 01**,
  just generated for you by libvirt.
- Note `name guest=demo,debug-threads=on`. The vCPU threads are still named
  `CPU N/KVM`.

Now do the Exp 02 inspection on it:

```bash
PID=$(pgrep -nf 'guest=demo')
ps -L -p "$PID" -o tid,psr,cls,pri,comm | head -15
```

**Expected output:** the same kind of output as Exp 02; a main thread,
vCPU threads `CPU 0/KVM` and `CPU 1/KVM`, plus libvirt-specific I/O threads.

---

## Step 3 — Tour the `virsh` verbs

`virsh` is to libvirt what `docker` is to dockerd; the everyday CLI.

**Lifecycle:**

```bash
virsh list --all                # see all domains, even stopped
virsh dominfo demo              # high-level info: state, memory, CPUs, OS type
virsh domstate demo             # current state (running, shut off, paused, ...)
```

**Expected output for `dominfo`:**

```
Id:             1
Name:           demo
UUID:           f5a8...
OS Type:        hvm
State:          running
CPU(s):         2
CPU time:       12.3s
Max memory:     1048576 KiB
Used memory:    1048576 KiB
Persistent:     yes
Autostart:      disable
Managed save:   no
Security model: apparmor
Security DOI:   0
```

**The XML — the source of truth:**

```bash
virsh dumpxml demo | less
```

**What to look for.** A complete domain definition in XML. Find these
sections (they correspond directly to the QEMU command-line flags you saw):

```xml
<vcpu placement='static'>2</vcpu>          <!-- -smp 2 -->
<cpu mode='host-passthrough' ... />        <!-- -cpu host -->

<disk type='file' device='disk'>
  <source file='/home/.../demo.qcow2'/>
  <target dev='vda' bus='virtio'/>
</disk>

<interface type='network'>
  <source network='default'/>
  <model type='virtio'/>
</interface>
```

This is the **declarative** form of an entire VM. Check it into a git repo
and you can recreate the VM anywhere.

**Editing the XML live:**

```bash
virsh edit demo
```

This opens the XML in your `$EDITOR` (vim by default). Changes take effect
on the next start (libvirt won't change a running VM's hardware
configuration without an explicit "live update" verb).

**Console access:**

```bash
virsh console demo
```

**Expected output:** if everything is wired up, the serial console of the
guest appears. Hit Enter to wake the prompt. Detach with **Ctrl-]**.

> If it hangs at `Connected to domain demo / Escape character is ^]`, the
> serial console isn't enabled in the guest. For our cloud image it should
> be, but if it isn't: `virsh shutdown demo`, then `virsh edit demo` and
> ensure there's a `<serial type='pty'><target port='0'/></serial>` and a
> matching `<console>` element, then `virsh start demo`.

**Stop, start, destroy:**

```bash
virsh shutdown demo             # ACPI poweroff (the guest cooperates)
virsh list --all                # state goes to 'shut off'

virsh start demo                # boot again
virsh destroy demo              # pull the plug (not graceful — use shutdown if you can)
virsh start demo
```

**Snapshots (a quick taste):**

```bash
virsh snapshot-create-as demo --name baseline
virsh snapshot-list demo
```

**Expected output:** a single snapshot called `baseline`. In production this
is how you take a known-good point to roll back to.

---

## Step 4 — `virt-viewer` for the graphical console

Open the SPICE console:

```bash
virt-viewer demo &
```

**What this does.** Opens a window that displays the guest's framebuffer.
For a serial-only Debian cloud image, you'll see the text login on the
graphical terminal too, useful if SSH isn't working.

> If you're connecting to a remote host, `virt-viewer --connect
> qemu+ssh://user@host/system demo` proxies the console over SSH. This is
> how admins log in to VMs in production.

Close the window when done. The VM continues running.

---

## Step 5 — A taste of what `virsh` can do that raw QEMU makes painful

This is a preview of Experiments 05 and 06 (where we do the same with raw
`taskset` / `chrt`):

**Pin a vCPU to a host CPU:**

```bash
virsh vcpupin demo 0 1          # pin vCPU 0 to host CPU 1
virsh vcpupin demo 1 3          # pin vCPU 1 to host CPU 3
virsh vcpupin demo               # show current pinnings
```

**Expected output (the last line):**

```
 VCPU   CPU Affinity
----------------------
 0      1
 1      3
```

Verify with the host-side tool from Exp 02:

```bash
ps -L -p "$(pgrep -nf 'guest=demo')" -o tid,psr,comm | awk 'NR==1 || /CPU [0-9]+\/KVM/'
```

The `psr` of the vCPU threads is now constrained to the pinned CPUs.

**Set a CPU scheduling priority on emulator + vCPU threads:**

```bash
virsh schedinfo demo --set vcpu_period=1000000 --set vcpu_quota=500000 --live
```

This applies a CPU bandwidth cap via cgroups (50% per vCPU over a 1ms window).

---

## Step 6 — Clean up the libvirt domain

```bash
virsh shutdown demo             # try graceful first
sleep 5
virsh destroy demo 2>/dev/null  # if still running

virsh snapshot-delete demo --snapshotname baseline 2>/dev/null
virsh undefine demo --remove-all-storage 2>/dev/null \
  || virsh undefine demo        # if --remove-all-storage isn't available
```

**What this does.**

- `shutdown` asks the guest to poweroff via ACPI; gives the guest a chance to
  flush, close files, etc.
- `destroy` is forceful; use only if `shutdown` didn't work.
- `undefine` removes the domain definition. `--remove-all-storage` also
  deletes the disk image, otherwise the qcow2 stays in `/var/lib/libvirt/images/`.

Verify cleanup:

```bash
virsh list --all                # should not list 'demo' anymore
```

---

## Summary — what you should have observed

- A libvirt-managed VM is **literally** a `qemu-system-x86_64` process,
  with the same vCPU threads (`CPU N/KVM`) and the same observability.
- libvirt's value is the **management plane**: a declarative XML schema, a
  CLI (`virsh`) with verbs for the whole VM lifecycle, snapshots, pinning,
  cgroup-based resource control, and a stable API for higher tools.
- Everything we did by hand with `taskset` / `chrt` has a libvirt equivalent (`virsh vcpupin`, `virsh schedinfo`,
  `<cputune>` in the XML). For production: prefer the libvirt path.

---

## Things to note

- The first time `virt-install --import` is run, libvirt may warn about
  AppArmor profiles or about not being able to autodetect the OS. The
  `--osinfo debian12` flag suppresses the OS guess; AppArmor warnings are
  usually harmless.
- The `default` network may collide with other tools (Docker, VirtualBox)
  that also grab `192.168.122.0/24`. If `virsh net-start default` fails with
  a DHCP conflict, edit the network with `virsh net-edit default` and change
  the subnet.
- **libvirt runs QEMU under the `libvirt-qemu` user, not yours.** While libvirt will attempt to automatically `chown` the specific disk image file during `virsh start`, **it cannot bypass your parent directory permissions**. 
  - If your image is in `~/kvm-demo/` and your home directory is locked down (e.g., `750` on Ubuntu), the `libvirt-qemu` user will be blocked from traversing the folder, resulting in a "Permission denied" error.
  - **Best Practice:** Move your VM disks to the default libvirt storage pool (`/var/lib/libvirt/images/`).
  - **Alternative:** If you must keep the image in your home folder, you need to grant traverse (execute) permissions to others on your home directory: `chmod o+x ~`.
- The provided [`demo-domain.xml`](demo-domain.xml) is an equivalent,
  hand-written version of what `virt-install` generated. Edit the disk path if needed
  and try `virsh define demo-domain.xml; virsh start demo` to see it work.

## Cleanup

If you skipped Step 6, run those commands now. Verify:

```bash
virsh list --all
ls /var/lib/libvirt/images/demo.qcow2 2>/dev/null && echo "still there" || echo "gone"
```

---

## Going further

- Read the libvirt domain XML format reference:
  https://libvirt.org/formatdomain.html; every concept in this lab is
  expressible in XML.
- Try `virsh dommemstat`, `virsh domblkstat`, `virsh domiflist`, `virsh
  cpu-stats`, it is telemetry that production monitors scrape every few seconds.
- `virt-top` is `top` for libvirt: it lists all domains with their CPU /
  memory / disk / network rates.
- For mass operations, `virsh` accepts URIs other than the local libvirtd:
  `virsh -c qemu+ssh://user@host/system list`. This is how a single
  workstation manages a whole rack.
