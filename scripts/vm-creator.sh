#!/bin/bash

# ──────── Cloud VM Creator ────────
# CLI for managing cloud-init VMs on KVM/libvirt.
# Supports: Ubuntu, AlmaLinux
# Commands: run [ubuntu|alma], start, stop, destroy, ip, ssh, prune [--dry-run], help

set -euo pipefail

# ── Config ──
ISO_DIR="$HOME/Documents/kvm-iso/cloudinit-vms"
DEFAULT_HOSTNAME="cloud-vm"
DEFAULT_RAM=2048
DEFAULT_VCPUS=2
DEFAULT_DISK_GB=20
RELEASES_CACHE="/tmp/ubuntu-releases.json"
RELEASES_CACHE_TTL=3600

# Ubuntu-specific
DEFAULT_UBUNTU_VERSION="24.04"
DEFAULT_UBUNTU_CODENAME="noble"
UBUNTU_STREAMS_URL="https://cloud-images.ubuntu.com/releases/streams/v1/com.ubuntu.cloud:released:download.json"

# AlmaLinux-specific
DEFAULT_ALMA_VERSION="9"

# ── Helpers ──

check_libvirt() {
    if ! virsh list >/dev/null 2>&1; then
        echo "❌ libvirt is not running. Start it with: kvm on" >&2
        exit 1
    fi
}

pick_vm() {
    local label="$1" candidates="$2" all_label="${3:-}"
    [ -z "$candidates" ] && return 1
    local arr=()
    while IFS= read -r line; do arr+=("$line"); done <<<"$candidates"
    [ "${#arr[@]}" -eq 0 ] && return 1

    if [ "${#arr[@]}" -eq 1 ]; then
        echo "${arr[0]}" && return 0
    fi

    local has_all=false
    if [ -n "$all_label" ]; then
        has_all=true
        arr=("$all_label" "${arr[@]}")
    fi

    echo "⚠️ Multiple VMs found. Select one:" >&2
    select choice in "${arr[@]}"; do
        [ -n "$choice" ] || { echo "Invalid selection." >&2; continue; }
        [ "$has_all" = true ] && [ "$choice" = "$all_label" ] && echo "__ALL__" && return 0
        echo "$choice" && return 0
    done
}

confirm() {
    echo "🚦 $1"
    read -r -p "  [y/N] " response
    [[ "$response" =~ ^[yY] ]]
}

select_ssh_key() {
    local default_key="$HOME/.ssh/id_ed25519.pub"
    local keys=() k idx custom_idx choice
    local default_exists=true

    while IFS= read -r -d '' k; do
        keys+=("$k")
    done < <(find "$HOME/.ssh" -maxdepth 1 -name '*.pub' -type f -print0 2>/dev/null || true)

    [ -f "$default_key" ] || default_exists=false

    # ── Case B: default key not found ──
    if [ "$default_exists" = false ]; then
        echo "⚠️  Default SSH key (~/.ssh/id_ed25519.pub) not found."
        if confirm "Create it now?"; then
            echo "🔑 Generating SSH key pair..."
            ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" || {
                echo "❌ Failed to generate SSH key" >&2
                exit 1
            }
            echo "✅ SSH key created: $default_key"
            keys=()
            while IFS= read -r -d '' k; do
                keys+=("$k")
            done < <(find "$HOME/.ssh" -maxdepth 1 -name '*.pub' -type f -print0 2>/dev/null || true)
        else
            local filtered=()
            for k in "${keys[@]}"; do
                [ "$k" != "$default_key" ] && filtered+=("$k")
            done
            keys=("${filtered[@]}")
            if [ "${#keys[@]}" -eq 0 ]; then
                echo "❌ No SSH public keys found in ~/.ssh/" >&2
                echo "   Generate one with: ssh-keygen -t ed25519" >&2
                exit 1
            fi
            echo "ℹ️ Available SSH public keys on host:"
            idx=1
            for k in "${keys[@]}"; do
                echo "  $idx) $k"
                idx=$((idx + 1))
            done
            custom_idx=$idx
            echo "  $custom_idx) Custom path"
            echo
            read -p "SSH public key (choose 1-$custom_idx): " choice
            [ -z "$choice" ] && {
                echo "❌ No selection made." >&2
                exit 1
            }
            if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#keys[@]}" ] 2>/dev/null; then
                SSH_KEY_PATH="${keys[$((choice - 1))]}"
            elif [ "$choice" = "$custom_idx" ] 2>/dev/null; then
                read -p "Enter path to SSH public key: " SSH_KEY_PATH
                SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
            else
                echo "❌ Invalid choice: $choice" >&2
                exit 1
            fi
            [ ! -f "$SSH_KEY_PATH" ] && {
                echo "❌ SSH key not found: $SSH_KEY_PATH" >&2
                exit 1
            }
            SSH_PUB_KEY=$(cat "$SSH_KEY_PATH")
            return
        fi
    fi

    # ── Case A: default exists (or was just created) ──
    echo "ℹ️ Available SSH public keys on host:"
    idx=1
    for k in "${keys[@]}"; do
        echo "  $idx) $k"
        idx=$((idx + 1))
    done
    custom_idx=$idx
    echo "  $custom_idx) Custom path"
    echo
    read -p "SSH public key (default: 1): " choice
    choice="${choice:-1}"
    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#keys[@]}" ] 2>/dev/null; then
        SSH_KEY_PATH="${keys[$((choice - 1))]}"
    elif [ "$choice" = "$custom_idx" ] 2>/dev/null; then
        read -p "Enter path to SSH public key: " SSH_KEY_PATH
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    else
        echo "❌ Invalid choice: $choice" >&2
        exit 1
    fi

    [ ! -f "$SSH_KEY_PATH" ] && {
        echo "❌ SSH key not found: $SSH_KEY_PATH" >&2
        exit 1
    }
    SSH_PUB_KEY=$(cat "$SSH_KEY_PATH")
}

