# PayFlow Monitoring Stack

> **Purpose**: Deploy Prometheus and Grafana to monitor PayFlow services

---

## Overview

This monitoring stack includes:
- **Prometheus**: Metrics collection and storage
- **Grafana**: Metrics visualization (to be added)
- **AlertManager**: Alert routing (to be added)

---

## Files Structure

```
k8s/monitoring/
├── namespace.yaml              # Monitoring namespace
├── prometheus-config.yaml      # Prometheus scrape configuration
├── prometheus-rules.yaml       # Alert rules
└── prometheus-deployment.yaml  # Prometheus deployment, service, PVC
```

---

## Deployment

### Step 1: Create Namespace and Resources

```bash
# Deploy everything
kubectl apply -f k8s/monitoring/

# Verify namespace created
kubectl get namespace monitoring

# Verify Prometheus is running
kubectl get pods -n monitoring
```

### Step 2: Verify Prometheus

```bash
# Check Prometheus pod status
kubectl get pods -n monitoring -l app=prometheus

# Check Prometheus logs
kubectl logs -n monitoring -l app=prometheus --tail=50

# Check if Prometheus is scraping targets
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Then open: http://localhost:9090
# Go to: Status → Targets (should see all services)
```

### Step 3: Access Prometheus (Temporary - Port Forward)

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Access Prometheus UI
# Open browser: http://localhost:9090
```

**Note**: We'll configure ingress for URL access later (as you mentioned).

---

## Configuration

### Prometheus Scrape Configuration

Prometheus automatically discovers pods using Kubernetes service discovery:

- **Auto-discovery**: Finds pods in `payflow` namespace
- **Filtering**: Only scrapes pods with matching labels
- **Ports**: Uses service-specific ports (3000, 3001, 3002, etc.)

**Services Scraped:**
- API Gateway (port 3000)
- Auth Service (port 3004)
- Wallet Service (port 3001)
- Transaction Service (port 3002)
- Notification Service (port 3003)
- PostgreSQL (port 5432) - *requires exporter*
- Redis (port 6379) - *requires exporter*
- RabbitMQ (port 15672)

### Alert Rules

Alert rules are defined in `prometheus-rules.yaml`:

- **ServiceDown**: Service unavailable for 1 minute
- **HighErrorRate**: Error rate > 10% for 2 minutes
- **HighResponseTime**: 95th percentile > 1 second for 3 minutes
- **HighMemoryUsage**: Memory > 500MB for 5 minutes
- **HighCPUUsage**: CPU > 80% for 5 minutes
- **DatabaseDown**: PostgreSQL unavailable
- **HighTransactionFailureRate**: Failure rate > 5%

---

## Storage

### Persistent Volume

- **Size**: 50GB
- **Retention**: 30 days
- **Storage Class**: `microk8s-hostpath` (MicroK8s)
  - **For Production**: Change to `managed-premium` (AKS) or `gp3` (EKS)

### Changing Storage Class

Edit `prometheus-deployment.yaml`:
```yaml
storageClassName: managed-premium  # For AKS
# or
storageClassName: gp3  # For EKS
```

---

## Troubleshooting

### Prometheus Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n monitoring -l app=prometheus

# Check logs
kubectl logs -n monitoring -l app=prometheus

# Common issues:
# - ConfigMap not found → Check if prometheus-config exists
# - PVC not bound → Check storage class
# - Resource limits → Check node resources
```

### No Targets Scraping

```bash
# Check Prometheus config
kubectl get configmap prometheus-config -n monitoring -o yaml

# Check if services expose /metrics endpoint
kubectl exec -n payflow <pod-name> -- wget -qO- http://localhost:3000/metrics

# Check Prometheus targets in UI
# Go to: Status → Targets
```

### Storage Issues

```bash
# Check PVC status
kubectl get pvc -n monitoring

# Check PV
kubectl get pv

# If PVC is pending, check storage class
kubectl get storageclass
```

---

## Next Steps

1. **Deploy Grafana** (to be added)
   - Visualize Prometheus metrics
   - Create dashboards

2. **Deploy AlertManager** (to be added)
   - Route alerts to Slack/Email
   - Group and silence alerts

3. **Configure Ingress** (as you mentioned)
   - Access Prometheus via URL
   - Access Grafana via URL
   - HTTPS with certificates

4. **Add Exporters** (optional)
   - PostgreSQL exporter
   - Redis exporter
   - Node exporter (system metrics)

---

## Useful Prometheus Queries

### Service Health
```promql
up{job="api-gateway"}
```

### Request Rate
```promql
rate(http_requests_total[5m])
```

### Error Rate
```promql
rate(http_requests_total{code=~"5.."}[5m])
```

### Response Time (95th percentile)
```promql
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

### Memory Usage
```promql
process_resident_memory_bytes
```

---

## Production Considerations

1. **High Availability**: Run multiple Prometheus instances (requires external storage)
2. **Long-term Storage**: Use Thanos or Cortex for long-term metrics
3. **Resource Limits**: Adjust based on metrics volume
4. **Retention**: Adjust retention time based on storage capacity
5. **Security**: Add authentication to Prometheus UI
6. **Network Policies**: Allow Prometheus to scrape from payflow namespace

---

*Monitoring is essential for production! 📊*

