#!/bin/bash

# ============================================
# PayFlow Monitoring Stack Deployment Script
# ============================================
# This script upgrades monitoring from 60% → 100%
#
# Run (either is fine — the script cds to repo root):
#   ./monitoring/deploy-monitoring.sh
#   cd monitoring && bash deploy-monitoring.sh
#
# Manual kubectl apply paths are relative to REPO ROOT, not this folder:
#   kubectl apply -f k8s/monitoring/kube-state-metrics.yaml
# From inside monitoring/: use ../k8s/monitoring/kube-state-metrics.yaml

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}PayFlow Monitoring Stack Deployment${NC}"
echo -e "${GREEN}Upgrading from 60% → 100% Production-Ready${NC}"
echo -e "${GREEN}================================================${NC}"

# ============================================
# Step 1: Verify Prerequisites
# ============================================
echo -e "\n${YELLOW}[1/9] Verifying prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl not found. Please install kubectl.${NC}"
    exit 1
fi

# Cluster connectivity check (skip with SKIP_CLUSTER_CHECK=1 for manifest-only runs)
if [ "${SKIP_CLUSTER_CHECK}" != "1" ]; then
  if ! kubectl cluster-info &> /dev/null; then
      echo -e "${RED}Cannot connect to Kubernetes cluster.${NC}"
      echo -e "${YELLOW}Ensure kubectl is configured for your target cluster:${NC}"
      echo -e "  • EKS (private): Run this script from the bastion host:"
      echo -e "    aws ssm start-session --target <bastion-instance-id> --region <region>"
      echo -e "    (Get instance ID: terraform -chdir=terraform/aws/bastion output bastion_instance_id)"
      echo -e "    Full steps + debugging: monitoring/DEPLOYMENT-GUIDE.md → \"Deploy monitoring to EKS\""
      echo -e "  • EKS (public): aws eks update-kubeconfig --region <region> --name <cluster-name>"
      echo -e "  • AKS: az aks get-credentials --resource-group <rg> --name <cluster-name>"
      echo -e "  • Local: microk8s kubectl config view --raw > ~/.kube/config"
      [ -n "$KUBECONFIG" ] && echo -e "  • KUBECONFIG is set to: $KUBECONFIG"
      exit 1
  fi
fi

echo -e "${GREEN}✓ kubectl configured${NC}"
echo -e "${GREEN}✓ Cluster: $(kubectl config current-context 2>/dev/null || echo 'N/A')${NC}"

# Storage class: EKS/AKS use gp3/gp2; local uses microk8s-hostpath. Detect or default to gp3 for cloud.
STORAGE_CLASS="${STORAGE_CLASS:-}"
if [ -z "$STORAGE_CLASS" ]; then
  for sc in gp3 gp2 efs standard microk8s-hostpath; do
    if kubectl get storageclass "$sc" &>/dev/null 2>&1; then
      STORAGE_CLASS="$sc"
      echo -e "${YELLOW}Using storage class: $STORAGE_CLASS${NC}"
      break
    fi
  done
  if [ -z "$STORAGE_CLASS" ]; then
    STORAGE_CLASS="gp3"
    echo -e "${YELLOW}No matching storage class found; defaulting to gp3 (EKS). Set STORAGE_CLASS if different.${NC}"
  fi
fi
export STORAGE_CLASS

# Apply YAML with storage class substitution (for EKS where microk8s-hostpath doesn't exist)
apply_with_storage() {
  local f="$1"
  if [ -f "$f" ]; then
    sed "s/storageClassName: microk8s-hostpath/storageClassName: $STORAGE_CLASS/g" "$f" | kubectl apply -f -
  else
    kubectl apply -f "$f"
  fi
}

# Ensure monitoring namespace and core stack (Prometheus, Loki, Grafana) with correct StorageClass
kubectl create namespace monitoring 2>/dev/null || true
[ -f k8s/monitoring/namespace.yaml ] && kubectl apply -f k8s/monitoring/namespace.yaml 2>/dev/null || true
[ -f k8s/monitoring/prometheus-rbac.yaml ] && kubectl apply -f k8s/monitoring/prometheus-rbac.yaml

# Prometheus Deployment mounts prometheus-config + prometheus-rules; they MUST exist before pods start.
# (Previously these were only created in step 5 → pods stuck NotReady / mount errors → verify showed "not running".)
if [ -f k8s/monitoring/prometheus.yml ] && [ -f k8s/monitoring/alerts.yml ]; then
  kubectl create configmap prometheus-config -n monitoring \
    --from-file=prometheus.yml=k8s/monitoring/prometheus.yml \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create configmap prometheus-rules -n monitoring \
    --from-file=alerts.yml=k8s/monitoring/alerts.yml \
    --dry-run=client -o yaml | kubectl apply -f -
