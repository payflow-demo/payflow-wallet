# Monitoring Stack Deployment Guide

## 🎯 Overview

This guide will take your monitoring from **60% → 100%** production-ready. After following this guide, you'll have:

✅ **Business metrics** that catch issues before users complain  
✅ **CronJob monitoring** (would have caught our timeout handler issues)  
✅ **Infrastructure health** (CoreDNS, resource quotas, network policies)  
✅ **Database metrics** (connection pools, query duration, locks)  
✅ **RabbitMQ monitoring** (queue depth, consumers, backlogs)  
✅ **Production-grade alerting** (PagerDuty, Slack, email)  
✅ **Complete Grafana dashboard** with visual indicators

---

## 📋 Prerequisites

```bash
# Verify you have kubectl access
kubectl config current-context

# Verify Prometheus is running
kubectl get pods -n monitoring

# Verify MicroK8s addons (local only)
microk8s status
```

---

## 🚀 Deploy monitoring to EKS (with debugging)

For **private EKS**, `kubectl` only works from inside the VPC. Run the monitoring deploy from the **bastion host** via SSM.

### Step 1: Connect to the bastion

From your laptop (with AWS CLI and Session Manager plugin):

```bash
# Set region (match your Terraform)
export AWS_REGION=us-east-1

# Get bastion instance ID (from Terraform state)
cd /path/to/payflow-wallet-2
BASTION_ID=$(terraform -chdir=terraform/aws/bastion output -raw bastion_instance_id 2>/dev/null || echo "")

if [ -z "$BASTION_ID" ]; then
  echo "Could not get bastion ID. Run from repo root after: cd terraform/aws/bastion && terraform output bastion_instance_id"
  exit 1
fi

# Start SSM session (no SSH keys needed)
aws ssm start-session --target "$BASTION_ID" --region "$AWS_REGION"
```

**Debugging:**

- **"TargetNotConnected" / "TargetNotFound"**  
  Bastion may be stopped or SSM agent not ready. Check instance in EC2 console; ensure IAM instance profile has `AmazonSSMManagedInstanceCore`.

