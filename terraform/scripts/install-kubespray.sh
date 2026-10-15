#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================
# Install Kubernetes with Kubespray
# ============================================================
log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
die() {
  log "ERROR: $*"
  exit 1
}
# ------------------------------------------------------------
# Validate environment
# ------------------------------------------------------------
required_vars=(
  PROJECT_DIR
  KUBESPRAY_VERSION
  KUBESPRAY_WORKDIR
  SSH_USER
  SSH_PRIVATE_KEY_PATH
  MASTER_PUBLIC_IP
  WORKER1_PUBLIC_IP
  WORKER2_PUBLIC_IP
  PRIVATE_NET_PREFIX
)
for name in "${required_vars[@]}"; do
  [[ -n "${!name:-}" ]] || die "Required environment variable is missing: $name"
done

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v python3.12 >/dev/null 2>&1 || die "python3.12 is not installed"

# ------------------------------------------------------------
# Normalize paths (make everything absolute)
# ------------------------------------------------------------
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
KUBESPRAY_WORKDIR="${KUBESPRAY_WORKDIR/#\~/$HOME}"
SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH/#\~/$HOME}"

mkdir -p "$(dirname "$KUBESPRAY_WORKDIR")"
KUBESPRAY_WORKDIR="$(cd "$(dirname "$KUBESPRAY_WORKDIR")" && pwd)/$(basename "$KUBESPRAY_WORKDIR")"

[[ -f "$SSH_PRIVATE_KEY_PATH" ]] ||
  die "SSH private key not found: $SSH_PRIVATE_KEY_PATH"
chmod 600 "$SSH_PRIVATE_KEY_PATH"

INVENTORY_FILE="$KUBESPRAY_WORKDIR/inventory/local/hosts.ini"
VENV_DIR="$KUBESPRAY_WORKDIR/.venv"

SSH_OPTS=(
  -i "$SSH_PRIVATE_KEY_PATH"
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=5
)

sed_inplace() {
  # BSD sed (macOS) and GNU sed (Linux) differ in the -i syntax.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

log "Kubespray version: $KUBESPRAY_VERSION"
log "Project directory: $PROJECT_DIR"
log "Kubespray directory: $KUBESPRAY_WORKDIR"

# ------------------------------------------------------------
# Wait for SSH
# ------------------------------------------------------------
wait_for_ssh() {
  local host="$1"
  local attempt
  for attempt in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" true; then
      log "SSH is ready: $host"
      return 0
    fi
    log "Waiting for SSH on $host (attempt $attempt/30)"
    sleep 10
  done
  die "SSH connection failed after retries: $host"
}
wait_for_ssh "$MASTER_PUBLIC_IP"
wait_for_ssh "$WORKER1_PUBLIC_IP"
wait_for_ssh "$WORKER2_PUBLIC_IP"

# ------------------------------------------------------------
# Detect private IPs from the nodes (DHCP-assigned)
# ------------------------------------------------------------
get_private_ip() {
  # "|| true" so that a non-matching grep does not kill the script
  # silently; the empty result is reported by the check below.
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" \
    "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | grep -F '${PRIVATE_NET_PREFIX}' | head -n1" || true
}

MASTER_PRIVATE_IP="$(get_private_ip "$MASTER_PUBLIC_IP")"
WORKER1_PRIVATE_IP="$(get_private_ip "$WORKER1_PUBLIC_IP")"
WORKER2_PRIVATE_IP="$(get_private_ip "$WORKER2_PUBLIC_IP")"

for v in MASTER_PRIVATE_IP WORKER1_PRIVATE_IP WORKER2_PRIVATE_IP; do
  [[ -n "${!v}" ]] ||
    die "Could not detect $v (prefix ${PRIVATE_NET_PREFIX}). The private NIC probably has no IP inside the OS; check 'ip -br a' on the node."
done

log "Private IPs: master=$MASTER_PRIVATE_IP worker1=$WORKER1_PRIVATE_IP worker2=$WORKER2_PRIVATE_IP"

# ------------------------------------------------------------
# Clone the exact Kubespray release tag
# ------------------------------------------------------------
if [[ ! -d "$KUBESPRAY_WORKDIR/.git" ]]; then
  log "Cloning Kubespray $KUBESPRAY_VERSION"
  git clone \
    --depth 1 \
    --branch "$KUBESPRAY_VERSION" \
    https://github.com/kubernetes-sigs/kubespray.git \
    "$KUBESPRAY_WORKDIR"
else
  log "Checking out Kubespray $KUBESPRAY_VERSION"
  git -C "$KUBESPRAY_WORKDIR" fetch --tags --force origin
  git -C "$KUBESPRAY_WORKDIR" checkout --detach "$KUBESPRAY_VERSION"
fi

ACTUAL_VERSION="$(
  git -C "$KUBESPRAY_WORKDIR" describe --tags --exact-match HEAD
)" || die "Checked-out Kubespray commit does not match an exact tag"

[[ "$ACTUAL_VERSION" == "$KUBESPRAY_VERSION" ]] ||
  die "Expected $KUBESPRAY_VERSION but checked out $ACTUAL_VERSION"

# ------------------------------------------------------------
# Create Python virtual environment and install dependencies
# ------------------------------------------------------------
log "Preparing Python virtual environment"
python3.12 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python3.12 -m pip install --upgrade pip
python3.12 -m pip install -r "$KUBESPRAY_WORKDIR/requirements.txt"

cd "$KUBESPRAY_WORKDIR"
export ANSIBLE_CONFIG="$KUBESPRAY_WORKDIR/ansible.cfg"