# ── Cloud-init generation ──

gen_cloudinit() {
    local ci_dir="$1" ssh_key="$2" vm_name="$3"
    python3 "$(dirname "$0")/_vm_cloudinit.py" \
        --ci-dir "$ci_dir" \
        --ssh-key "$ssh_key" \
        --vm-name "$vm_name" \
        --vm-user "$VM_USER" \
        --vm-hostname "$VM_HOSTNAME" \
        --distro "$DISTRO"
}

# ── Network detection ──

describe_network() {
    local net="$1"
    local ip bridge
    ip=$(virsh net-dumpxml "$net" 2>/dev/null | grep -oP "ip address='\K[\d.]+")
    bridge=$(virsh net-info "$net" 2>/dev/null | awk '/Bridge:/{print $2}')
    if [ -n "$ip" ] && [ -n "$bridge" ]; then
        echo "${net}  (NAT — ${ip%.*}.0/24 via ${bridge})"
    else
        echo "$net"
    fi
}

detect_default_network() {
    local running
    running=$(virsh list --state-running --name 2>/dev/null | grep -v '^$' | head -1)
    if [ -n "$running" ]; then
        local net
        net=$(virsh domiflist "$running" 2>/dev/null | awk 'NR>2 {print $3; exit}')
        [ -n "$net" ] && echo "$net" && return
    fi
    echo "default"
}

# ── Version resolution ──

fetch_releases_json() {
    if [ -f "$RELEASES_CACHE" ] && [ $(($(date +%s) - $(stat -c %Y "$RELEASES_CACHE"))) -lt $RELEASES_CACHE_TTL ]; then
        cat "$RELEASES_CACHE"
        return 0
    fi
    local json
    json=$(curl -sL --max-time 10 "$UBUNTU_STREAMS_URL" 2>/dev/null) || true
    if [ -n "$json" ]; then
        echo "$json" >"$RELEASES_CACHE" 2>/dev/null || true
        echo "$json"
    fi
}

get_lts_versions() {
    local json="$1"
    [ -z "$json" ] && return 0
    echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
seen = set()
for key in sorted(data.get('products', {})):
    parts = key.split(':')
    if len(parts) == 4 and 'server' in key and 'amd64' in parts[3]:
        ver = parts[2]
        title = data['products'][key].get('release_title', '')
        if 'LTS' in title and ver not in seen:
            seen.add(ver)
            codename = data['products'][key].get('release', '')
            print(f'{ver} ({codename})')
" 2>/dev/null || true
}

