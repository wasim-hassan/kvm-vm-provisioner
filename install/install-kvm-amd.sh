#!/bin/bash
set -euo pipefail

APP_NAME="KVM (AMD)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

if [ -n "${1:-}" ]; then
    LOGFILE="$1"
    export SETUP_ORCHESTRATED=true
else
    LOGDIR="${SCRIPT_DIR}/../logs"
    mkdir -p "$LOGDIR"
    LOGFILE="$LOGDIR/install-kvm-amd-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOGFILE") 2>&1
fi

heading "$APP_NAME"

# ═══════════════════════════════════════════════════════════════
# STEP 1: INSTALL KVM PACKAGES
# ═══════════════════════════════════════════════════════════════

info "[1/6] Installing KVM packages..."

GUEST_PKGS="virtualbox-guest-additions,open-vm-tools,open-vm-tools-desktop,qemu-guest-agent"

sudo dnf install -y @virtualization \
    --setopt=install_weak_deps=False \
    --exclude="$GUEST_PKGS"

sudo dnf install -y virt-manager virt-viewer swtpm qemu-img guestfs-tools libosinfo edk2-ovmf \
    --setopt=install_weak_deps=False \
    --exclude="$GUEST_PKGS"

success "[1/6] KVM packages installed"

# ═══════════════════════════════════════════════════════════════
# STEP 2: REMOVE GUEST PACKAGES
# ═══════════════════════════════════════════════════════════════

info "[2/6] Removing guest-only packages..."
sudo dnf remove -y virtualbox-guest-additions open-vm-tools open-vm-tools-desktop 2>/dev/null || true
success "[2/6] Guest packages removed"

# ═══════════════════════════════════════════════════════════════
# STEP 3: CONFIGURE SOCKET ACTIVATION
# ═══════════════════════════════════════════════════════════════

info "[3/6] Configuring libvirt socket activation..."
sudo systemctl disable --now libvirtd 2>/dev/null || true
for drv in qemu interface network nodedev nwfilter secret storage lock log; do
    sudo systemctl enable virt${drv}d.socket 2>/dev/null || true
    sudo systemctl enable virt${drv}d-ro.socket 2>/dev/null || true
    sudo systemctl enable virt${drv}d-admin.socket 2>/dev/null || true
done
success "[3/6] Socket activation configured"

# ═══════════════════════════════════════════════════════════════
# STEP 4: INSTALL VIRTIO-WIN
# ═══════════════════════════════════════════════════════════════

info "[4/6] Installing virtio-win drivers for Windows guests..."
sudo dnf install -y virtio-win 2>/dev/null || skip "[4/6] virtio-win not available (RPM Fusion may not be installed)"

sudo tee /etc/yum.repos.d/virtio-win.repo >/dev/null <<'EOF'
# virtio-win yum repo
# Details: https://fedoraproject.org/wiki/Windows_Virtio_Drivers

[virtio-win-stable]
name=virtio-win builds roughly matching what was shipped in latest RHEL
baseurl=https://fedorapeople.org/groups/virt/virtio-win/repo/stable
enabled=1
skip_if_unavailable=1
gpgcheck=0

[virtio-win-latest]
name=Latest virtio-win builds
baseurl=https://fedorapeople.org/groups/virt/virtio-win/repo/latest
enabled=1
skip_if_unavailable=1
gpgcheck=0

[virtio-win-source]
name=virtio-win source RPMs
baseurl=https://fedorapeople.org/groups/virt/virtio-win/repo/srpms
enabled=0
skip_if_unavailable=1
gpgcheck=0
EOF

success "[4/6] virtio-win configured"

# ═══════════════════════════════════════════════════════════════
# STEP 5: ADD USER TO libvirt GROUP
# ═══════════════════════════════════════════════════════════════

info "[5/6] Adding user to libvirt group..."
sudo usermod -aG libvirt "$USER"
success "[5/6] User added to libvirt group"

# ═══════════════════════════════════════════════════════════════
# STEP 6: VALIDATE AND CONFIGURE PERMISSIONS
# ═══════════════════════════════════════════════════════════════

info "[6/6] Validating host virtualization and fixing permissions..."
sudo virt-host-validate qemu || true
sudo setfacl -R -b /var/lib/libvirt/images 2>/dev/null || true
sudo setfacl -R -m u:"$USER":rwX /var/lib/libvirt/images 2>/dev/null || true
sudo setfacl -m d:u:"$USER":rwx /var/lib/libvirt/images 2>/dev/null || true
success "[6/6] Validation and permissions configured"

# ═══════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════

complete_msg "$APP_NAME completed"
logged "Log: $LOGFILE"