# ------------------------------------------------------------
# Create inventory
# ansible_host: public IP (reachable from this machine)
# ip / access_ip: private IP (used by etcd, kubelet and the cluster)
# ------------------------------------------------------------
cat > "$INVENTORY_FILE" <<EOF
[all]
master ansible_host=${MASTER_PUBLIC_IP} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_PRIVATE_KEY_PATH} ip=${MASTER_PRIVATE_IP} access_ip=${MASTER_PRIVATE_IP}
worker1 ansible_host=${WORKER1_PUBLIC_IP} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_PRIVATE_KEY_PATH} ip=${WORKER1_PRIVATE_IP} access_ip=${WORKER1_PRIVATE_IP}
worker2 ansible_host=${WORKER2_PUBLIC_IP} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_PRIVATE_KEY_PATH} ip=${WORKER2_PRIVATE_IP} access_ip=${WORKER2_PRIVATE_IP}

[kube_control_plane]
master

[etcd]
master

[kube_node]
worker1
worker2

[k8s_cluster:children]
kube_control_plane
kube_node
EOF
log "Inventory created at $INVENTORY_FILE"

# ------------------------------------------------------------
# Validate Ansible connectivity
# ------------------------------------------------------------
log "Testing Ansible connectivity"
ansible -i "$INVENTORY_FILE" all -m ping

# ------------------------------------------------------------
# Enable Helm and Metrics Server
# ------------------------------------------------------------
INVENTORY_GROUP_VARS="$KUBESPRAY_WORKDIR/inventory/local/group_vars/k8s_cluster/addons.yml"
[[ -f "$INVENTORY_GROUP_VARS" ]] ||
  die "addons.yml not found: $INVENTORY_GROUP_VARS"

sed_inplace \
  -e 's/^helm_enabled: false$/helm_enabled: true/' \
  -e 's/^metrics_server_enabled: false$/metrics_server_enabled: true/' \
  "$INVENTORY_GROUP_VARS"
log "Enabled Helm and Metrics Server in Kubespray configuration"


# ------------------------------------------------------------
# Bind kube-apiserver to the private IP only
# (NodePorts stay on all interfaces; Calico stays at its defaults)
# ------------------------------------------------------------
# K8S_CLUSTER_VARS="$KUBESPRAY_WORKDIR/inventory/local/group_vars/k8s_cluster/k8s-cluster.yml"
# [[ -f "$K8S_CLUSTER_VARS" ]] ||
#   die "k8s-cluster.yml not found: $K8S_CLUSTER_VARS"
 
# if grep -Eq '^#?[[:space:]]*kube_apiserver_bind_address:' "$K8S_CLUSTER_VARS"; then
#   sed_inplace -E 's|^#?[[:space:]]*kube_apiserver_bind_address:.*|kube_apiserver_bind_address: "{{ ip }}"|' "$K8S_CLUSTER_VARS"
# else
#   # '$a\' + text in a second -e works on both BSD (macOS) and GNU sed
#   sed_inplace -e '$a\' -e 'kube_apiserver_bind_address: "{{ ip }}"' "$K8S_CLUSTER_VARS"
# fi
# log "kube-apiserver will listen on each node's private IP only"
 
# Configure kube-apiserver bind address

# Configure kube-apiserver bind address
K8S_CLUSTER_VARS="$KUBESPRAY_WORKDIR/inventory/local/group_vars/k8s_cluster/k8s-cluster.yml"
[[ -f "$K8S_CLUSTER_VARS" ]] || die "k8s-cluster.yml not found: $K8S_CLUSTER_VARS"

SETTING='kube_apiserver_bind_address: "{{ main_ip }}"'
TMP="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$TMP"' EXIT

# Remove every existing (commented or not) occurrence, then append once.
{
  grep -Ev '^[[:space:]]*#?[[:space:]]*kube_apiserver_bind_address[[:space:]]*:' "$K8S_CLUSTER_VARS" || true
  printf '%s\n' "$SETTING"
} > "$TMP" || die "Failed to build new k8s-cluster.yml"

cat "$TMP" > "$K8S_CLUSTER_VARS" || die "Failed to write k8s-cluster.yml"

log "kube-apiserver will listen on each node's private IP only"

# ------------------------------------------------------------
# Configure HTTP(S) proxy in group_vars/all/all.yml
# (Kubespray adds node IPs, service/pod CIDRs and cluster domains
#  to no_proxy automatically)
# ------------------------------------------------------------
# PROXY_URL="${PROXY_URL:-http://37.152.179.85:8080}"
# ALL_YML="$KUBESPRAY_WORKDIR/inventory/local/group_vars/all/all.yml"
# [[ -f "$ALL_YML" ]] || die "all.yml not found: $ALL_YML"

# set_yaml_var() {
#   local file="$1" key="$2" value="$3"
#   local line="${key}: \"${value}\""

#   if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*:" "$file"; then
#     # Replace the existing setting, whether commented or uncommented.
#     sed_inplace -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*:.*\$|${line}|" "$file"
#   else
#     printf '\n%s\n' "$line" >> "$file"
#   fi

#   grep -Fxq "$line" "$file" || die "Failed to set $key in $file"
# }

# set_yaml_var "$ALL_YML" "http_proxy" "$PROXY_URL"
# set_yaml_var "$ALL_YML" "https_proxy" "$PROXY_URL"

# log "Proxy configured in all.yml: $PROXY_URL"
# ------------------------------------------------------------
# Install Kubernetes
# ------------------------------------------------------------
log "Starting Kubespray cluster installation"
ansible-playbook \
  -i "$INVENTORY_FILE" \
  -b \
  -u "$SSH_USER" \
  cluster.yml

log "Kubespray installation completed successfully"
log "Inventory: $INVENTORY_FILE"
log "Kubespray version: $ACTUAL_VERSION"