- **"SessionManagerPlugin not found"**  
  Install: [Session Manager plugin for AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

- **Region mismatch**  
  Use the same region as your EKS cluster: `aws ssm start-session --target $BASTION_ID --region us-east-1`.

### Step 2: On the bastion, get the repo and run the script

Once you're in the SSM shell on the bastion:

```bash
# 1. Ensure kubectl and AWS CLI exist (bastion user-data usually installs them)
which kubectl aws

# 2. Configure kubectl for EKS (if not already done)
# Replace CLUSTER_NAME and REGION with your values (from Terraform spoke output)
aws eks update-kubeconfig --region us-east-1 --name payflow-eks-cluster

# 3. Verify cluster access
kubectl cluster-info
kubectl get nodes
kubectl get ns payflow

# 4. Get the repo (clone or copy). Option A: clone (if bastion has git and network)
git clone https://github.com/your-org/payflow-wallet-2.git
cd payflow-wallet-2

# Option B: copy from laptop (from a second terminal on your laptop)
# From laptop: scp -r monitoring k8s/monitoring user@<bastion-ip>:~/payflow-wallet-2/
# Or use rsync over SSM: see "Copy files to bastion" below

# 5. Run the monitoring deploy script
./monitoring/deploy-monitoring.sh
```

**Debugging:**

- **"Cannot connect to Kubernetes cluster"**  
  - Run `kubectl cluster-info`. If it fails, run `aws eks update-kubeconfig --region <region> --name <cluster-name>`.  
  - Ensure bastion IAM role has EKS access (e.g. `eks:DescribeCluster`) and the cluster’s `aws-auth` (or EKS Access Entries) allows the bastion role.

- **"kubectl not found"**  
  Install kubectl on the bastion, or use the same version as your EKS control plane.

- **"No matching storage class"**  
  Script defaults to `gp3`. If your cluster uses another class (e.g. `gp2`), run:  
  `STORAGE_CLASS=gp2 ./monitoring/deploy-monitoring.sh`

- **Permission denied on script**  
  `chmod +x monitoring/deploy-monitoring.sh`

### Step 3: Copy files to bastion (if not using git)

If the bastion can’t clone the repo, copy only what’s needed from your laptop:

```bash
# From your laptop (new terminal), with BASTION_ID and AWS_REGION set:
# Create a tarball of monitoring + k8s/monitoring
cd /path/to/payflow-wallet-2
tar czf /tmp/payflow-monitoring.tar.gz monitoring k8s/monitoring

# Copy via S3 (bastion has AWS CLI)
aws s3 cp /tmp/payflow-monitoring.tar.gz s3://YOUR_BUCKET/payflow-monitoring.tar.gz --region "$AWS_REGION"

# On bastion (inside SSM session):
aws s3 cp s3://YOUR_BUCKET/payflow-monitoring.tar.gz /tmp/
mkdir -p payflow-wallet-2 && cd payflow-wallet-2 && tar xzf /tmp/payflow-monitoring.tar.gz
./monitoring/deploy-monitoring.sh
```

Alternatively use `rsync` over SSH if the bastion has an SSH server and you use SSH (not only SSM).

### Step 4: Verify and debug the stack

After the script finishes:

```bash
# Namespaces
kubectl get ns monitoring payflow

# Monitoring pods
kubectl get pods -n monitoring
kubectl get pods -n payflow -l 'app in (postgres-exporter,redis-exporter)'

# Storage class in use (script prints this)
kubectl get storageclass

# If something is Missing or CrashLoopBackOff
kubectl describe pod -n monitoring <pod-name>
kubectl logs -n monitoring <pod-name> --tail=100
```

**Common issues:**

- **Prometheus/Loki/Grafana pending (PVC)**  
  Check `kubectl get pvc -n monitoring`. If `storageClassName` is wrong for your cluster, set `STORAGE_CLASS` and re-run the script (or fix PVCs and redeploy).

- **postgres-exporter/redis-exporter not ready**  
  They need `db-secrets` (or ESO) and correct DSN. Check `kubectl get secret -n payflow` and exporter logs.

- **Script fails at “Waiting for … to be ready”**  
  Inspect the resource: `kubectl describe pod -n <ns> -l app=<name>` and `kubectl logs ...`. Fix the underlying issue (e.g. image pull, secrets, probes) then re-run the script.

### One-liner (from laptop) to run deploy on bastion

You can’t run the script *on* the bastion from your laptop in one command without extra tooling. The intended flow is:

1. **Terminal 1:** `aws ssm start-session --target $BASTION_ID --region $AWS_REGION`  
2. **In that session:** `cd payflow-wallet-2 && ./monitoring/deploy-monitoring.sh`

To only test connectivity from the laptop (e.g. with a public EKS endpoint):

```bash
aws eks update-kubeconfig --region us-east-1 --name payflow-eks-cluster
kubectl cluster-info
# If that works, you can run from laptop:
./monitoring/deploy-monitoring.sh
```

---

## 📊 Understanding Prometheus: The Essence of Monitoring

### **What is Prometheus?**

Prometheus is a **time-series database** that collects metrics from your services. Think of it as a health monitor that:
- **Scrapes** (pulls) metrics from services every few seconds
- **Stores** them in a time-series database
- **Queries** them using PromQL (Prometheus Query Language)
- **Alerts** when thresholds are exceeded

### **How Prometheus Works: The Pull Model**

```
┌─────────────┐         ┌──────────────┐         ┌─────────────┐
│   Service   │         │  Prometheus  │         │   Grafana   │
│  (exposes   │◄────────│   (scrapes   │◄────────│  (queries   │
│  /metrics)  │         │   metrics)   │         │  Prometheus)│
└─────────────┘         └──────────────┘         └─────────────┘
```

**Key Concept:** Services expose metrics, Prometheus pulls them.

1. **Service exposes `/metrics` endpoint** (e.g., `http://api-gateway:3000/metrics`)
2. **Prometheus scrapes** this endpoint every 15-30 seconds
3. **Metrics are stored** with timestamps
4. **Grafana queries** Prometheus to display graphs

### **What Are Metrics?**

Metrics are **numbers** that tell you about your system:

**Counter:** Always increases (e.g., total requests)
```
http_requests_total{method="GET", status="200"} 1234
http_requests_total{method="POST", status="500"} 5
```

**Gauge:** Can go up or down (e.g., current CPU usage)
```
cpu_usage_percent{instance="api-gateway"} 45.2
memory_usage_bytes{instance="api-gateway"} 256000000
```

**Histogram:** Tracks distribution (e.g., request duration)
```
http_request_duration_seconds_bucket{le="0.1"} 100
http_request_duration_seconds_bucket{le="0.5"} 150
http_request_duration_seconds_bucket{le="1.0"} 180
```

### **How to Check Systems with Prometheus**

#### **1. Access Prometheus UI**

```bash
# Port-forward to access Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Open in browser
open http://localhost:9090
```

#### **2. Check if Services Are Up**

**Go to:** Status → Targets (or http://localhost:9090/targets)

**What you see:**
- ✅ **UP** = Prometheus can scrape metrics (healthy)
- ❌ **DOWN** = Prometheus can't reach the service (problem!)

**What to check:**
- All PayFlow services should be UP
- If DOWN, check:
  - Is the service running? (`kubectl get pods`)
  - Is the `/metrics` endpoint working? (`curl http://service:port/metrics`)
  - Are network policies blocking? (`kubectl get networkpolicy`)

#### **3. Query Metrics (PromQL Basics)**

**Go to:** Graph (or http://localhost:9090/graph)

**Basic Queries:**

```promql
# Check if service is up (1 = up, 0 = down)
up{job="api-gateway"}

# Count total HTTP requests
sum(http_requests_total)

# Average response time
avg(http_request_duration_seconds)

# Current CPU usage
cpu_usage_percent

# Pending transactions (business metric)
payflow_pending_transactions_total

# Error rate (errors per second)
rate(http_requests_total{status="500"}[5m])
```

**Query Operators:**

```promql
# Rate: requests per second
rate(http_requests_total[5m])

# Sum: total across all instances
sum(http_requests_total)

# Average: average across instances
avg(cpu_usage_percent)

# Max: highest value
max(memory_usage_bytes)

# Filter by label
http_requests_total{status="500"}
http_requests_total{service="api-gateway"}

# Combine filters
http_requests_total{status="500", service="api-gateway"}
```

#### **4. Check Specific Service Health**

**Example: Check API Gateway**

```promql
# Is it up?
up{job="api-gateway"}

# Request rate
rate(http_requests_total{job="api-gateway"}[5m])

# Error rate
rate(http_requests_total{job="api-gateway", status="500"}[5m])

# Response time (p95)
histogram_quantile(0.95, 
  rate(http_request_duration_seconds_bucket{job="api-gateway"}[5m])
)
```

**Example: Check Database**

```promql
# Active connections
pg_stat_database_numbackends{datname="payflow"}

# Query duration
pg_stat_statements_mean_exec_time

# Transaction count
pg_stat_database_xact_commit{datname="payflow"}
```

**Example: Check CronJob**

```promql
# Last successful run
kube_job_status_succeeded{job_name=~"transaction-timeout-handler.*"}

# Failed jobs
kube_job_status_failed{job_name=~"transaction-timeout-handler.*"}

# Job duration
kube_job_status_completion_time - kube_job_status_start_time
```

#### **5. Check Business Metrics**

```promql
# Pending transactions (should be 0)
payflow_pending_transactions_total

# Money stuck in pending (should be $0)
payflow_pending_transaction_amount_total

# Oldest pending transaction age (should be 0s)
time() - payflow_transactions_oldest_pending_timestamp

# Transaction success rate
sum(rate(payflow_transactions_total{status="COMPLETED"}[5m])) / 
sum(rate(payflow_transactions_total[5m])) * 100
```

#### **6. Check Alerts**

**Go to:** Alerts (or http://localhost:9090/alerts)

**What you see:**
- **Pending** = Condition met, waiting for duration
- **Firing** = Alert is active (needs attention!)
- **Inactive** = No issues

**Example alerts:**
- `PendingTransactionsStuck` - Money is stuck!
- `CronJobFailures` - CronJob is failing
- `ServiceDown` - Service is not responding

### **Common Prometheus Queries for PayFlow**

```promql
# 1. Service Health Check
up{namespace="payflow"}

# 2. Request Rate (requests per second)
sum(rate(http_requests_total[5m])) by (service)

# 3. Error Rate
sum(rate(http_requests_total{status="500"}[5m])) by (service)

# 4. Response Time (p95)
histogram_quantile(0.95, 
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
)

# 5. Pending Transactions
payflow_pending_transactions_total

# 6. Database Connections
pg_stat_database_numbackends{datname="payflow"}

# 7. RabbitMQ Queue Depth
rabbitmq_queue_messages_ready{queue="transaction-queue"}

# 8. CPU Usage
avg(cpu_usage_percent) by (service)

# 9. Memory Usage
avg(memory_usage_bytes) by (service) / 1024 / 1024  # MB

# 10. CronJob Last Run
max(kube_job_status_completion_time{job_name=~"transaction-timeout-handler.*"})
```

### **How to Debug with Prometheus**

**Step 1: Check if service is being scraped**
```
Go to: Status → Targets
Look for: Your service (should be UP)
```

**Step 2: Check if metrics exist**
```
Go to: Graph
Query: up{job="your-service"}
Result: Should be 1 (if UP) or 0 (if DOWN)
```

**Step 3: Check specific metric**
```
Go to: Graph
Query: your_metric_name
Result: Should show data points
```

**Step 4: Check time range**
```
Use time picker: Last 1 hour, Last 6 hours, etc.
If no data: Service might be down or not emitting metrics
```

**Step 5: Check labels**
```
Query: your_metric{label="value"}
Labels help filter metrics (e.g., by service, status, etc.)
```

### **Prometheus vs. Logs**

| Prometheus (Metrics) | Logs |
|----------------------|------|
| Numbers (counts, rates) | Text messages |
| Fast queries | Slow searches |
| Aggregated data | Individual events |
| "How many errors?" | "What was the error?" |
| Good for: Trends, alerts | Good for: Debugging, details |

**Use Prometheus when:**
- You want to know "how many" or "how fast"
- You need to alert on thresholds
- You want to see trends over time

**Use Logs when:**
- You need to know "what happened"
- You're debugging a specific issue
- You need detailed error messages

---

## 🚀 Deployment Steps

### **Step 1: Deploy Kube State Metrics (CRITICAL)**

This provides metrics about Kubernetes objects (Jobs, CronJobs, ResourceQuotas).

```bash
cd /Users/mac/Desktop/Coaching/PayFlow\ Wallet\ 2

# Deploy kube-state-metrics
kubectl apply -f k8s/monitoring/kube-state-metrics.yaml

# Verify deployment
kubectl get pods -n kube-system -l app=kube-state-metrics

# Check metrics endpoint
kubectl port-forward -n kube-system svc/kube-state-metrics 8080:8080 &
curl localhost:8080/metrics | grep kube_job_status

# Stop port-forward
pkill -f "port-forward.*kube-state-metrics"
```

**Expected output:**
```
kube_job_status_completion_time{job_name="transaction-timeout-handler-..."} 1.73684e+09
kube_job_status_succeeded{job_name="transaction-timeout-handler-..."} 1
```

---

### **Step 2: Deploy PostgreSQL Exporter**

Provides database metrics including our critical business metrics.

```bash
# Deploy postgres-exporter
kubectl apply -f k8s/monitoring/postgres-exporter.yaml

# Verify deployment
kubectl get pods -n payflow -l app=postgres-exporter

# Check metrics
kubectl port-forward -n payflow svc/postgres-exporter 9187:9187 &
curl localhost:9187/metrics | grep pg_transactions

# You should see:
# pg_transactions_by_status{status="PENDING"} 0
# pg_transactions_by_status{status="COMPLETED"} 247
# pg_oldest_pending_transaction 0
# pg_pending_transaction_amount 0

# Stop port-forward
pkill -f "port-forward.*postgres-exporter"
```

---

### **Step 3: Enable RabbitMQ Prometheus Plugin**

RabbitMQ has a built-in Prometheus exporter that needs to be enabled.

```bash
# Enable prometheus plugin
kubectl exec -n payflow rabbitmq-0 -- rabbitmq-plugins enable rabbitmq_prometheus

# Verify plugin enabled
kubectl exec -n payflow rabbitmq-0 -- rabbitmq-plugins list | grep prometheus

# Check metrics endpoint
kubectl port-forward -n payflow svc/rabbitmq 15692:15692 &
curl localhost:15692/metrics | grep rabbitmq_queue

# Stop port-forward
pkill -f "port-forward.*rabbitmq"
```

**Expected output:**
```
rabbitmq_queue_messages_ready{queue="transaction-queue"} 0
rabbitmq_queue_consumers{queue="transaction-queue"} 2
```

---

### **Step 4: Update Prometheus Configuration**

```bash
# Update Prometheus with new scrape configs
kubectl delete configmap prometheus-config -n monitoring
kubectl create configmap prometheus-config -n monitoring \
  --from-file=prometheus.yml=k8s/monitoring/prometheus.yml

# Update alert rules
kubectl delete configmap prometheus-rules -n monitoring
kubectl create configmap prometheus-rules -n monitoring \
  --from-file=alerts.yml=k8s/monitoring/alerts.yml

# Reload Prometheus (without restart)
kubectl exec -n monitoring prometheus-0 -- killall -HUP prometheus

# Or restart Prometheus pod
kubectl delete pod -n monitoring prometheus-0

# Verify Prometheus targets
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
open http://localhost:9090/targets

# You should see:
# - kube-state-metrics (UP)
# - postgres-exporter (UP)
# - rabbitmq (UP)
# - kube-dns (UP)

# Stop port-forward
pkill -f "port-forward.*prometheus"
```

---

### **Step 5: Update AlertManager Configuration**

```bash
# Update AlertManager config
kubectl delete configmap alertmanager-config -n monitoring
kubectl create configmap alertmanager-config -n monitoring \
  --from-file=alertmanager.yml=k8s/monitoring/alertmanager.yml

# Reload AlertManager
kubectl exec -n monitoring alertmanager-0 -- killall -HUP alertmanager

# Or restart AlertManager pod
kubectl delete pod -n monitoring alertmanager-0

# Verify AlertManager is running
kubectl get pods -n monitoring -l app=alertmanager
```

---

### **Step 6: Configure Slack/PagerDuty (Production)**

#### **Slack Setup:**

1. Go to https://api.slack.com/apps
2. Create new app → "PayFlow Alerts"
3. Add Incoming Webhooks
4. Create webhooks for:
   - `#alerts` (warnings)
   - `#incidents` (critical)
5. Copy webhook URLs

```bash
# Update alertmanager.yml with your webhook URLs
# Find: https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK
# Replace with actual URLs

# Apply updated config
kubectl create configmap alertmanager-config -n monitoring \
  --from-file=alertmanager.yml=k8s/monitoring/alertmanager.yml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl delete pod -n monitoring alertmanager-0
```

#### **PagerDuty Setup:**

1. Go to PagerDuty → Services
2. Create service: "PayFlow Production"
3. Integration type: "Events API v2"
4. Copy Integration Key

```bash
# Update alertmanager.yml with your PagerDuty key
# Find: YOUR_PAGERDUTY_INTEGRATION_KEY
# Replace with actual key

# Apply config
kubectl create configmap alertmanager-config -n monitoring \
  --from-file=alertmanager.yml=k8s/monitoring/alertmanager.yml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl delete pod -n monitoring alertmanager-0
```

---

### **Step 7: Deploy Grafana**

Grafana provides visual dashboards for your Prometheus metrics. This section covers the complete deployment journey, including issues we faced and how we fixed them.

#### **7.1: Deploy Grafana Service and Deployment**

```bash
# Deploy Grafana
kubectl apply -f k8s/monitoring/grafana-deployment.yaml

# Verify deployment
kubectl get pods -n monitoring -l app=grafana

# Check service
kubectl get svc -n monitoring grafana
```

**Expected output:**
```
NAME      READY   STATUS    RESTARTS   AGE
grafana   1/1     Running   0          2m

NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
grafana      ClusterIP   10.152.183.39   <none>        3000/TCP  2m
```

**What this does:**
- Creates a Grafana deployment with 1 replica
- Exposes Grafana on port 3000 via ClusterIP service
- Configures Grafana datasource to point to Prometheus
- Sets default admin credentials (admin/admin - change in production!)

#### **7.2: Configure Grafana Datasource**

The Grafana deployment automatically configures Prometheus as a datasource using a ConfigMap. This is defined in `k8s/monitoring/grafana-deployment.yaml`.

**What is `grafana-datasources.yml`?**
- **One sentence:** It tells Grafana where to find Prometheus metrics (the datasource URL).
- **Details:** Grafana needs to know which Prometheus instance to query. The datasource config points Grafana to `http://prometheus.monitoring.svc.cluster.local:9090`, which is the Prometheus service in the monitoring namespace.

**Verify datasource is configured:**
```bash
# Port-forward to Grafana
kubectl port-forward -n monitoring svc/grafana 3000:3000 &

# Open Grafana
open http://localhost:3000

# Login: admin / admin
# Go to: Configuration → Data Sources
# You should see: Prometheus (Default)
```

#### **7.3: Import Grafana Dashboard**

```bash
# Option 1: Auto-import via API (if you have API key)
GRAFANA_URL="http://localhost:3000"
GRAFANA_API_KEY="your-api-key"

curl -X POST "$GRAFANA_URL/api/dashboards/db" \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d @k8s/monitoring/grafana-dashboards/payflow-complete-dashboard.json

# Option 2: Manual import (recommended for first time)
kubectl port-forward -n monitoring svc/grafana 3000:3000 &

# Open Grafana
open http://localhost:3000

# Login: admin / admin (change on first login)
# Go to: + → Import Dashboard
# Upload: k8s/monitoring/grafana-dashboards/payflow-complete-dashboard.json
# Click: Import
```

**Expected result:**
- Dashboard appears in Grafana
- Shows panels for business metrics, CronJob health, infrastructure, etc.
- **BUT:** Panels may show "No data" initially (see troubleshooting below)

#### **7.4: Set Up Ingress for Grafana (Optional but Recommended)**

To access Grafana via a friendly URL instead of port-forwarding:

```bash
# Deploy monitoring ingress (includes Prometheus and Grafana)
kubectl apply -f k8s/ingress/monitoring-ingress.yaml

# Verify ingress
kubectl get ingress -n monitoring

# Add to /etc/hosts (macOS/Linux) or C:\Windows\System32\drivers\etc\hosts (Windows)
# Get ingress IP first:
INGRESS_IP=$(kubectl get ingress -n monitoring monitoring-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# If empty, use node IP (for MicroK8s):
INGRESS_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Add to /etc/hosts:
echo "${INGRESS_IP} grafana.payflow.local prometheus.payflow.local" | sudo tee -a /etc/hosts
```

**Access Grafana:**
- Via Ingress: `http://grafana.payflow.local`
- Via Port-forward: `http://localhost:3000`

---

### **Step 8: Grafana Troubleshooting - Real Issues We Fixed**

This section documents the actual issues we encountered when deploying Grafana and how we systematically debugged and fixed them.

---

#### **Issue 1: Grafana Dashboards Show "No Data" - The Complete Journey**

**Symptom:** After importing the dashboard, all panels showed "No data" even though:
- Prometheus was running and healthy
- All Prometheus targets were UP
- Prometheus had metrics data

**Our Thought Process:**
1. First, we verified Prometheus was working (it was)
2. Then we checked if Grafana could query Prometheus (it could)
3. We discovered the dashboard queries were using wrong metric names
4. We systematically updated all queries to match actual metrics

---

#### **Problem 1: Dashboard Queries Using Wrong Metric Names**

**What We Saw:**
- Dashboard panels showing "No data"
- Prometheus had data, but Grafana couldn't find it

**Step 1: Check if Prometheus has data**
```bash
# Why: First rule - verify the data source has data
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
open http://localhost:9090/graph

# Query: up{namespace="payflow"}
# Result: Shows 1 (services are up) ✅
```

**Step 2: Check if Grafana can query Prometheus**
```bash
# Why: If Grafana can't reach Prometheus, no data will show
kubectl port-forward -n monitoring svc/grafana 3000:3000 &
open http://localhost:3000

# Go to: Explore → Select Prometheus → Query: up
# Result: Shows data! ✅ Grafana can query Prometheus
```

**Step 3: Check what metrics actually exist**
```bash
# Why: The dashboard queries might be looking for metrics that don't exist
# Go to Prometheus UI: http://localhost:9090
# Go to: Graph
# Query: {__name__=~"payflow.*"}
# Result: No metrics found! ❌

# Try: {__name__=~"pg.*"}
# Result: Found metrics! ✅
# Examples:
# - pg_transactions_by_status_count{status="PENDING"}
# - pg_stat_database_numbackends
```

**Step 4: Check dashboard queries**
```bash
# Why: We need to see what the dashboard is querying
cat k8s/monitoring/grafana-dashboards/payflow-complete-dashboard.json | grep -A 5 "expr"

# Result: Found queries like:
# - payflow_pending_transactions_total
# - payflow_transactions_oldest_pending_timestamp
# - payflow_pending_transaction_amount_total
```

**Root Cause:** The dashboard was created expecting custom `payflow_*` metrics from the application services, but:
- The application services weren't emitting these metrics yet
- The `postgres-exporter` was exposing `pg_*` metrics instead
- The dashboard queries didn't match the actual metric names

**The Fix:**
We updated the dashboard JSON to use the actual metrics from `postgres-exporter`:

```json
// BEFORE (wrong):
{
  "expr": "payflow_pending_transactions_total",
  "refId": "A"
}

// AFTER (correct):
{
  "expr": "pg_transactions_by_status_count{status=\"PENDING\"}",
  "refId": "A"
}
```

**Specific Changes Made:**

1. **Pending Transactions:**
   - Before: `payflow_pending_transactions_total`
   - After: `pg_transactions_by_status_count{status="PENDING"}`

2. **Money Stuck:**
   - Before: `payflow_pending_transaction_amount_total`
   - After: `pg_pending_transaction_amount_total` (if available) or calculated from `pg_transactions_by_status_count`

3. **Oldest Pending Age:**
   - Before: `time() - payflow_transactions_oldest_pending_timestamp`
   - After: `time() - pg_oldest_pending_transaction_timestamp` (if available)

4. **Transaction Rates:**
   - Before: `rate(payflow_transactions_total[5m])`
   - After: `rate(pg_stat_database_xact_commit[5m])` or `rate(pg_transactions_by_status_count[5m])`

**Why This Works:**
- `postgres-exporter` queries the database and exposes metrics with `pg_*` prefix
- These metrics reflect the actual database state
- The dashboard queries now match what Prometheus actually has

**Command to Apply:**
```bash
# Update dashboard file
# (Edit k8s/monitoring/grafana-dashboards/payflow-complete-dashboard.json)

# Re-import dashboard in Grafana
# Go to: Dashboards → Import → Upload updated JSON
```

---

#### **Problem 2: No Data Because System Is Idle**

**What We Saw:**
- Dashboard queries were correct
- Prometheus had metrics
- But panels still showed "No data" or flat lines at zero

**Step 1: Check if metrics have recent data**
```bash
# Why: Metrics might exist but have no recent data points
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
open http://localhost:9090/graph

# Query: pg_transactions_by_status_count{status="PENDING"}
# Check time range: Last 1 hour
# Result: Shows 0 (no pending transactions) ✅
```

**Step 2: Simulate data to test dashboard**
```bash
# Why: We need to generate activity to see if dashboard works
# Create test transactions via API
kubectl port-forward -n payflow svc/api-gateway 3000:3000 &

# Make API calls to generate metrics
curl -X POST http://localhost:3000/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"test123","email":"test@test.com"}'

# Create transactions
curl -X POST http://localhost:3000/api/transactions \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"to_user_id":"user2","amount":10.00}'
```

**Step 3: Check dashboard again**
```bash
# Why: After generating activity, metrics should appear
# Go to Grafana dashboard
# Check time range: Last 15 minutes
# Result: Should show data now! ✅
```

**Root Cause:** The system was idle, so metrics existed but had no activity. This is normal for a new deployment.

**The Fix:**
- Generate test data to verify dashboard works
- In production, real user activity will populate metrics
- For testing, use the simulation commands above

---

#### **Problem 3: Grafana Readiness/Liveness Probe Failures**

**What We Saw:**
```bash
kubectl get pods -n monitoring -l app=grafana
# Result:
# NAME      READY   STATUS             RESTARTS   AGE
# grafana   0/1     Running           0          30s
```

**Step 1: Check pod events**
```bash
# Why: Events tell us why the pod isn't ready
kubectl describe pod -n monitoring -l app=grafana | grep -A 10 "Events"

# Result:
# Warning  Unhealthy  Readiness probe failed: Get "http://10.1.254.178:3000/api/health": dial tcp 10.1.254.178:3000: connect: connection refused
```

**Step 2: Check Grafana logs**
```bash
# Why: Logs tell us what Grafana is doing during startup
kubectl logs -n monitoring -l app=grafana --tail=50

# Result:
# logger=server t=2024-01-14T10:30:15.123Z level=info msg="Starting Grafana" version=10.2.0
# logger=server t=2024-01-14T10:30:20.456Z level=info msg="HTTP Server Listen" address=0.0.0.0:3000
```

**Root Cause:** Grafana takes 30-60 seconds to fully start. The readiness probe was checking too early (10 seconds), before Grafana finished initializing.

**The Fix:**
We increased the readiness probe `initialDelaySeconds` in the deployment:

```yaml
# In k8s/monitoring/grafana-deployment.yaml
readinessProbe:
  httpGet:
    path: /api/health
    port: 3000
  initialDelaySeconds: 30  # ← Increased from 10 to 30
  periodSeconds: 5
```

**Why This Works:**
- Grafana needs time to initialize (load configs, connect to datasources, etc.)
- The readiness probe tells Kubernetes when the pod is ready to receive traffic
- If the probe runs too early, it fails and the pod stays "Not Ready"
- Increasing the delay gives Grafana time to start

**Command to Apply:**
```bash
kubectl apply -f k8s/monitoring/grafana-deployment.yaml
kubectl delete pod -n monitoring -l app=grafana  # Restart to pick up changes
```

---

#### **Problem 4: Grafana Datasource Not Connecting to Prometheus**

**What We Saw:**
- Grafana was running
- Datasource was configured
- But queries returned "Datasource not found" or connection errors

**Step 1: Check datasource configuration**
```bash
# Why: The datasource config might be wrong
kubectl get configmap grafana-datasources -n monitoring -o yaml

# Check the URL:
# url: http://prometheus.monitoring.svc.cluster.local:9090
```

**Step 2: Test connectivity from Grafana pod**
```bash
# Why: If Grafana can't reach Prometheus, queries will fail
kubectl exec -n monitoring $(kubectl get pods -n monitoring -l app=grafana -o jsonpath='{.items[0].metadata.name}') -- wget -qO- --timeout=5 http://prometheus.monitoring.svc.cluster.local:9090/api/v1/status/config

# Result: Should return Prometheus config JSON ✅
# If fails: Check network policies or DNS
```

**Step 3: Check network policies**
```bash
# Why: Network policies might block Grafana from reaching Prometheus
kubectl get networkpolicy -n monitoring

# If no policies exist, that's fine (default allow)
# If policies exist, check if they allow Grafana → Prometheus
```

**Root Cause:** In our case, the datasource URL was correct, but we needed to verify network connectivity.

**The Fix:**
- Verified datasource URL uses FQDN: `prometheus.monitoring.svc.cluster.local:9090`
- Tested connectivity from Grafana pod
- Confirmed network policies allow traffic (or no policies = default allow)

**Why This Works:**
- FQDN ensures DNS resolution works across namespaces
- Testing from the pod verifies actual connectivity
- Network policies control pod-to-pod communication

---

### **Grafana Deployment Summary: What We Did**

1. **Deployed Grafana:**
   - Created deployment with 1 replica
   - Exposed via ClusterIP service on port 3000
   - Configured datasource to point to Prometheus

2. **Fixed Dashboard Queries:**
   - Updated all queries from `payflow_*` to `pg_*` metrics
   - Matched queries to actual metrics from `postgres-exporter`
   - Tested queries in Prometheus before updating dashboard

3. **Set Up Ingress:**
   - Created `monitoring-ingress.yaml` for Grafana and Prometheus
   - Added entries to `/etc/hosts` for friendly URLs
   - Accessible via `http://grafana.payflow.local`

4. **Fixed Readiness Probes:**
   - Increased `initialDelaySeconds` to 30s
   - Gives Grafana time to initialize before marking as ready

5. **Simulated Data:**
   - Created test transactions to populate metrics
   - Verified dashboard shows data correctly

---

### **Grafana Access Methods**

**Method 1: Port-Forward (Quick Testing)**
```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
open http://localhost:3000
```

**Method 2: Ingress (Production-Like)**
```bash
# Access via: http://grafana.payflow.local
# (Requires /etc/hosts entry)
```

**Method 3: NodePort (If Configured)**
```bash
# Get node IP and port
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc -n monitoring grafana -o jsonpath='{.spec.ports[0].nodePort}')
# Access: http://${NODE_IP}:${NODE_PORT}
```

---

### **Grafana Dashboard Verification Checklist**

After deployment, verify everything works:

```bash
# 1. Grafana pod is running
kubectl get pods -n monitoring -l app=grafana
# Expected: 1/1 Running

# 2. Grafana service is accessible
kubectl port-forward -n monitoring svc/grafana 3000:3000 &
curl http://localhost:3000/api/health
# Expected: {"commit":"...","database":"ok","version":"10.2.0"}

# 3. Datasource is configured
# Go to: http://localhost:3000 → Configuration → Data Sources
# Expected: Prometheus (Default) with green "Data source is working"

# 4. Dashboard is imported
# Go to: http://localhost:3000 → Dashboards
# Expected: "PayFlow Production Dashboard - Complete"

# 5. Dashboard shows data (after generating activity)
# Go to: Dashboard → Check panels
# Expected: Panels show metrics (not "No data")
```

---

### **Grafana Troubleshooting Commands**

```bash
# Check Grafana logs
kubectl logs -n monitoring -l app=grafana --tail=50

# Check Grafana pod status
kubectl describe pod -n monitoring -l app=grafana

# Test Grafana health endpoint
kubectl exec -n monitoring $(kubectl get pods -n monitoring -l app=grafana -o jsonpath='{.items[0].metadata.name}') -- wget -qO- http://localhost:3000/api/health

# Test Prometheus connectivity from Grafana
kubectl exec -n monitoring $(kubectl get pods -n monitoring -l app=grafana -o jsonpath='{.items[0].metadata.name}') -- wget -qO- --timeout=5 http://prometheus.monitoring.svc.cluster.local:9090/api/v1/status/config

# Check datasource config
kubectl get configmap grafana-datasources -n monitoring -o yaml

# Restart Grafana (if needed)
kubectl delete pod -n monitoring -l app=grafana
```

---

### **What We Learned from Grafana Deployment**

1. **Dashboard queries must match actual metric names**
   - Don't assume metric names - check Prometheus first
   - Use `{__name__=~".*"}` in Prometheus to discover metrics
   - Update dashboard queries to match reality

2. **Grafana needs time to start**
   - Increase readiness probe delay for slow-starting services
   - Check logs if pod stays "Not Ready"

3. **Datasource URLs must use FQDNs**
   - Use `service.namespace.svc.cluster.local` for cross-namespace access
   - Test connectivity from the actual pod

4. **"No data" can mean multiple things**
   - Wrong metric names (fix queries)
   - No recent activity (normal for idle systems)
   - Datasource not connected (check config)

5. **Ingress makes access easier**
   - Friendly URLs instead of port-forwarding
   - Production-like setup for testing

---

### **Step 9: Update Service Code to Emit Metrics**

Add business metrics tracking to your services:

```bash
# Example: Update transaction-service to track pending transactions
# Add to services/transaction-service/server.js:

const metrics = require('../shared/metrics');

// Update pending transactions gauge every 30 seconds
setInterval(async () => {
  try {
    // Get pending count
    const result = await db.query(`
      SELECT 
        COUNT(*) as pending_count,
        COALESCE(SUM(amount), 0) as pending_amount,
        EXTRACT(EPOCH FROM MIN(created_at)) as oldest_timestamp
      FROM transactions 
      WHERE status = 'PENDING'
    `);
    
    const row = result.rows[0];
    
    metrics.pendingTransactionsGauge.set(parseInt(row.pending_count));
    metrics.pendingTransactionAmountGauge.set(parseFloat(row.pending_amount));
    
    if (row.oldest_timestamp) {
      metrics.oldestPendingTransactionGauge.set(parseFloat(row.oldest_timestamp));
    }
    
    // Get transaction counts by status
    const statusResult = await db.query(`
      SELECT status, COUNT(*) as count 
      FROM transactions 
      GROUP BY status
    `);
    
    statusResult.rows.forEach(row => {
      metrics.transactionsByStatus.labels(row.status).set(parseInt(row.count));
    });
    
  } catch (err) {
    console.error('Failed to update metrics:', err);
  }
}, 30000); // Every 30 seconds
```

**Rebuild and redeploy services:**
```bash
# Rebuild services
cd services/transaction-service
docker build -t payflow/transaction-service:latest .

# Push to registry (if using)
docker push payflow/transaction-service:latest

# Restart deployment
kubectl rollout restart deployment transaction-service -n payflow
```

---

### **Step 10: Test Alerts**

#### **Test 1: Pending Transaction Alert**

```bash
# Create a test pending transaction
kubectl exec postgres-0 -n payflow -- psql -U payflow -d payflow -c "
  INSERT INTO transactions (id, from_user_id, to_user_id, amount, status, created_at) 
  VALUES ('TEST-ALERT-' || floor(random() * 10000)::text, 'test', 'test', 100.00, 
          'PENDING', NOW() - INTERVAL '5 minutes');
"

# Wait 3 minutes for alert to fire
sleep 180

# Check AlertManager
kubectl port-forward -n monitoring svc/alertmanager 9093:9093 &
open http://localhost:9093

# You should see: PendingTransactionsStuck alert

# Check Slack #alerts channel for notification

# Cleanup test transaction
kubectl exec postgres-0 -n payflow -- psql -U payflow -d payflow -c "
  DELETE FROM transactions WHERE id LIKE 'TEST-ALERT%';
"
```

#### **Test 2: CronJob Failure Alert**

```bash
# Suspend CronJob
kubectl patch cronjob transaction-timeout-handler -n payflow -p '{"spec":{"suspend":true}}'

# Wait 3 minutes
sleep 180

# Check for alert: TransactionTimeoutCronJobNotRunning

# Unsuspend
kubectl patch cronjob transaction-timeout-handler -n payflow -p '{"spec":{"suspend":false}}'
```

#### **Test 3: Service Down Alert**

```bash
# Scale down a service
kubectl scale deployment wallet-service -n payflow --replicas=0

# Wait 1 minute
sleep 60

# Check for alert: ServiceDown

# Scale back up
kubectl scale deployment wallet-service -n payflow --replicas=2
```

---

## 🔍 Verification Checklist

After deployment, verify everything works:

```bash
# 1. All monitoring pods running
kubectl get pods -n monitoring
kubectl get pods -n kube-system -l app=kube-state-metrics
kubectl get pods -n payflow -l app=postgres-exporter

# 2. Prometheus scraping all targets
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
open http://localhost:9090/targets
# All should show "UP"

# 3. Check Prometheus has business metrics
curl http://localhost:9090/api/v1/query?query=payflow_pending_transactions_total

# 4. AlertManager configured
kubectl port-forward -n monitoring svc/alertmanager 9093:9093 &
open http://localhost:9093

# 5. Grafana dashboard loaded
kubectl port-forward -n monitoring svc/grafana 3000:3000 &
open http://localhost:3000

# Navigate to: Dashboards → PayFlow Production Dashboard - Complete
```

---

## 📊 Dashboard Overview

Your new dashboard shows:

### **Row 1: CRITICAL BUSINESS METRICS**
- ⏳ Pending Transactions (should be 0)
- 💰 Money Stuck (should be $0)
- ⏰ Oldest Pending Age (should be 0s)
- ✅ Transaction Success Rate (should be >99%)

### **Row 2: CRONJOB HEALTH**
- ⏱️ Last Successful Run (should be <60s)
- ❌ Failed Jobs (should be 0)
- CronJob Execution Duration (should be ~10s)
- Transactions Reversed by CronJob

### **Row 3: TRANSACTION METRICS**
- Transaction Rate by Status
- Transaction Processing Duration

### **Row 4: INFRASTRUCTURE HEALTH**
- Service Health Status (all green)
- Resource Quota Utilization (<85%)
- CoreDNS Response Rate

### **Row 5: RABBITMQ HEALTH**
- Queue Depth (should be low)
- Active Consumers (should match workers)

### **Row 6: DATABASE METRICS**
- Connection Pool (active/idle)
- Query Duration

---

## 🚨 Alert Testing Results

Expected alert timeline after deployment:

| Time | Alert | Channel | Severity |
|------|-------|---------|----------|
| T+0 | None | - | - |
| T+3m | CronJobNotRunning (if suspended) | Slack + PagerDuty | Critical |
| T+3m | PendingTransactionsStuck (if any) | Slack + PagerDuty | P0 |
| T+1m | ServiceDown (if service down) | Slack + PagerDuty | Critical |

---

## 🔧 Troubleshooting: Real-World Issues We Fixed

This section documents actual issues we encountered during deployment and how we solved them. This is a **beginner-friendly walkthrough** of the debugging process.

---

### **Issue 1: Prometheus Targets Showing DOWN - The Complete Debugging Journey**

**Symptom:** After deploying monitoring, Prometheus showed several targets as DOWN:
- `api-gateway` - timeout errors
- `postgres-exporter` - timeout errors  
- `rabbitmq` - timeout errors

**Our Thought Process:**
1. First, we checked if services were running (they were)
2. Then we tested connectivity from Prometheus pod
3. We discovered different root causes for each service
4. We fixed each one systematically

---

#### **Problem 1: api-gateway Timeout**

**What We Saw:**
```
Error scraping target: Get "http://api-gateway.payflow.svc.cluster.local:3000/metrics": context deadline exceeded
```

**Step 1: Check if the service is running**
```bash
# Why: First rule of debugging - verify the service exists
kubectl get pods -n payflow -l app=api-gateway
```
**Result:** Pods were running ✅

**Step 2: Test from inside the pod**
```bash
# Why: If it works from inside, the endpoint exists. If not, the service code is broken.
kubectl exec -n payflow $(kubectl get pods -n payflow -l app=api-gateway -o jsonpath='{.items[0].metadata.name}') -- wget -qO- --timeout=5 http://localhost:3000/metrics | head -5
```
**Result:** Metrics endpoint worked from inside the pod ✅

**Step 3: Test from Prometheus pod**
```bash
# Why: This tests if Prometheus can reach the service (network policy, DNS, routing)
kubectl exec -n monitoring $(kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}') -- wget -qO- --timeout=10 http://api-gateway.payflow.svc.cluster.local:3000/metrics
```
**Result:** Connection timed out ❌

**Step 4: Test direct pod IP (bypass service)**
```bash
# Why: If pod IP works but service doesn't, the issue is with the Service configuration
API_GW_IP=$(kubectl get pods -n payflow -l app=api-gateway -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n monitoring $(kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}') -- wget -qO- --timeout=10 http://${API_GW_IP}:3000/metrics
```
**Result:** Direct pod IP worked! ✅ This told us the network policy was fine, but the Service was the problem.

**Step 5: Check Service configuration**
```bash
# Why: We need to see what ports the service exposes
kubectl get svc api-gateway -n payflow -o yaml | grep -A 5 "ports:"
```
**Result:** Service only exposed port 80, not port 3000! 🎯

**Root Cause:** The `api-gateway` service was configured as a LoadBalancer with only port 80 exposed. Prometheus was trying to connect to port 3000, which didn't exist on the service.

**The Fix:**
```yaml
# We added port 3000 to the service in k8s/deployments/api-gateway.yaml
ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 3000
  - name: metrics    # ← NEW: Added this port
    protocol: TCP
    port: 3000       # ← Expose port 3000
    targetPort: 3000 # ← Route to container port 3000
```

**Why This Works:**
- Kubernetes Services act as load balancers
- They only route traffic to ports that are explicitly defined
- Port 80 was defined, but port 3000 wasn't
- Adding port 3000 allows Prometheus to connect

**Command to Apply:**
```bash
kubectl apply -f k8s/deployments/api-gateway.yaml
```

---

#### **Problem 2: postgres-exporter Timeout**

**What We Saw:**
```
Error scraping target: Get "http://postgres-exporter.payflow.svc.cluster.local:9187/metrics": context deadline exceeded
```

**Step 1: Check postgres-exporter logs**
```bash
# Why: Logs tell us what the exporter is doing (or failing to do)
kubectl logs -n payflow -l app=postgres-exporter --tail=20
```
**Result:** We saw password authentication errors:
```
pq: password authentication failed for user "payflow"
```

**Step 2: Check what password is in the secret**
```bash
# Why: The exporter uses a secret for database credentials. Wrong password = can't connect.
kubectl get secret postgres-exporter-secret -n payflow -o jsonpath='{.data.DATA_SOURCE_NAME}' | base64 -d
```
**Result:** Secret had `payflowpass` but database expected `payflow123`

**Step 3: Check actual database password**
```bash
# Why: We need to know the correct password to fix the secret
kubectl get secret db-secrets -n payflow -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```
**Result:** Database password was `payflow123`

**Root Cause:** The postgres-exporter secret was created with a hardcoded password (`payflowpass`) that didn't match the actual database password (`payflow123`).

**The Fix:**
```bash
# Get the correct password from db-secrets
DB_PASS=$(kubectl get secret db-secrets -n payflow -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)

# Delete old secret
kubectl delete secret postgres-exporter-secret -n payflow

# Create new secret with correct password
kubectl create secret generic postgres-exporter-secret -n payflow \
  --from-literal=DATA_SOURCE_NAME="postgresql://payflow:${DB_PASS}@postgres.payflow.svc.cluster.local:5432/payflow?sslmode=disable"

# Restart exporter to pick up new secret
kubectl delete pod -n payflow -l app=postgres-exporter
```

**Why This Works:**
- Kubernetes Secrets store sensitive data
- When a pod starts, it reads secrets as environment variables
- If the secret has wrong data, the pod fails
- Updating the secret and restarting the pod fixes it

**Additional Fix: Network Policy**
We also discovered postgres-exporter couldn't reach postgres due to network policies. We added:
```yaml
# In k8s/policies/network-policies.yaml
# Allow postgres-exporter to connect to postgres
- from:
  - podSelector:
      matchLabels:
        app: postgres-exporter
  ports:
  - protocol: TCP
    port: 5432
```

---

#### **Problem 3: rabbitmq Timeout**

**What We Saw:**
```
Error scraping target: Get "http://rabbitmq.payflow.svc.cluster.local:15692/metrics": context deadline exceeded
```

**Step 1: Check if RabbitMQ plugin is enabled**
```bash
# Why: RabbitMQ needs a plugin to expose Prometheus metrics
kubectl exec -n payflow rabbitmq-0 -- rabbitmq-plugins list | grep prometheus
```
**Result:** Plugin was enabled ✅

**Step 2: Check if port 15692 is listening**
```bash
# Why: Even if plugin is enabled, we need to verify the port is open
kubectl exec -n payflow rabbitmq-0 -- netstat -tlnp 2>/dev/null | grep 15692
```
**Result:** Port 15692 was listening ✅

**Step 3: Check Service configuration**
```bash
# Why: The service needs to expose port 15692 for Prometheus to reach it
kubectl get svc rabbitmq -n payflow -o yaml | grep -A 5 "15692"
```
**Result:** Port 15692 was NOT in the service! ❌

**Root Cause:** RabbitMQ was listening on port 15692, but the Kubernetes Service didn't expose it. Prometheus couldn't reach the port through the service.

**The Fix:**
```yaml
# In k8s/infrastructure/rabbitmq.yaml
# Added port 15692 to the service
ports:
  - name: amqp
    port: 5672
  - name: management
    port: 15672
  - name: prometheus    # ← NEW: Added this
    port: 15692         # ← Expose Prometheus metrics port
    targetPort: 15692   # ← Route to container port 15692
```

**Why This Works:**
- RabbitMQ container listens on port 15692
- But Kubernetes Service is what other pods use to connect
- If the service doesn't expose port 15692, Prometheus can't reach it
- Adding the port to the service makes it accessible

**Additional Fix: Network Policy**
We also added a network policy to allow Prometheus to scrape RabbitMQ:
```yaml
# In k8s/policies/network-policies.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-rabbitmq
  namespace: payflow
spec:
  podSelector:
    matchLabels:
      app: rabbitmq
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
      podSelector:
        matchLabels:
          app: prometheus
    ports:
    - protocol: TCP
      port: 15692
```

---

#### **Problem 4: Prometheus Config Error (Timeout > Interval)**

**What We Saw:**
```
Error loading config: scrape timeout greater than scrape interval for scrape config with job name "postgres-exporter"
```

**Step 1: Check Prometheus logs**
```bash
# Why: Prometheus logs tell us exactly what's wrong with the config
kubectl logs -n monitoring -l app=prometheus --tail=30
```
**Result:** Error message was clear - timeout must be less than interval

**Root Cause:** We set `scrape_timeout: 20s` but didn't set `scrape_interval`, so it defaulted to 15s. Prometheus requires timeout < interval.

**The Fix:**
```yaml
# In k8s/monitoring/prometheus.yml
- job_name: 'postgres-exporter'
  scrape_interval: 30s  # ← Set interval to 30s
  scrape_timeout: 25s    # ← Timeout (25s) < interval (30s) ✅
```

**Why This Works:**
- Prometheus scrapes metrics at regular intervals
- Each scrape has a timeout (max time to wait)
- If timeout > interval, Prometheus would start a new scrape before the old one finished
- This causes race conditions and errors
- Rule: `timeout < interval` always

**Command to Apply:**
```bash
kubectl create configmap prometheus-config -n monitoring \
  --from-file=prometheus.yml=k8s/monitoring/prometheus.yml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl delete pod -n monitoring -l app=prometheus
```

---

### **Debugging Methodology: How We Approach Issues**

**1. Start with the obvious**
```bash
# Is the service running?
kubectl get pods -n <namespace> -l app=<service-name>
```

**2. Check logs**
```bash
# What errors are happening?
kubectl logs -n <namespace> -l app=<service-name> --tail=50
```

**3. Test connectivity**
```bash
# Can we reach the service?
kubectl exec -n <namespace> <pod-name> -- curl http://service-name:port
```

**4. Check configuration**
```bash
# Is the service configured correctly?
kubectl get svc <service-name> -n <namespace> -o yaml
kubectl get networkpolicy -n <namespace>
```

**5. Test from different angles**
```bash
# Test from inside pod (bypasses service)
# Test from Prometheus pod (tests network policies)
# Test direct IP (bypasses DNS)
```

**6. Fix systematically**
- One issue at a time
- Test after each fix
- Document what worked

---

### **Common Issues: kube-state-metrics not scraping**

```bash
# Check pod logs
kubectl logs -n kube-system -l app=kube-state-metrics

# Check RBAC permissions
kubectl auth can-i list jobs --as=system:serviceaccount:kube-system:kube-state-metrics
```

### **Issue: Postgres exporter failing**

```bash
# Check logs
kubectl logs -n payflow -l app=postgres-exporter

# Test database connection
kubectl exec -n payflow postgres-exporter-xxx -- psql $DATA_SOURCE_NAME -c "SELECT 1"

# Check secret
kubectl get secret postgres-exporter-secret -n payflow -o yaml
```

### **Issue: RabbitMQ metrics not appearing**

```bash
# Check if plugin enabled
kubectl exec -n payflow rabbitmq-0 -- rabbitmq-plugins list | grep prometheus

# Re-enable plugin
kubectl exec -n payflow rabbitmq-0 -- rabbitmq-plugins enable rabbitmq_prometheus

# Restart RabbitMQ
kubectl delete pod -n payflow rabbitmq-0
```

### **Issue: Alerts not firing**

```bash
# Check Prometheus rules loaded
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
open http://localhost:9090/rules

# Check AlertManager config
kubectl logs -n monitoring alertmanager-0 | grep -i error

# Test alert expression in Prometheus
# Go to: Graph → Enter alert expression → Execute
```

---

## 📈 Cost Analysis

**Before (60% monitoring):**
- Prometheus: ~$5/month
- Grafana: ~$3/month
- **Total: ~$8/month**
- **Blind spots:** CronJobs, business metrics, infrastructure health

**After (100% monitoring):**
- Prometheus: ~$5/month
- Grafana: ~$3/month
- kube-state-metrics: ~$1/month
- postgres-exporter: ~$0.50/month
- **Total: ~$9.50/month**

**ROI:** $1.50/month extra cost prevents $100,000+ incidents

---

## 🎓 What We Learned

**This monitoring setup would have caught:**

1. ✅ **CronJob DNS issues** (CoreDNS monitoring)
2. ✅ **Job pod failures** (kube-state-metrics)
3. ✅ **Pending transactions** (business metrics)
4. ✅ **Resource quota exhaustion** (quota monitoring)
5. ✅ **RabbitMQ 19-day outage** (queue metrics)
6. ✅ **Network policy misconfigurations** (connection errors)

**Before:** Found issues when users complained (hours/days later)  
**After:** Alerted within 1-3 minutes of issue occurring

---

## 📚 Next Steps

1. **Week 1:** Deploy all components, verify metrics
2. **Week 2:** Test alerts in staging, tune thresholds
3. **Week 3:** Configure PagerDuty, set up on-call rotation
4. **Week 4:** Add custom dashboards for specific teams
5. **Month 2:** Implement SLO tracking and error budgets
6. **Month 3:** Add distributed tracing with Jaeger

---

## 🆘 Support

If you encounter issues:
1. Check logs: `kubectl logs -n monitoring <pod-name>`
2. Verify connectivity: `kubectl port-forward ...`
3. Review Prometheus targets: http://localhost:9090/targets
4. Check AlertManager status: http://localhost:9093

**Production Support:**
- Slack: #monitoring-help
- Runbook: https://github.com/payflow/docs/monitoring
- On-call: page-monitoring@payflow.com

---

---

## 📝 Summary: What We Learned From Real Deployment

### **Key Takeaways**

1. **Services must expose the ports you want to use**
   - Just because a container listens on port 3000 doesn't mean the Service exposes it
   - Always check `kubectl get svc` to see what ports are available
   - Add ports to the Service YAML if missing

2. **Secrets must match actual credentials**
   - If a service can't connect to a database, check the secret
   - Use `kubectl get secret <name> -o jsonpath='{.data.<key>}' | base64 -d` to decode
   - Compare with actual database credentials

3. **Network policies can block connections**
   - Even if DNS resolves, network policies can block traffic
   - Test from the actual source pod (Prometheus) not just locally
   - Add network policies for each service Prometheus needs to scrape

4. **Prometheus config has rules**
   - `scrape_timeout` must be less than `scrape_interval`
   - Always set both explicitly for slow services
   - Default interval is 15s, so timeout must be < 15s if using defaults

5. **Debug systematically**
   - Start with logs
   - Test connectivity from different angles
   - Check configuration files
   - Fix one issue at a time

### **Commands Cheat Sheet**

```bash
# Check if service is running
kubectl get pods -n <namespace> -l app=<service>

# Check logs
kubectl logs -n <namespace> -l app=<service> --tail=50

# Test connectivity from inside pod
kubectl exec -n <namespace> <pod-name> -- curl http://service:port

# Check service ports
kubectl get svc <service-name> -n <namespace> -o yaml | grep -A 5 "ports:"

# Check network policies
kubectl get networkpolicy -n <namespace>

# Decode secret
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.<key>}' | base64 -d

# Test from Prometheus pod
kubectl exec -n monitoring $(kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}') -- wget -qO- --timeout=10 http://service.namespace.svc.cluster.local:port

# Update Prometheus config
kubectl create configmap prometheus-config -n monitoring \
  --from-file=prometheus.yml=k8s/monitoring/prometheus.yml \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl delete pod -n monitoring -l app=prometheus
```

### **What Fixed Each Issue**

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| api-gateway timeout | Service didn't expose port 3000 | Added port 3000 to service YAML |
| postgres-exporter timeout | Wrong password in secret | Updated secret with correct password from db-secrets |
| rabbitmq timeout | Service didn't expose port 15692 | Added port 15692 to service + network policy |
| Prometheus crash | timeout > interval | Set interval to 30s, timeout to 25s |

### **Time Spent Debugging**

- **api-gateway:** ~15 minutes (testing connectivity, checking service config)
- **postgres-exporter:** ~10 minutes (checking logs, comparing secrets)
- **rabbitmq:** ~10 minutes (checking plugin, service config)
- **Prometheus config:** ~5 minutes (reading error message, fixing config)

**Total:** ~40 minutes to fix all issues

**Lesson:** Systematic debugging is faster than guessing!

---

**Document Version:** 1.1  
**Last Updated:** January 14, 2026  
**Next Review:** After production deployment

