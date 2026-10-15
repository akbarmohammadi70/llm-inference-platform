#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ============================================================
# Configuration
# ============================================================
# VictoriaMetrics
MONITORING_NAMESPACE="monitoring"
VM_RELEASE="vmks"
VM_CHART="vm/victoria-metrics-k8s-stack"
VM_CHART_VERSION="0.96.0"
WORKER_NODE="worker2"
DATA_PATH="/data/victoria-metrics"
STORAGE_CLASS="local-worker2"
PV_NAME="victoria-metrics-local-pv"
# Optional: only used if the file exists on this machine.
VALUES_FILE="./vm-values.yaml"
GENERATED_VALUES="/tmp/vm-values-local-storage.yaml"

# KubeRay Operator
KUBERAY_NAMESPACE="kuberay-system"
KUBERAY_RELEASE="kuberay-operator"
KUBERAY_CHART_VERSION="1.7.1"

# Ray inference
RAY_NAMESPACE="ai-inference"

# ============================================================
# Pre-flight checks
# ============================================================
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v helm >/dev/null 2>&1 || die "helm not found (is helm_enabled true in Kubespray?)"
kubectl get nodes >/dev/null 2>&1 || die "kubectl cannot reach the cluster"

# ============================================================
# Namespaces
# ============================================================
echo "==> Creating namespaces"
for ns in "$MONITORING_NAMESPACE" "$KUBERAY_NAMESPACE" "$RAY_NAMESPACE"; do
  kubectl create namespace "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# ============================================================
# Helm repositories and chart version checks
# ============================================================
echo "==> Adding Helm repositories"
helm repo add vm https://victoriametrics.github.io/helm-charts/ \
  --force-update
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ \
  --force-update
helm repo update vm kuberay

helm search repo "$VM_CHART" --version "$VM_CHART_VERSION" | grep -q "$VM_CHART" ||
  die "Chart $VM_CHART version $VM_CHART_VERSION not found. Check: helm search repo $VM_CHART --versions | head"
helm search repo kuberay/kuberay-operator --version "$KUBERAY_CHART_VERSION" | grep -q "kuberay-operator" ||
  die "Chart kuberay/kuberay-operator version $KUBERAY_CHART_VERSION not found. Check: helm search repo kuberay/kuberay-operator --versions | head"

# ============================================================
# VictoriaMetrics local storage
# ============================================================
echo "==> Preparing VictoriaMetrics StorageClass and PV"
if ! kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
  cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
else
  echo "StorageClass $STORAGE_CLASS already exists; not modifying it."
fi

if ! kubectl get pv "$PV_NAME" >/dev/null 2>&1; then
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: 20Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${STORAGE_CLASS}
  local:
    path: ${DATA_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${WORKER_NODE}
EOF
else
  echo "PV $PV_NAME already exists; not modifying it."
fi

echo "==> Generating VictoriaMetrics Helm values"
# NOTE: Grafana is exposed as a NodePort. If the security group allows
# ingress from 0.0.0.0/0, it is reachable from the internet. Restrict the
# security group or set a strong admin password via VALUES_FILE.
cat > "$GENERATED_VALUES" <<EOF
vmsingle:
  enabled: true
  spec:
    retentionPeriod: "7d"
    replicaCount: 1
    nodeSelector:
      kubernetes.io/hostname: "${WORKER_NODE}"
    storage:
      storageClassName: "${STORAGE_CLASS}"
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 20Gi
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 1Gi
grafana:
  enabled: true
  service:
    type: NodePort
    port: 80
    targetPort: 3000
    nodePort: 30300
EOF

echo "==> Installing/upgrading VictoriaMetrics Stack"
VM_HELM_ARGS=(
  upgrade --install "$VM_RELEASE" "$VM_CHART"
  --version "$VM_CHART_VERSION"
  --namespace "$MONITORING_NAMESPACE"
  --create-namespace
  --values "$GENERATED_VALUES"
  --wait
  --timeout 10m
)

# Existing user values override generated defaults.
if [[ -f "$VALUES_FILE" ]]; then
  VM_HELM_ARGS+=(--values "$VALUES_FILE")
fi

helm "${VM_HELM_ARGS[@]}"
echo "==> VictoriaMetrics status"
kubectl get storageclass "$STORAGE_CLASS"
kubectl get pv "$PV_NAME"
kubectl get pvc -n "$MONITORING_NAMESPACE"
kubectl get pods -n "$MONITORING_NAMESPACE" -o wide

# ============================================================
# KubeRay Operator in its own namespace
# ============================================================
echo "==> Installing KubeRay Operator in $KUBERAY_NAMESPACE"
helm upgrade --install "$KUBERAY_RELEASE" \
  kuberay/kuberay-operator \
  --version "$KUBERAY_CHART_VERSION" \
  --namespace "$KUBERAY_NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 5m

kubectl wait \
  --for=condition=Established \
  --timeout=120s \
  crd/rayservices.ray.io

# ============================================================
# Verification
# ============================================================
echo "==> Final status"
kubectl get pods -n "$RAY_NAMESPACE" -o wide
kubectl get svc -n "$RAY_NAMESPACE"

echo
echo "============================================================"
echo "Deployment commands"
echo "============================================================"
echo "Ray namespace: $RAY_NAMESPACE"
echo "Operator namespace: $KUBERAY_NAMESPACE"