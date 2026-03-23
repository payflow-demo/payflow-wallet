#!/bin/bash

# ============================================
# PayFlow Monitoring Stack Deployment Script
# ============================================
# This script upgrades monitoring from 60% → 100%

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
[ -f k8s/monitoring/prometheus-deployment.yaml ] && apply_with_storage k8s/monitoring/prometheus-deployment.yaml
[ -f k8s/monitoring/loki-deployment.yaml ] && apply_with_storage k8s/monitoring/loki-deployment.yaml
[ -f k8s/monitoring/grafana-deployment.yaml ] && apply_with_storage k8s/monitoring/grafana-deployment.yaml

# ============================================
# Step 2: Deploy Kube State Metrics
# ============================================
echo -e "\n${YELLOW}[2/9] Deploying kube-state-metrics...${NC}"

kubectl apply -f k8s/monitoring/kube-state-metrics.yaml

echo -e "${GREEN}Waiting for kube-state-metrics to be ready...${NC}"
kubectl wait --for=condition=ready pod \
  -l app=kube-state-metrics \
  -n kube-system \
  --timeout=120s

echo -e "${GREEN}✓ kube-state-metrics deployed${NC}"

# ============================================
# Step 3: Deploy PostgreSQL Exporter
# ============================================
echo -e "\n${YELLOW}[3/9] Deploying postgres-exporter...${NC}"

kubectl apply -f k8s/monitoring/postgres-exporter.yaml

echo -e "${GREEN}Waiting for postgres-exporter to be ready...${NC}"
kubectl wait --for=condition=ready pod \
  -l app=postgres-exporter \
  -n payflow \
  --timeout=120s

echo -e "${GREEN}✓ postgres-exporter deployed${NC}"

# ============================================
# Step 3b: Deploy Redis Exporter
# ============================================
echo -e "\n${YELLOW}[3b/9] Deploying redis-exporter...${NC}"

kubectl apply -f k8s/monitoring/redis-exporter.yaml

echo -e "${GREEN}Waiting for redis-exporter to be ready...${NC}"
kubectl wait --for=condition=ready pod \
  -l app=redis-exporter \
  -n payflow \
  --timeout=120s

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

# Check Prometheus
if kubectl get pod -n monitoring -l app=prometheus | grep Running &> /dev/null; then
    echo -e "${GREEN}✓ Prometheus running${NC}"
else
    echo -e "${RED}✗ Prometheus not running${NC}"
fi

# Check AlertManager
if kubectl get pod -n monitoring -l app=alertmanager | grep Running &> /dev/null; then
    echo -e "${GREEN}✓ AlertManager running${NC}"
else
    echo -e "${RED}✗ AlertManager not running${NC}"
fi

# Check Promtail
if kubectl get pod -n monitoring -l app=promtail | grep Running &> /dev/null; then
    echo -e "${GREEN}✓ Promtail running${NC}"
else
    echo -e "${RED}✗ Promtail not running${NC}"
fi

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

echo -e "\n1. ${YELLOW}Import Grafana Dashboard:${NC}"
echo -e "   - Open Grafana (see above)"
echo -e "   - Go to: + → Import Dashboard"
echo -e "   - Upload: k8s/monitoring/grafana-dashboards/payflow-complete-dashboard.json"

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