version_to_codename() {
    local json="$1" version="$2"
    local codename=""
    if [ -n "$json" ]; then
        codename=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key in data.get('products', {}):
    parts = key.split(':')
    if len(parts) == 4 and 'server' in key and 'amd64' in parts[3] and parts[2] == sys.argv[1]:
        print(data['products'][key].get('release', ''))
        break
" "$version" 2>/dev/null) || true
    fi
    if [ -z "$codename" ]; then
        case "$version" in
        26.04) echo "resolute" && return 0 ;;
        24.04) echo "noble" && return 0 ;;
        22.04) echo "jammy" && return 0 ;;
        20.04) echo "focal" && return 0 ;;
        18.04) echo "bionic" && return 0 ;;
        *) return 1 ;;
        esac
    fi
    echo "$codename"
}

verify_sha256() {
    local image_path="$1" check_url="$2" filename_pattern="$3"
    local expected
    expected=$(curl -sL --max-time 10 "$check_url" 2>/dev/null | grep "$filename_pattern" | awk '{print $1}') || true
    [ -z "$expected" ] && return 0
    local actual
    actual=$(sha256sum "$image_path" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}

# ── Subcommands ──

cmd_run() {
    local distro_arg="${1:-}"
    [ -n "$distro_arg" ] && shift

    check_libvirt

    echo "📊 New Cloud VM"
    read -p "VM name: " VM_NAME
    [ -z "$VM_NAME" ] && {
        echo "❌ VM name cannot be empty" >&2
        exit 1
    }
    virsh dominfo "$VM_NAME" >/dev/null 2>&1 && {
        echo "❌ VM '$VM_NAME' already exists" >&2
        exit 1
    }

    # ── Distro selection ──
    DISTRO="${distro_arg:-}"
    if [ -z "$DISTRO" ]; then
        echo
        read -p "📋 Select distro (ubuntu/almalinux, default: ubuntu): " DISTRO
        DISTRO="${DISTRO:-ubuntu}"
    fi
    case "$DISTRO" in
    ubuntu) DISTRO="ubuntu" ;;
    alma | almalinux) DISTRO="almalinux" ;;
    *)
        echo "❌ Invalid distro: $DISTRO" >&2
        exit 1
        ;;
    esac

    # ── Distro defaults ──
    case "$DISTRO" in
    ubuntu)
        VM_USER="ubuntu"
        VM_HOSTNAME="$DEFAULT_HOSTNAME"
        VM_VERSION="$DEFAULT_UBUNTU_VERSION"
        RELEASES_JSON=""
        ;;
    almalinux)
        VM_USER="alma"
        VM_HOSTNAME="$DEFAULT_HOSTNAME"
        VM_VERSION="$DEFAULT_ALMA_VERSION"
        ;;
    esac

    # ── Internet check ──
    echo "🌐 Checking internet connectivity..."
    ONLINE=false
    if ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
        echo "✅ Internet OK"
        ONLINE=true
    else
        echo "❌ No internet connectivity"
    fi

    # ── Version selection ──
    case "$DISTRO" in
    ubuntu)
        if [ "$ONLINE" = true ]; then
            echo "🔄 Fetching available Ubuntu versions..."
            RELEASES_JSON=$(fetch_releases_json)
            LTS_VERSIONS=$(get_lts_versions "$RELEASES_JSON")
            if [ -n "$LTS_VERSIONS" ]; then
                echo "ℹ️ Available Ubuntu LTS versions:"
                while IFS= read -r line; do
                    echo "  $line"
                done <<<"$LTS_VERSIONS"
            fi
            echo
            read -p "Ubuntu version (default: $DEFAULT_UBUNTU_VERSION): " VERSION_INPUT
            VM_VERSION="${VERSION_INPUT:-$DEFAULT_UBUNTU_VERSION}"
        else
            echo "ℹ️  Checking cached images..."
            CACHED=$(ls "$ISO_DIR"/ubuntu-*-server-cloudimg-amd64.img 2>/dev/null | xargs -I{} basename {} | sed 's/ubuntu-\(.*\)-server-cloudimg-amd64\.img/\1/') || true
            if echo "$CACHED" | grep -q "^${DEFAULT_UBUNTU_VERSION}$"; then
                echo "ℹ️  Found cached: Ubuntu ${DEFAULT_UBUNTU_VERSION}"
                echo "🚦 Proceed offline with cached image?"
                read -r -p "  [y/N] " response
                if [[ ! "$response" =~ ^[yY] ]]; then
                    echo "⚠️  Cancelled. Connect to the internet and try again."
                    exit 0
                fi
                VM_VERSION="$DEFAULT_UBUNTU_VERSION"
            else
                echo "❌ No cached Ubuntu images found in $ISO_DIR" >&2
                echo "   Connect to the internet or manually download a cloud image." >&2
                exit 1
            fi
        fi
        VM_CODENAME=$(version_to_codename "$RELEASES_JSON" "$VM_VERSION")
        if [ -z "$VM_CODENAME" ]; then
            echo "❌ Unknown Ubuntu version: $VM_VERSION" >&2
            exit 1
        fi
        CLOUD_IMAGE_NAME="ubuntu-${VM_VERSION}-server-cloudimg-amd64.img"
        CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/${VM_CODENAME}/current/${VM_CODENAME}-server-cloudimg-amd64.img"
        VM_OSINFO="ubuntu${VM_VERSION}"
        CHECKSUM_URL="https://cloud-images.ubuntu.com/${VM_CODENAME}/current/SHA256SUMS"
        CHECKSUM_IMAGE_PATTERN="server-cloudimg-amd64.img$"
        ;;
    almalinux)
        if [ "$ONLINE" = true ]; then
            echo "🔄 Fetching available AlmaLinux versions..."
            ALMA_VERSIONS=$(curl -sL --max-time 10 "https://repo.almalinux.org/almalinux/" 2>/dev/null | grep -oP 'href="\K[0-9]+(?=/")' | sort -V) || true
            if [ -n "$ALMA_VERSIONS" ]; then
                echo "ℹ️  Available AlmaLinux versions: $(echo "$ALMA_VERSIONS" | tr '\n' ' ')"
            fi
            echo
            read -p "AlmaLinux version (default: $DEFAULT_ALMA_VERSION): " VER_INPUT
            VM_VERSION="${VER_INPUT:-$DEFAULT_ALMA_VERSION}"
        else
            echo "ℹ️  Checking cached images..."
            CACHED=$(ls "$ISO_DIR"/AlmaLinux-*-GenericCloud-*.qcow2 2>/dev/null | sed 's/.*AlmaLinux-\([0-9]*\)-.*/\1/' | sort -u) || true
            if [ -n "$CACHED" ]; then
                echo "ℹ️  Cached versions: $(echo "$CACHED" | tr '\n' ' ')"
                read -r -p "Proceed offline? [y/N] " response
                if [[ "$response" =~ ^[yY] ]]; then
                    VM_VERSION=$(echo "$CACHED" | head -1)
                else
                    echo "⚠️  Cancelled."
                    exit 0
                fi
            else
                echo "❌ No cached AlmaLinux images found in $ISO_DIR" >&2
                echo "   Connect to the internet or manually download a cloud image." >&2
                exit 1
            fi
        fi
        CLOUD_IMAGE_NAME="AlmaLinux-${VM_VERSION}-GenericCloud-latest.x86_64.qcow2"
        CLOUD_IMAGE_URL="https://repo.almalinux.org/almalinux/${VM_VERSION}/cloud/x86_64/images/AlmaLinux-${VM_VERSION}-GenericCloud-latest.x86_64.qcow2"
        VM_OSINFO="almalinux${VM_VERSION}"
        CHECKSUM_URL="https://repo.almalinux.org/almalinux/${VM_VERSION}/cloud/x86_64/images/CHECKSUM"
        CHECKSUM_IMAGE_PATTERN="AlmaLinux-${VM_VERSION}-GenericCloud-latest.x86_64.qcow2$"
        ;;
    esac

    read -p "Username (default: $VM_USER): " VM_USER_INPUT
    VM_USER="${VM_USER_INPUT:-$VM_USER}"
    read -p "Hostname (default: $VM_HOSTNAME): " VM_HOST_INPUT
    VM_HOSTNAME="${VM_HOST_INPUT:-$VM_HOSTNAME}"
    read -p "vCPUs (default: $DEFAULT_VCPUS): " VCPUS
    VCPUS="${VCPUS:-$DEFAULT_VCPUS}"
    read -p "RAM in MiB (default: $DEFAULT_RAM): " RAM
    RAM="${RAM:-$DEFAULT_RAM}"
    read -p "Disk size in GB (default: $DEFAULT_DISK_GB): " DISK_GB
    DISK_GB="${DISK_GB:-$DEFAULT_DISK_GB}"

    DEFAULT_NET=$(detect_default_network)
    echo
    echo "ℹ️ Available networks:"
    for net in $(virsh net-list --name 2>/dev/null); do
        echo "  $(describe_network "$net")"
    done
    read -p "Network name (default: $DEFAULT_NET): " NET_INPUT
    VM_NET="${NET_INPUT:-$DEFAULT_NET}"

    select_ssh_key

    echo
    echo "ℹ️ Creating VM with:"
    echo "  Name:     $VM_NAME"
    local DISPLAY_DISTRO
    case "$DISTRO" in
    ubuntu) DISPLAY_DISTRO="Ubuntu" ;;
    almalinux) DISPLAY_DISTRO="AlmaLinux" ;;
    esac
    echo "  Distro:   ${DISPLAY_DISTRO} ${VM_VERSION}"
    echo "  Username: $VM_USER"
    echo "  Hostname: $VM_HOSTNAME"
    echo "  vCPUs:    $VCPUS"
    echo "  RAM:      ${RAM} MiB"
    echo "  Disk:     ${DISK_GB}G"
    echo "  Network:  $(describe_network "$VM_NET")"
    echo "  SSH key:  $SSH_KEY_PATH"
    if [ "$ONLINE" = false ]; then
        echo "⚠️  Running offline — using cached image"
    fi
    if [ "$RAM" -lt 3072 ]; then
        echo "⚠️ Note: ${RAM} MiB is below the recommended 3072 MiB -- harmless, VM will work fine."
    fi
    confirm "Proceed?" || {
        echo "⚠️ Cancelled"
        exit 0
    }

    # ── Check/download cloud image ──
    mkdir -p "$ISO_DIR"
    if [ ! -f "$ISO_DIR/$CLOUD_IMAGE_NAME" ]; then
        echo
        echo "📥 Downloading cloud image..."
        wget -O "$ISO_DIR/$CLOUD_IMAGE_NAME" "$CLOUD_IMAGE_URL" || {
            echo "❌ Download failed" >&2
            exit 1
        }
    fi

    # ── Verify checksum ──
    if [ "$ONLINE" = true ]; then
        echo
        echo "🔒 Verifying image integrity..."
        if verify_sha256 "$ISO_DIR/$CLOUD_IMAGE_NAME" "$CHECKSUM_URL" "$CHECKSUM_IMAGE_PATTERN"; then
            echo "✅ Checksum verified"
        else
            echo "⚠️ Checksum mismatch — image may be corrupted."
            echo "   Removing corrupted image..."
            rm -f "$ISO_DIR/$CLOUD_IMAGE_NAME"
            echo "   Run 'vm run' again to download a fresh copy."
            exit 1
        fi
    fi

    # ── Create disk ──
    DISK_PATH="$ISO_DIR/$VM_NAME.qcow2"
    echo
    echo "🔨 Creating disk image..."
    cp "$ISO_DIR/$CLOUD_IMAGE_NAME" "$DISK_PATH"
    qemu-img resize "$DISK_PATH" "${DISK_GB}G" >/dev/null

    # ── Create cloud-init ISO ──
    CLOUD_INIT_DIR=$(mktemp -d)
    trap "rm -rf '$CLOUD_INIT_DIR'" EXIT

    gen_cloudinit "$CLOUD_INIT_DIR" "$SSH_PUB_KEY" "$VM_NAME"

    SEED_ISO="$ISO_DIR/$VM_NAME-seed.iso"
    mkisofs -output "$SEED_ISO" -volid CIDATA -joliet -rock "$CLOUD_INIT_DIR/" >/dev/null 2>&1

    # ── Launch VM ──
    echo
    echo "🟢 Launching VM '$VM_NAME'..."
    virt-install \
        --name "$VM_NAME" \
        --ram "$RAM" \
        --vcpus "$VCPUS" \
        --disk path="$DISK_PATH",format=qcow2 \
        --disk path="$SEED_ISO",device=cdrom \
        --network network="$VM_NET" \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole \
        --osinfo "$VM_OSINFO"

    # ── Store distro metadata for prune detection ──
    virsh desc "$VM_NAME" --live --config "distro=${DISTRO} version=${VM_VERSION}" 2>/dev/null || true

    # ── Wait for IP (indefinite) ──
    echo
    echo "⏳ Waiting for VM to get an IP address (Ctrl+C to cancel)..."
    IP=""
    count=0
    while [ -z "$IP" ]; do
        count=$((count + 1))
        if [ $((count % 10)) -eq 0 ]; then
            echo ""
            echo "⏳ Still waiting... ($((count * 3))s elapsed)"
        fi
        echo -n "."
        IP=$(virsh domifaddr "$VM_NAME" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1) || true
        [ -n "$IP" ] && break
        IP=$(virsh domifaddr "$VM_NAME" --source arp 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1) || true
        [ -n "$IP" ] && break
        sleep 3
    done

    rm -rf "$CLOUD_INIT_DIR" 2>/dev/null || true
    trap - EXIT

    echo
    echo "✅ VM '$VM_NAME' is ready!"
    echo
    echo "   SSH: ssh ${VM_USER}@${IP}"
    echo
}

