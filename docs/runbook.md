# Runbook: KVM VM Provisioner — Local AWS EC2-Style VM Lifecycle

I wanted to learn KVM and cloud-init properly — not just boot a single VM, but automate the whole lifecycle end-to-end, the way AWS EC2 works. This is what I built over a few sessions: a CLI that creates, manages, and tears down cloud-init VMs on Fedora KVM.

Supports two distros (Ubuntu and AlmaLinux), handles SSH keys intelligently (auto-creates them if missing, picks from existing ones otherwise), works offline with cached images, and verifies every download with SHA256. The errors section at the bottom covers everything that broke along the way and how I fixed it.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     kvm-toggle.sh                           │
│  kvm on   → unmask + enable + start virt services           │
│  kvm off  → shutdown VMs → disable + mask virt services     │
│  kvm      → show service status + VM table                  │
└────────────┬────────────────────────────────────────────────┘
             │ (libvirt available)
             ▼
┌─────────────────────────────────────────────────────────────┐
│                      vm-creator.sh                          │
│  Commands: run, start, stop, destroy, list, ip, prune       │
│                                                             │
│  vm run ubuntu/alma (interactive wizard):                   │
│    1. Name → Distro → Version → Username → Hostname         │
│    2. vCPUs → RAM → Disk → Network                          │
│    3. SSH key selection (auto-create if missing)            │
│    4. Download cloud image (SHA256 verified)                │
│    5. Generate cloud-init user-data via _vm_cloudinit.py    │
│    6. Create seed ISO + clone disk → launch VM              │
│    7. Wait for DHCP IP → print SSH command                  │
└────────────┬────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│                     Libvirt / KVM                           │
│  NAT network (192.168.122.0/24) → DHCP → virsh domifaddr    │
│  cloud-init NoCloud ISO → user-data + meta-data             │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **cloud-init ISO**: `mkisofs` creates a seed ISO with `CIDATA` volume label
2. **disk clone**: cloud image (Ubuntu `.img` or AlmaLinux `.qcow2`) is copied and resized via `qemu-img`
3. **launch**: `virt-install` boots with both disk and seed ISO attached
4. **IP detection**: `virsh domifaddr --source lease` then `--source arp` loop
5. **metadata**: `virsh desc` stores `distro=... version=...` for prune detection

## Component Reference

### `scripts/kvm-toggle.sh`
Toggle virtualization services on/off. Masks/unmasks 9 systemd daemons.

| Flag | Action |
|------|--------|
| `kvm on` | Unmask, enable, and start all virt services. Launch virt-manager. |
| `kvm off` | Shut down running VMs, disable and mask all virt services. |
| `kvm` (no arg) | Show systemd status for each daemon + `virsh list --all`. |

### `scripts/vm-creator.sh`

| Command | Action |
|---------|--------|
| `vm run [ubuntu\|alma]` | Interactive wizard to create and boot a new VM |
| `vm start [name]` | Start a stopped VM (pick interactively) |
| `vm stop [name]` | Shut down a running VM (pick interactively) |
| `vm destroy [name]` | Delete VM + disk (pick interactively, with "Remove all VMs" option) |
| `vm` (no arg) | List all VMs with status and IP addresses |
| `vm ip [name]` | Show IP address of one or all VMs |
| `vm prune [--dry-run]` | Remove orphaned `.qcow2`/`-seed.iso` files and unused cloud images |
| `vm help` | Show usage information |

### `scripts/_vm_cloudinit.py`
Generates `user-data` and `meta-data` for cloud-init NoCloud, with distro-specific package handling:

- **Ubuntu** (`--distro ubuntu`): `apt` with `timeout 30` on `qemu-guest-agent`
- **AlmaLinux** (`--distro almalinux`): `dnf install -y qemu-guest-agent` with `sshd` instead of `ssh`

### `install/install-kvm-amd.sh`
Standalone KVM/QEMU installation script for Fedora (AMD64). Installs virtualization packages via `dnf`, configures libvirt socket activation (modular daemons), sets up virtio-win drivers for Windows guests, adds the current user to the `libvirt` group, and configures ACL permissions on `/var/lib/libvirt/images`. Sources `lib/common.sh` for logging helpers.

### `lib/common.sh`
Bash logging library vendored from `fedora-v3`. Provides `info()`, `success()`, `heading()`, `skip()`, `complete_msg()`, and `logged()` — used by `install-kvm-amd.sh` for consistent colored output during installation.

## Design Decisions

### SSH Key UX
When `~/.ssh/id_ed25519.pub` doesn't exist, the user is asked if they want to create it. If yes, the key is generated and used. If no, existing keys are listed with a custom-path option. If no keys exist at all, the script exits with instructions.