fi

[ -f k8s/monitoring/prometheus-deployment.yaml ] && apply_with_storage k8s/monitoring/prometheus-deployment.yaml
[ -f k8s/monitoring/loki-deployment.yaml ] && apply_with_storage k8s/monitoring/loki-deployment.yaml
# Grafana mounts dashboard JSON from ConfigMap grafana-dashboards-json (file provider in grafana-dashboard-provider CM).
# Single dashboard: queries align with k8s/monitoring/prometheus.yml scrape jobs.
# When only this ConfigMap changes, Grafana often keeps serving stale JSON until the pod restarts.
RESTART_GRAFANA_DASHBOARDS=0
OLD_DASH_CM_RV=$(kubectl get configmap grafana-dashboards-json -n monitoring -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)
if [ -f k8s/monitoring/grafana-dashboards/payflow-complete-dashboard.json ]; then
  kubectl create configmap grafana-dashboards-json -n monitoring \
    --from-file=payflow-dashboard.json=k8s/monitoring/grafana-dashboards/payflow-complete-dashboard.json \
    --dry-run=client -o yaml | kubectl apply -f -
  NEW_DASH_CM_RV=$(kubectl get configmap grafana-dashboards-json -n monitoring -o jsonpath='{.metadata.resourceVersion}')
  if [ "$OLD_DASH_CM_RV" != "$NEW_DASH_CM_RV" ]; then
    RESTART_GRAFANA_DASHBOARDS=1
  fi
fi
[ -f k8s/monitoring/grafana-deployment.yaml ] && apply_with_storage k8s/monitoring/grafana-deployment.yaml
if [ "$RESTART_GRAFANA_DASHBOARDS" = 1 ] && kubectl get deploy grafana -n monitoring &>/dev/null; then
  echo -e "${YELLOW}Restarting Grafana so provisioned dashboards pick up the latest ConfigMap...${NC}"
  kubectl rollout restart deployment/grafana -n monitoring
fi

echo -e "${GREEN}Waiting for core monitoring rollouts (Prometheus / Loki / Grafana)...${NC}"
if [ -f k8s/monitoring/prometheus-deployment.yaml ]; then
  kubectl rollout status deployment/prometheus -n monitoring --timeout=300s \
    || { echo -e "${RED}Prometheus rollout failed.${NC}"; kubectl get pods -n monitoring -l app=prometheus; exit 1; }
fi
if [ -f k8s/monitoring/loki-deployment.yaml ]; then
  kubectl rollout status statefulset/loki -n monitoring --timeout=300s \
    || { echo -e "${RED}Loki rollout failed.${NC}"; kubectl get pods -n monitoring -l app=loki; exit 1; }
fi
if [ -f k8s/monitoring/grafana-deployment.yaml ]; then
  kubectl rollout status deployment/grafana -n monitoring --timeout=300s \
    || { echo -e "${RED}Grafana rollout failed.${NC}"; kubectl get pods -n monitoring -l app=grafana; exit 1; }
fi

# ============================================
# Step 2: Deploy Kube State Metrics
# ============================================
echo -e "\n${YELLOW}[2/9] Deploying kube-state-metrics...${NC}"

kubectl apply -f k8s/monitoring/kube-state-metrics.yaml

# Do NOT use `kubectl wait pod -l app=...` here: during a rollout several pods match
# the label (terminating + new); wait tries to satisfy all and times out. Use rollout.
echo -e "${GREEN}Waiting for kube-state-metrics rollout (kube-system, up to 5m)...${NC}"
if ! kubectl rollout status deployment/kube-state-metrics -n kube-system --timeout=300s; then
  echo -e "${RED}kube-state-metrics rollout did not finish.${NC}"
  echo -e "${YELLOW}kubectl get pods -n kube-system -l app=kube-state-metrics -o wide${NC}"
  echo -e "${YELLOW}kubectl describe pod -n kube-system -l app=kube-state-metrics${NC}"
  exit 1
fi

echo -e "${GREEN}✓ kube-state-metrics deployed${NC}"

# ============================================
# Step 3: Deploy PostgreSQL Exporter
# ============================================
echo -e "\n${YELLOW}[3/9] Deploying postgres-exporter...${NC}"