cmd_start() {
    local name="${1:-}"
    check_libvirt
    [ -z "$name" ] && name=$(pick_vm "start" "$(virsh list --state-shutdown --name 2>/dev/null | grep -v '^$')") || true
    [ -z "$name" ] && {
        echo "⚠️ No stopped VMs found." >&2
        exit 1
    }
    virsh dominfo "$name" >/dev/null 2>&1 || {
        echo "❌ VM '$name' does not exist" >&2
        exit 1
    }
    virsh domstate "$name" 2>/dev/null | grep -q running && {
        echo "⚠️ VM '$name' is already running"
        exit 0
    }
    echo "🟢 Starting VM '$name'..."
    virsh start "$name"
}

cmd_stop() {
    local name="${1:-}"
    check_libvirt
    [ -z "$name" ] && name=$(pick_vm "stop" "$(virsh list --state-running --name 2>/dev/null | grep -v '^$')") || true
    [ -z "$name" ] && {
        echo "⚠️ No running VMs found." >&2
        exit 1
    }
    virsh dominfo "$name" >/dev/null 2>&1 || {
        echo "❌ VM '$name' does not exist" >&2
        exit 1
    }
    echo "🔴 Shutting down VM '$name'..."
    virsh shutdown "$name" 2>/dev/null || virsh destroy "$name"
}