(The auto-create path is the one I use most — typing ssh-keygen flags every single time gets old fast.)

### Multi-Distro Version Discovery
- **Ubuntu**: LTS versions fetched from Canonical's streams API (`com.ubuntu.cloud:released:download.json`), cached to `/tmp/ubuntu-releases.json` with 1-hour TTL. Falls back to a hardcoded codename map (18.04–26.04) if offline.
- **AlmaLinux**: Versions discovered by scraping the AlmaLinux mirror directory listing — dynamically adapts as new versions are released.

### Offline Mode
If no internet is available, the script scans for cached cloud images matching the distro's naming convention. If found, the user can proceed offline. If not, an error message explains what's needed.

### SHA256 Verification
A generalized `verify_sha256()` function accepts a checksum URL and filename pattern — works for both Ubuntu `SHA256SUMS` and AlmaLinux `CHECKSUM` files. Skipped transparently when offline.

### Prune Logic
Two-phase cleanup with `--dry-run` support:
1. **Orphaned VM files**: Scans for `.qcow2` and `-seed.iso` files not associated with any defined libvirt VM
2. **Cloud images**: Scans for `ubuntu-*-server-cloudimg-amd64.img` and `AlmaLinux-*-GenericCloud-*.qcow2`

Both phases require separate confirmation prompts. `--dry-run` previews reclaimable space without deletion.

### "Remove all VMs" Option
When multiple VMs exist, `vm destroy` shows a first option to destroy everything, followed by individual VM names. Single-VM scenarios skip the menu entirely and proceed directly to confirmation.

### `vm ssh` Removed
The `cmd_ssh()` function was removed because it was unnecessary — `vm ssh my-vm` wraps `ssh user@ip`, and wrapping SSH doesn't add anything useful. The IP is already printed after `vm run`, and `vm ip` gives a quick lookup when you need it again.

### `confirm()` y/N Default
The `confirm()` function defaults to "No" on Enter (`[y/N]`). Cancelling is the safe default — the user must explicitly type `y` to proceed with destructive actions (destroy, prune, overwrite). This prevents accidental VM deletion.

### Style Convention
All scripts use plain text with emoji indicators — no ANSI color codes. This keeps output consistent with other `~/.dotutils/` scripts and avoids rendering issues in log files or CI pipelines.

## Session Walkthrough

### Create two VMs (AlmaLinux + Ubuntu)

I usually start with AlmaLinux since it's lighter to boot, then spin up an Ubuntu VM alongside it.

```sh
vm run almalinux
```

```
📊 New Cloud VM
VM name: test-alma
📋 Select distro (ubuntu/almalinux, default: ubuntu): almalinux
🌐 Checking internet connectivity...
✅ Internet OK
🔄 Fetching available AlmaLinux versions...
ℹ️  Available AlmaLinux versions: 8 9 10
AlmaLinux version (default: 9):
Username (default: alma):
Hostname (default: cloud-vm):
vCPUs (default: 2):
RAM in MiB (default: 2048):
Disk size in GB (default: 20):

ℹ️ Available networks:
  default  (NAT — 192.168.122.0/24 via virbr0)
Network name (default: default):
ℹ️ Available SSH public keys on host:
  1) /home/user/.ssh/id_ed25519.pub
  2) Custom path
SSH public key (default: 1):

ℹ️ Creating VM with:
  Name:     test-alma
  Distro:   AlmaLinux 9
  Username: alma
  Hostname: cloud-vm
  vCPUs:    2
  RAM:      2048 MiB
  Disk:     20G
  Network:  default  (NAT — 192.168.122.0/24 via virbr0)
  SSH key:  /home/user/.ssh/id_ed25519.pub
🚦 Proceed?
  [y/N] y

📥 Downloading cloud image...
Saving '/home/user/Documents/kvm-iso/cloudinit-vms/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2'
HTTP response 200  [...]
🔒 Verifying image integrity...
✅ Checksum verified
🔨 Creating disk image...
🟢 Launching VM 'test-alma'...
⏳ Waiting for VM to get an IP address...
........
✅ VM 'test-alma' is ready!
   SSH: ssh alma@192.168.122.111
```

```sh
vm run ubuntu
```

```
...
✅ VM 'test-ubuntu' is ready!
   SSH: ssh ubuntu@192.168.122.31
```

### SSH into VMs

The IP was printed at the end of `vm run`, but if you close the terminal or forget it, `vm ip` will show you all addresses. Straight SSH, no wrapper:

