#!/usr/bin/env bash
# Fresh-install kernel + sysctl prerequisites for kubeadm + containerd.
# Run on BOTH control-plane (kubes) and worker (deploy) BEFORE kubeadm init/join.
# DO NOT run on an already-running cluster — it is for a rebuild only.
#
# What it does:
#   - disables swap (kubelet dislikes swap in general use)
#   - loads the bridge + overlay kernel modules Calico expects
#   - enables IPv4 forwarding and iptables on bridged traffic
set -euo pipefail

if ! command -v sudo >/dev/null; then
  echo "This script needs sudo." >&2
  exit 1
fi

sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

sudo modprobe overlay
sudo modprobe br_netfilter
cat <<'EOF' | sudo tee /etc/modules-load.d/kubernetes.conf >/dev/null
overlay
br_netfilter
EOF

cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf >/dev/null
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sudo sysctl --system

echo
echo "Prereqs applied. Now install containerd + kubelet/kubeadm/kubectl from the"
echo "upstream Kubernetes apt repo for the version you intend to run."