_do_destroy() {
    local name="$1"
    virsh domstate "$name" 2>/dev/null | grep -q running && {
        echo "🔴 Destroying VM '$name'..."
        virsh destroy "$name" 2>/dev/null || true
    }
    virsh undefine "$name" 2>/dev/null || true
    rm -f "$ISO_DIR/$name.qcow2" "$ISO_DIR/$name-seed.iso"
    echo "🗑️ VM '$name' has been destroyed"
}

cmd_destroy() {
    local name="${1:-}"
    check_libvirt
    local all_vms
    all_vms=$(virsh list --all --name 2>/dev/null | grep -v '^$') || true
    [ -z "$name" ] && name=$(pick_vm "destroy" "$all_vms" "Remove all VMs") || true
    [ -z "$name" ] && {
        echo "⚠️ No VMs found." >&2
        exit 1
    }

    if [ "$name" = "__ALL__" ]; then
        echo
        echo "⚠️ You are about to permanently delete ALL VMs."
        confirm "Are you sure?" || {
            echo "⚠️ Cancelled"
            exit 0
        }
        while IFS= read -r vm; do
            [ -z "$vm" ] && continue
            _do_destroy "$vm"
        done <<<"$all_vms"
    else
        virsh dominfo "$name" >/dev/null 2>&1 || {
            echo "❌ VM '$name' does not exist" >&2
            exit 1
        }
        echo
        echo "⚠️ You are about to permanently delete VM '$name' and its disk."
        confirm "Are you sure?" || {
            echo "⚠️ Cancelled"
            exit 0
        }
        _do_destroy "$name"
    fi
}