```sh
ssh alma@192.168.122.111
ssh ubuntu@192.168.122.31
```

### List VMs

```sh
vm
```

```
📊 Virtual Machines
  Id   VM Name        Status     IP Address
  ------------------------------------------------
  1    test-alma      running    192.168.122.111
  2    test-ubuntu    running    192.168.122.31
```

### Destroy a specific VM

The interactive picker shows all VMs with a "Remove all" option at the top. When there's only one VM, it skips the menu entirely and asks directly.

```sh
vm destroy
```

```
⚠️ Multiple VMs found. Select one:
1) Remove all VMs
2) test-alma
3) test-ubuntu
#? 2

⚠️ You are about to permanently delete VM 'test-alma' and its disk.
🚦 Are you sure?
  [y/N] y
🔴 Shutting down VM 'test-alma'...
🗑️ VM 'test-alma' has been destroyed
```

### Destroy all VMs

```sh
vm destroy
```

```
⚠️ Multiple VMs found. Select one:
1) Remove all VMs
2) test-ubuntu
#? 1

⚠️ You are about to permanently delete ALL VMs.
🚦 Are you sure?
  [y/N] y
🔴 Shutting down VM 'test-ubuntu'...
🗑️ VM 'test-ubuntu' has been destroyed
```

### Single VM — no menu

When only one VM exists, `vm destroy` skips the menu entirely:

```
⚠️ You are about to permanently delete VM 'test-alma' and its disk.
🚦 Are you sure?
  [y/N] y
```

### Prune orphaned files

```sh
vm prune --dry-run
```

```
📊 Prune Analysis
  Scanning: /home/user/Documents/kvm-iso/cloudinit-vms

  🗃️  Orphaned VM files:
     (none)

  🖼️  Cloud images:
     AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 (555MB)
     → Total: 555MB

  💾 Total reclaimable: ~555MB

⚠️  Dry run — no changes made.
```

### KVM toggle

```sh
kvm off
```

```
🔴 Shutting down running VMs...
🔴 Disabling virtualization services...
[sudo] password for user:
Created symlink '/etc/systemd/system/virtqemud.service' → '/dev/null'.
...
⛔ Virtualization services are stopped and masked
```

```sh
kvm on
```

```
🟢 Enabling virtualization services...
Removed '/etc/systemd/system/virtqemud.service'.
Created symlink '/etc/systemd/system/multi-user.target.wants/virtqemud.service' → '/usr/lib/systemd/system/virtqemud.service'.
...
✅ Virtualization services are running
🟢 Launching Virtual Machine Manager...
```

```sh
kvm
```

```
📊 Virtualization Service Status:
     Loaded: active (running) ...
     Active: active (running) since ...
...
📊 Virtual Machines:
 Id   Name   State
--------------------
```

## Errors

