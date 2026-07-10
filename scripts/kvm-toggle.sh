#!/bin/bash

# ──────── KVM toggle ────────
# Starts, stops, or checks the status of KVM/libvirt virtualization services.

DAEMONS="virtqemud virtinterfaced virtnetworkd virtnodedevd virtnwfilterd virtsecretd virtstoraged virtlockd virtlogd"

case "$1" in
on)
    echo "🟢 Enabling virtualization services..."
    for svc in $DAEMONS; do
        sudo systemctl unmask "${svc}.service" || true
        sudo systemctl enable "${svc}.service" || true
        sudo systemctl start "${svc}.service" || true
    done
    echo "✅ Virtualization services are running"

    echo "🟢 Launching Virtual Machine Manager..."
    nohup virt-manager >/dev/null 2>&1 &
    ;;

off)
    echo "🔴 Shutting down running VMs..."
    RUNNING=$(virsh list --state-running --name 2>/dev/null)
    if [ -n "$RUNNING" ]; then
        for vm in $RUNNING; do
            echo "  🔴 Shutting down '$vm'..."
            virsh shutdown "$vm" 2>/dev/null || virsh destroy "$vm" 2>/dev/null || true
        done
        echo "  ⏳ Waiting 5 seconds for VMs to shut down..."
        sleep 5
    fi

    echo "🔴 Disabling virtualization services..."
    for svc in $DAEMONS; do
        sudo systemctl disable --now ${svc}.service 2>/dev/null || true
        sudo systemctl mask ${svc}.service
    done
    echo "⛔ Virtualization services are stopped and masked"
    ;;

--help|-h)
    echo "💡 Usage: kvm {on|off|--help}"
    echo ""
    echo "  on       Unmask + enable + start virt services, launch virt-manager"
    echo "  off      Shutdown VMs, then disable + mask virt services"
    echo "  (no arg) Show service and VM status"
    echo "  --help   Show this help message"
    ;;

*)
    if [ -n "$1" ]; then
        echo "❌ Unknown option: $1" >&2
        echo "⚠️ Usage: kvm {on|off|--help}" >&2
        exit 1
    fi
    echo "📊 Virtualization Service Status:"
    for svc in $DAEMONS; do
        systemctl status ${svc}.service 2>/dev/null | grep -E --color=always "loaded|active|inactive|enabled|disabled|masked"
    done
    echo ""
    echo "📊 Virtual Machines:"
    virsh list --all 2>/dev/null || echo "   (libvirt not available)"
    ;;
esac