cmd_list() {
    check_libvirt
    echo
    echo "📊 Virtual Machines"
    printf "  %-3s  %-14s %-10s %-15s\n" "Id" "VM Name" "Status" "IP Address"
    printf "  %s\n" "------------------------------------------------"

    local count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        count=$((count + 1))
        read -r raw_id name state <<<"$line"

        local ip="-"
        if [ "$state" = "running" ]; then
            ip=$(virsh domifaddr "$name" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1) || true
            [ -z "$ip" ] && ip=$(virsh domifaddr "$name" --source arp 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1) || true
            [ -z "$ip" ] && ip="-"
        fi

        printf "  %-3s  %-14s %-10s %-15s\n" "$raw_id" "$name" "$state" "$ip"
    done < <(virsh list --all | tail -n +3)

    [ "$count" -eq 0 ] && echo "  (no VMs)"
    echo
}

cmd_ip() {
    local name="${1:-}"
    check_libvirt
    if [ -z "$name" ]; then
        echo
        echo "📊 VM IP Addresses"
        local found=false
        for vm in $(virsh list --name 2>/dev/null | grep -v '^$'); do
            ips=$(virsh domifaddr "$vm" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+' | tr '\n' ' ')
            [ -z "$ips" ] && ips=$(virsh domifaddr "$vm" --source arp 2>/dev/null | grep -oP '(\d+\.){3}\d+' | tr '\n' ' ')
            [ -n "$ips" ] && echo "  $vm: $ips" || echo "  $vm: (no IP)"
            found=true
        done
        $found || echo "  (no running VMs)"
        echo
        return 0
    fi
    virsh dominfo "$name" >/dev/null 2>&1 || {
        echo "❌ VM '$name' does not exist" >&2
        exit 1
    }
    ips=$(virsh domifaddr "$name" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+')
    [ -z "$ips" ] && ips=$(virsh domifaddr "$name" --source arp 2>/dev/null | grep -oP '(\d+\.){3}\d+')
    [ -n "$ips" ] && echo "$ips" || {
        echo "⚠️ No IP found for '$name'. Is it running?" >&2
        return 1
    }
}

cmd_prune() {
    check_libvirt

    local dry_run=false
    for arg in "$@"; do
        [ "$arg" = "--dry-run" ] && dry_run=true
    done

    echo
    echo "📊 Prune Analysis"
    echo "  Scanning: $ISO_DIR"
    echo

    local defined_vms
    defined_vms=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

    local orphans=() orphan_total=0
    local images=() image_total=0
    local file base vm_name size

    # ── Scan for orphaned VM files ──
    if [ -d "$ISO_DIR" ]; then
        while IFS= read -r -d '' file; do
            base=$(basename "$file")
            vm_name=""
            if [[ "$base" == *.qcow2 ]] && [[ "$base" != ubuntu-*-server-cloudimg-amd64.img ]] && [[ "$base" != AlmaLinux-*-GenericCloud-*.qcow2 ]]; then
                vm_name="${base%.qcow2}"
            elif [[ "$base" == *-seed.iso ]]; then
                vm_name="${base%-seed.iso}"
            fi
            if [ -n "$vm_name" ] && ! echo "$defined_vms" | grep -qxF "$vm_name"; then
                orphans+=("$file")
                orphan_total=$((orphan_total + $(stat -c %s "$file" 2>/dev/null || 0)))
            fi
        done < <(find "$ISO_DIR" -maxdepth 1 -type f \( -name '*.qcow2' -o -name '*-seed.iso' \) -print0 2>/dev/null || true)
    fi

    # ── Scan for cloud images ──
    if [ -d "$ISO_DIR" ]; then
        while IFS= read -r -d '' file; do
            images+=("$file")
            image_total=$((image_total + $(stat -c %s "$file" 2>/dev/null || 0)))
        done < <(find "$ISO_DIR" -maxdepth 1 -type f \( \
            -name 'ubuntu-*-server-cloudimg-amd64.img' -o \
            -name 'AlmaLinux-*-GenericCloud-*.qcow2' \
            \) -print0 2>/dev/null || true)
    fi

    # ── Print orphans ──
    echo "  🗃️  Orphaned VM files:"
    if [ "${#orphans[@]}" -eq 0 ]; then
        echo "     (none)"
    else
        for file in "${orphans[@]}"; do
            size=$(numfmt --to=iec --suffix=B "$(stat -c %s "$file" 2>/dev/null)" 2>/dev/null || echo "?")
            printf "     %-30s (%s)\n" "$(basename "$file")" "$size"
        done
        echo "     → Total: $(numfmt --to=iec --suffix=B "$orphan_total" 2>/dev/null || echo "${orphan_total}B")"
    fi
    echo

    # ── Print images ──
    echo "  🖼️  Cloud images:"
    if [ "${#images[@]}" -eq 0 ]; then
        echo "     (none)"
    else
        for file in "${images[@]}"; do
            size=$(numfmt --to=iec --suffix=B "$(stat -c %s "$file" 2>/dev/null)" 2>/dev/null || echo "?")
            printf "     %-30s (%s)\n" "$(basename "$file")" "$size"
        done
        echo "     → Total: $(numfmt --to=iec --suffix=B "$image_total" 2>/dev/null || echo "${image_total}B")"
    fi
    echo

    local total=$((orphan_total + image_total))
    if [ "$total" -eq 0 ]; then
        echo "  Nothing to prune."
        echo
        return 0
    fi

    echo "  💾 Total reclaimable: ~$(numfmt --to=iec --suffix=B "$total" 2>/dev/null || echo "${total}B")"
    echo

    if [ "$dry_run" = true ]; then
        echo "⚠️  Dry run — no changes made."
        echo "   Run 'ubuntu prune' without --dry-run to remove."
        echo
        return 0
    fi

    # ── Confirm and remove orphans ──
    if [ "${#orphans[@]}" -gt 0 ]; then
        if confirm "Remove orphaned VM files?"; then
            for file in "${orphans[@]}"; do
                rm -f "$file" 2>/dev/null || {
                    echo "  ⚠️  Failed to remove $(basename "$file")"
                    continue
                }
                echo "  ✅ Removed $(basename "$file")"
            done
        else
            echo "  ⚠️  Skipped orphaned VM files."
        fi
    fi

    # ── Confirm and remove images ──
    if [ "${#images[@]}" -gt 0 ]; then
        if confirm "Remove ALL cloud images? (will be re-downloaded if needed)"; then
            for file in "${images[@]}"; do
                rm -f "$file" 2>/dev/null || {
                    echo "  ⚠️  Failed to remove $(basename "$file")"
                    continue
                }
                echo "  ✅ Removed $(basename "$file")"
            done
        else
            echo "  ⚠️  Skipped cloud images."
        fi
    fi

    echo
}

cmd_help() {
    echo "💡 Usage: vm COMMAND [options]"
    echo ""
    echo "  Commands:"
    echo "  run    [ubuntu|alma]  Create and start a new cloud VM (interactive)"
    echo "  start    [name]       Start a stopped VM"
    echo "  stop     [name]       Shut down a running VM"
    echo "  destroy  [name]       Permanently delete a VM and its disk"
    echo "  prune    [--dry-run]  Remove orphaned VM files and unused cloud images"
    echo "  ip       [name]       Show VM IP address(es)"
    echo "  help                  Show this help message"
    echo ""
    echo "  Examples:"
    echo "  vm run                # Prompt for distro and create VM"
    echo "  vm run ubuntu         # Create Ubuntu VM"
    echo "  vm run alma           # Create AlmaLinux VM"
    echo "  vm start my-vm        # Start existing VM"
    echo "  vm stop               # Pick from running VMs to stop"
    echo "  vm destroy broken-vm  # Delete a VM"
    echo "  vm prune              # Remove orphaned files and unused images"
    echo "  vm prune --dry-run    # Preview what would be removed"
    echo "  vm                    # List all VMs (default)"
    echo "  vm ip my-vm           # Get IP of a VM"
}

# ── Main ──
COMMAND="${1:-list}"
shift 2>/dev/null || true
case "$COMMAND" in
run) cmd_run "$@" ;;
start) cmd_start "$@" ;;
stop) cmd_stop "$@" ;;
destroy) cmd_destroy "$@" ;;
destory | destro) cmd_destroy "$@" ;;
prune) cmd_prune "$@" ;;
list) cmd_list "$@" ;;
ip) cmd_ip "$@" ;;
help | --help | -h) cmd_help ;;
*)
    echo "❌ Unknown command: $COMMAND" >&2
    echo
    cmd_help
    exit 1
    ;;
esac
