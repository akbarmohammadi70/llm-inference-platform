#!/usr/bin/env bash
set -Eeuo pipefail

# Kernel tuning for Kubernetes nodes
# Target: Ubuntu 24.04, containerd, Kubespray
# Must run as root.

echo "[1/4] Applying kernel modules..."
cat >/etc/modules-load.d/kubernetes.conf <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF

modprobe overlay
modprobe br_netfilter
modprobe nf_conntrack

echo "[2/4] Applying sysctl settings..."

cat >/etc/sysctl.d/99-kubernetes-tuning.conf <<'EOF'
# Kubernetes networking
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
# Conntrack
net.netfilter.nf_conntrack_max = 262144
# TCP reliability and connection handling
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
# Ephemeral ports for outbound connections
net.ipv4.ip_local_port_range = 10240 65535
# Avoid excessive swapping; Kubernetes should manage node memory pressure.
vm.swappiness = 1
# File handles
fs.file-max = 2097152
EOF

sysctl --system

echo "[3/4] Setting file descriptor limits..."

cat >/etc/security/limits.d/99-kubernetes.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

echo "[4/4] Verifying settings..."
sysctl \
  net.ipv4.ip_forward \
  net.bridge.bridge-nf-call-iptables \
  net.bridge.bridge-nf-call-ip6tables \
  net.netfilter.nf_conntrack_max \
  net.core.somaxconn \
  net.ipv4.ip_local_port_range \
  vm.swappiness \
  fs.file-max

echo
echo "Kernel tuning completed successfully."
echo "Modules and sysctl settings are persisted in /etc/modules-load.d and /etc/sysctl.d."
echo "A reboot is not required for them to take effect; a later reboot keeps them."