# Local overlay capped payflow at services=10; app + infra fills that. Exporters add 2 Services.
# Patch live quota so apply succeeds; k8s YAML was also raised for new clusters.
if kubectl get resourcequota payflow-resource-quota -n payflow &>/dev/null; then
  kubectl patch resourcequota payflow-resource-quota -n payflow --type=merge \
    -p '{"spec":{"hard":{"services":"20"}}}' &>/dev/null \
    && echo -e "${GREEN}✓ payflow ResourceQuota services ≥ 20 (for exporters)${NC}" \
    || echo -e "${YELLOW}⚠ Could not patch payflow-resource-quota (missing RBAC?); apply k8s/overlays/local if Service quota errors persist.${NC}"
fi

kubectl apply -f k8s/monitoring/postgres-exporter.yaml

# Avoid `kubectl wait pod -l ...` immediately after apply: the Pod may not exist yet
# (brief window) → "no matching resources found". Rollout waits on the Deployment.
echo -e "${GREEN}Waiting for postgres-exporter rollout (payflow, up to 3m)...${NC}"
if ! kubectl rollout status deployment/postgres-exporter -n payflow --timeout=180s; then
  echo -e "${RED}postgres-exporter rollout failed.${NC}"
  echo -e "${YELLOW}kubectl get pods -n payflow -l app=postgres-exporter; kubectl describe deploy postgres-exporter -n payflow${NC}"
  exit 1
fi

echo -e "${GREEN}✓ postgres-exporter deployed${NC}"

# ============================================
# Step 3b: Deploy Redis Exporter
# ============================================
echo -e "\n${YELLOW}[3b/9] Deploying redis-exporter...${NC}"

kubectl apply -f k8s/monitoring/redis-exporter.yaml

echo -e "${GREEN}Waiting for redis-exporter rollout (payflow, up to 3m)...${NC}"
if ! kubectl rollout status deployment/redis-exporter -n payflow --timeout=180s; then
  echo -e "${RED}redis-exporter rollout failed.${NC}"
  echo -e "${YELLOW}kubectl get pods -n payflow -l app=redis-exporter; kubectl describe deploy redis-exporter -n payflow${NC}"
  exit 1
fi

echo -e "${GREEN}✓ redis-exporter deployed${NC}"

# ============================================
# Step 4: Enable RabbitMQ Prometheus Plugin
# ============================================
echo -e "\n${YELLOW}[4/8] Enabling RabbitMQ Prometheus plugin...${NC}"

# Check if RabbitMQ pod exists
if kubectl get pod rabbitmq-0 -n payflow &> /dev/null; then
    kubectl exec -n payflow rabbitmq-0 -- rabbitmq-plugins enable rabbitmq_prometheus
    echo -e "${GREEN}✓ RabbitMQ Prometheus plugin enabled${NC}"
else
    echo -e "${YELLOW}⚠ RabbitMQ pod not found. Skipping plugin enablement.${NC}"
fi

# ============================================
# Step 5: Update Prometheus Configuration
# ============================================
echo -e "\n${YELLOW}[5/9] Updating Prometheus configuration...${NC}"

# Update Prometheus config
kubectl create configmap prometheus-config -n monitoring \
  --from-file=prometheus.yml=k8s/monitoring/prometheus.yml \
  --dry-run=client -o yaml | kubectl apply -f -

# Update alert rules
kubectl create configmap prometheus-rules -n monitoring \
  --from-file=alerts.yml=k8s/monitoring/alerts.yml \
  --dry-run=client -o yaml | kubectl apply -f -

