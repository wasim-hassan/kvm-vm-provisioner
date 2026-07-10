#!/usr/bin/env python3
"""Generate cloud-init user-data and meta-data for cloud VMs (Ubuntu/AlmaLinux)."""
import os
import sys
import argparse

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ci-dir', required=True)
    parser.add_argument('--ssh-key', required=True)
    parser.add_argument('--vm-name', required=True)
    parser.add_argument('--vm-user', default='ubuntu')
    parser.add_argument('--vm-hostname', default='cloud-vm')
    parser.add_argument('--distro', default='ubuntu', choices=['ubuntu', 'almalinux'])
    args = parser.parse_args()

    # meta-data
    with open(os.path.join(args.ci_dir, 'meta-data'), 'w') as f:
        f.write(f"""instance-id: {args.vm_name}-{int(os.getpid())}
local-hostname: {args.vm_hostname}
""")

    # user-data — distro-aware package manager and ssh service
    if args.distro == 'almalinux':
        pkg_mgr_cmd = 'dnf install -y qemu-guest-agent'
        ssh_service = 'sshd'
    else:
        pkg_mgr_cmd = 'timeout 30 apt-get update -qq 2>/dev/null && timeout 30 apt-get install -y -qq qemu-guest-agent 2>/dev/null || true'
        ssh_service = 'ssh'

    content = f"""#cloud-config
hostname: {args.vm_hostname}
manage_etc_hosts: true
users:
  - name: {args.vm_user}
    ssh_authorized_keys:
      - __SSH_KEY_PLACEHOLDER__
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: true
ssh_pwauth: false
runcmd:
  - {pkg_mgr_cmd}
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, {ssh_service} ]
  - [ systemctl, enable, --now, qemu-guest-agent ]
"""
    content = content.replace('__SSH_KEY_PLACEHOLDER__', args.ssh_key)

    with open(os.path.join(args.ci_dir, 'user-data'), 'w') as f:
        f.write(content)

if __name__ == '__main__':
    main()