| Error | Why it happened | Fix |
|-------|-----------------|-----|
| `❌ VM '⚠️ Multiple VMs found...' does not exist` | `pick_vm()` printed its informational messages to stdout, which were captured by `$()` and mixed into the VM name alongside the actual selection. (Took me a while to spot — staring at the error, the VM name literally starts with "⚠️" and I still didn't connect it immediately.) | Redirect informational `echo` statements to stderr with `>&2` so only the selection output reaches `$()`. |
| Double prune prompt for the same file | The orphan scanner didn't exclude AlmaLinux cloud images (`AlmaLinux-*-GenericCloud-*.qcow2`), so the same file matched both the orphan list and the cloud images list — triggered two separate confirmation prompts. | Add `[[ "$base" != AlmaLinux-*-GenericCloud-*.qcow2 ]]` exclusion to the orphan scan condition. |
| `kvm on` shows a blinking cursor with no output for 15+ seconds | I suppressed all `systemctl` output with `2>/dev/null` thinking it would look "clean." Instead it made the command look frozen while 27 commands ran silently. | Remove `2>/dev/null` from `unmask`/`enable`/`start` so systemd output shows progress, matching `kvm off`'s visibility. |
| `kvm` (status) shows raw `error: failed to connect to the hypervisor` | The default case ran `virsh list --all` without checking if libvirt was available first. When KVM was off, virsh dumped its connection error to stderr. | Wrap with `virsh list --all 2>/dev/null \|\| echo "(libvirt not available)"`. |
| `sudo apt update` fails on first try after Ubuntu VM boots | Ubuntu's `unattended-upgrades` service runs automatically at boot, holding the `apt` lock for 30–60 seconds. The cloud-init script starts `apt update` immediately, hitting a lock contention. | Normal behavior — `dnf` on AlmaLinux doesn't have this issue. Not a script bug. |
| `vm run` shows double slash in download path (`cloudinit-vms//AlmaLinux-...`) | `ISO_DIR` had a trailing slash (`"$HOME/.../cloudinit-vms/"`) and the path concatenation added another `/` before the filename. | Remove trailing slash from `ISO_DIR` definition. |
| `virsh desc` command fails in non-running VMs | The `--live` flag requires the domain to be running. After VM creation, the VM may still be booting when `virsh desc` runs. | Add `2>/dev/null \|\| true` to allow failure gracefully. |
| Checksum mismatch proceeds instead of aborting | SHA256 verification fails on cached image, but the script only prints a warning and continues — corrupted image gets used to create the VM disk, cloud-init/networking breaks, IP detection loop runs indefinitely. | Remove the corrupted image and `exit 1` so a fresh download happens on retry. |
| `vm destroy` leaves a zombie VM | `virsh shutdown` is asynchronous (sends ACPI signal, returns immediately). The `sleep 2` isn't enough for the VM to power off, so `virsh undefine` fails silently (`\|\| true`). Disk files get deleted anyway, but the VM stays running — diskless, throwing I/O errors. | Use `virsh destroy` (forced poweroff, synchronous) instead of `virsh shutdown` + `sleep 2`.

## Setup

### Dependencies

```sh
sudo dnf install -y @virtualization \
    --setopt=install_weak_deps=False \
    --exclude=virtualbox-guest-additions,open-vm-tools,qemu-guest-agent

sudo dnf install -y virt-manager virt-viewer swtpm qemu-img guestfs-tools libosinfo edk2-ovmf
```

### Wire up shell functions

Add to `~/.bashrc` or `~/.bash_profile`:

```sh
kvm () 
{ 
    "$HOME/kvm-vm-provisioner/scripts/kvm-toggle.sh" "$@"
}
```
```sh
vm () 
{ 
    "$HOME/kvm-vm-provisioner/scripts/vm-creator.sh" "$@"
}
```

Reload:

```sh
source ~/.bashrc
```

## What I'd do differently

- **Use `genisoimage` instead of `mkisofs`** — they're the same tool under the hood, but `genisoimage` is more consistently packaged across distros.
- **Add a config file** — a simple `~/.config/vm-provisioner/config` with defaults for RAM, vCPUs, disk, and default distro would save key taps on repeat runs. The interactive wizard is nice for the first VM, but tedious for the fifth one.
- **Wire up a VM list cache** — `virsh list --all` every time `pick_vm()` runs is fine for 2–3 VMs, but with 20+ it starts to lag. Parse once, cache for a few seconds.
- **Terraform provider** — cloud-init is already declarative; pairing it with a Terraform libvirt provider (`dmacvicar/libvirt`) would make this fully Infrastructure-as-Code. Might look into that next.
- **Don't hardcode `cloudinit-vms` directory name** — it's a variable now, but the cloud image download path still assumes this exact directory layout. A `VM_DATA_DIR` environment variable would clean that up.

## Quick Context

**Cloud-init NoCloud**: The VM boots, finds a CD-ROM labeled `CIDATA`, reads `user-data` and `meta-data` from it, and applies the configuration (user creation, SSH key injection, package installation, hostname). This is the same mechanism AWS EC2 uses — the only difference is the metadata source (NoCloud ISO vs AWS metadata API).

**KVM modular daemons vs monolithic libvirtd**: Modern Fedora splits libvirt into per-driver daemons (`virtqemud`, `virtnetworkd`, etc.) with socket activation — each one starts on-demand when its socket gets a connection. There are 9 daemons total, which is why `kvm on` and `kvm off` loop through so many commands. `kvm off` masks them to prevent any auto-start, and `kvm on` reverses it.

**`set -euo pipefail`**: The script stops on any error (`-e`), treats unset variables as errors (`-u`), and fails a pipeline if any command in it fails (`-o pipefail`). Specific pipelines use `|| true` where failure is expected (e.g., IP detection loops, description writes).

**Systemd masking vs disabling**: `systemctl mask` creates a symlink to `/dev/null`, making it impossible to start the service — even manually. `systemctl disable` only removes the service from startup links. Masking is the nuclear option, used here to ensure KVM services stay off until explicitly enabled.

**Why this exists**: I wanted to really understand EC2's VM lifecycle — not just click through the AWS console, but know what's happening under the hood. Cloud-init is the key insight: AWS and KVM both use the same user-data mechanism, just with a different metadata source. Building this locally means I can test cloud-init configs, play with network topologies, and break things without spending money on EC2.