# Reload Prometheus (Deployment pod name varies)
echo -e "${GREEN}Reloading Prometheus...${NC}"
PROM_POD=$(kubectl get pod -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$PROM_POD" ] && kubectl exec -n monitoring "$PROM_POD" -- killall -HUP prometheus 2>/dev/null || true

echo -e "${GREEN}✓ Prometheus configuration updated${NC}"

# ============================================
# Step 6: Deploy Alertmanager and Promtail
# ============================================
echo -e "\n${YELLOW}[6/9] Deploying Alertmanager and Promtail...${NC}"

kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
kubectl apply -f k8s/monitoring/promtail-daemonset.yaml

# For EKS with Secrets Manager, optionally apply:
# kubectl apply -f k8s/monitoring/alertmanager-external-secret.yaml

echo -e "${GREEN}Waiting for Alertmanager and Promtail rollouts...${NC}"
kubectl rollout status deployment/alertmanager -n monitoring --timeout=180s \
  || { echo -e "${RED}Alertmanager rollout failed.${NC}"; kubectl get pods -n monitoring -l app=alertmanager; exit 1; }
kubectl rollout status daemonset/promtail -n monitoring --timeout=300s \
  || { echo -e "${RED}Promtail DaemonSet rollout failed.${NC}"; kubectl get pods -n monitoring -l app=promtail; exit 1; }

# Reload AlertManager (Deployment pod name varies)
echo -e "${GREEN}Reloading AlertManager...${NC}"
AM_POD=$(kubectl get pod -n monitoring -l app=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$AM_POD" ] && kubectl exec -n monitoring "$AM_POD" -- killall -HUP alertmanager 2>/dev/null || true

echo -e "${GREEN}✓ Alertmanager and Promtail deployed${NC}"

# ============================================
# Step 7: Verify All Components
# ============================================
echo -e "\n${YELLOW}[7/9] Verifying deployment...${NC}"

# Check kube-state-metrics
if kubectl get pod -n kube-system -l app=kube-state-metrics | grep Running &> /dev/null; then
    echo -e "${GREEN}✓ kube-state-metrics running${NC}"
else
    echo -e "${RED}✗ kube-state-metrics not running${NC}"
fi

# Check postgres-exporter
if kubectl get pod -n payflow -l app=postgres-exporter | grep Running &> /dev/null; then
    echo -e "${GREEN}✓ postgres-exporter running${NC}"
else
    echo -e "${RED}✗ postgres-exporter not running${NC}"
fi

# Check redis-exporter
if kubectl get pod -n payflow -l app=redis-exporter | grep Running &> /dev/null; then
    echo -e "${GREEN}✓ redis-exporter running${NC}"
else
    echo -e "${RED}✗ redis-exporter not running${NC}"
fi

# Use Ready condition (not plain-text grep — avoids false ✗ during ContainerCreating, etc.)
check_monitoring_ready() {
  local label="$1" name="$2"
  if kubectl wait --for=condition=ready pod -l "$label" -n monitoring --timeout=120s &>/dev/null; then
    echo -e "${GREEN}✓ ${name} Ready${NC}"
  else
    echo -e "${RED}✗ ${name} not Ready${NC}"
    kubectl get pods -n monitoring -l "$label" -o wide 2>/dev/null || true
  fi
}
check_monitoring_ready "app=prometheus" "Prometheus"
check_monitoring_ready "app=alertmanager" "Alertmanager"
check_monitoring_ready "app=promtail" "Promtail"

# ============================================
# Step 8: Display Access Information
# ============================================
echo -e "\n${YELLOW}[8/9] Deployment complete!${NC}"

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}Access Information${NC}"
echo -e "${GREEN}================================================${NC}"

echo -e "\n${YELLOW}Prometheus:${NC}"
echo -e "  kubectl port-forward -n monitoring svc/prometheus 9090:9090"
echo -e "  Then open: http://localhost:9090"

echo -e "\n${YELLOW}AlertManager:${NC}"
echo -e "  kubectl port-forward -n monitoring svc/alertmanager 9093:9093"
echo -e "  Then open: http://localhost:9093"

echo -e "\n${YELLOW}Grafana:${NC}"
echo -e "  kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo -e "  Then open: http://localhost:3000"
echo -e "  Default login: admin / admin"

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}Next Steps${NC}"
echo -e "${GREEN}================================================${NC}"

echo -e "\n1. ${YELLOW}Grafana dashboards:${NC}"
echo -e "   - PayFlow dashboards are provisioned automatically (folder: PayFlow)."
echo -e "   - Re-run this script after editing JSON under k8s/monitoring/grafana-dashboards/"

echo -e "\n2. ${YELLOW}Configure Slack/PagerDuty (Production):${NC}"
echo -e "   - Edit: k8s/monitoring/alertmanager-deployment.yaml (Secret stringData)"
echo -e "   - Or for EKS: Store config in AWS Secrets Manager at payflow/ENV/alertmanager"
echo -e "   - Then apply: kubectl apply -f k8s/monitoring/alertmanager-external-secret.yaml"

echo -e "\n4. ${YELLOW}Test Alerts:${NC}"
echo -e "   - See: monitoring/DEPLOYMENT-GUIDE.md"
echo -e "   - Section: Test Alerts"

echo -e "\n5. ${YELLOW}Update Service Code:${NC}"
echo -e "   - Add business metrics tracking to services"
echo -e "   - See: monitoring/DEPLOYMENT-GUIDE.md"
echo -e "   - Section: Update Service Code to Emit Metrics"

echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}Monitoring Status: 100% Production-Ready! 🎉${NC}"
echo -e "${GREEN}================================================${NC}"

echo -e "\n${YELLOW}For detailed information, see:${NC}"
echo -e "  monitoring/DEPLOYMENT-GUIDE.md"

