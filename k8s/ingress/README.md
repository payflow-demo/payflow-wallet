# PayFlow Ingress Configuration

> **Purpose**: Route external traffic to PayFlow services with HTTPS support

---

## Overview

**What is Ingress?**
- Ingress is a Kubernetes resource that manages external access to services
- Acts like a reverse proxy/router (similar to Nginx or Apache)
- Handles SSL/TLS termination (HTTPS → HTTP to services)
- Provides domain-based routing (api.payflow.local → API Gateway, www.payflow.local → Frontend)

**Why use Ingress?**
- ✅ **Single Entry Point**: One IP address for all services
- ✅ **HTTPS Support**: SSL/TLS certificates for secure connections
- ✅ **Domain Routing**: Different domains point to different services
- ✅ **Load Balancing**: Distributes traffic across multiple pods
- ✅ **Production-Ready**: Same setup works in production (EKS/AKS/GKE)

---

## Ingress Options

### 1. HTTP Ingress (Simple, No HTTPS)
**File**: `http-ingress.yaml`

**Use When**: 
- Quick local testing
- No HTTPS needed
- Simplest setup

**Access**:
- Frontend: `http://www.payflow.local`
- API: `http://api.payflow.local`

**Deploy**:
```bash
kubectl apply -f k8s/ingress/http-ingress.yaml
```

---

### 2. TLS Ingress with Self-Signed Certificate (Recommended for Local)
**File**: `tls-ingress-local.yaml`

**Use When**:
- Testing HTTPS locally
- Mimicking production setup
- Learning HTTPS flow

**Access**:
- Frontend: `https://www.payflow.local`
- API: `https://api.payflow.local`

**Setup Steps**:

#### Step 1: Generate Self-Signed Certificate
```bash
# Run the certificate generation script
cd k8s/ingress
./generate-tls-cert.sh
```

**What this does**:
- Creates `certs/tls.key` (private key - keep secret!)
- Creates `certs/tls.crt` (certificate - can be shared)
- Certificate valid for 365 days
- Includes both `www.payflow.local` and `api.payflow.local`

#### Step 2: Create Kubernetes Secret
```bash
kubectl create secret tls payflow-local-tls \
  --cert=k8s/ingress/certs/tls.crt \
  --key=k8s/ingress/certs/tls.key \
  -n payflow
```

**What this does**:
- Stores the certificate in Kubernetes (encrypted at rest)
- Ingress will use this secret for HTTPS

#### Step 3: Deploy TLS Ingress
```bash
kubectl apply -f k8s/ingress/tls-ingress-local.yaml
```

#### Step 4: Get Ingress IP
```bash
kubectl get ingress -n payflow
```

#### Step 5: Update /etc/hosts

**macOS/Linux**:
```bash
sudo nano /etc/hosts
# Add this line (replace <ingress-ip> with actual IP):
<ingress-ip> www.payflow.local api.payflow.local
```

**Windows**:
1. Open Notepad as Administrator
2. Open `C:\Windows\System32\drivers\etc\hosts`
3. Add this line (replace `<ingress-ip>` with actual IP):
   ```
   <ingress-ip> www.payflow.local api.payflow.local
   ```

#### Step 6: Access Application
- Frontend: `https://www.payflow.local`
- API: `https://api.payflow.local`

**⚠️ Browser Security Warning**:
- Browsers will show "Your connection is not private" warning
- This is **normal** for self-signed certificates
- Click "Advanced" → "Proceed to www.payflow.local (unsafe)"
- In production, you'd use Let's Encrypt (real certificates, no warnings)

---

### 3. TLS Ingress with Let's Encrypt (Production)
**File**: `tls-ingress-letsencrypt.yaml`

**Use When**:
- Production deployment (EKS/AKS/GKE)
- Real domain name (not .local)
- Need real SSL certificates (no browser warnings)

**Prerequisites**:
1. **cert-manager enabled**: `microk8s enable cert-manager`
2. **Real domain**: Must own a domain (e.g., `payflow.com`)
3. **DNS configured**: Domain must point to ingress IP/LoadBalancer
4. **Public access**: HTTP-01 challenge must be accessible from internet

**Setup Steps**:

#### Step 1: Enable cert-manager
```bash
microk8s enable cert-manager
```

#### Step 2: Update ClusterIssuer Email
Edit `tls-ingress-letsencrypt.yaml`:
```yaml
spec:
  acme:
    email: your-email@example.com  # ⚠️ Change this!
```

#### Step 3: Update Domain Names
Edit `tls-ingress-letsencrypt.yaml`:
```yaml
tls:
  - hosts:
    - api.yourdomain.com  # ⚠️ Change this!
    - www.yourdomain.com  # ⚠️ Change this!
```

#### Step 4: Deploy
```bash
kubectl apply -f k8s/ingress/tls-ingress-letsencrypt.yaml
```

**What happens**:
1. cert-manager creates ClusterIssuer
2. Ingress requests certificate from Let's Encrypt
3. Let's Encrypt validates domain ownership (HTTP-01 challenge)
4. Certificate is automatically issued and stored in `payflow-tls` secret
5. Certificate auto-renews before expiration (every 60 days)

**Access**:
- Frontend: `https://www.yourdomain.com`
- API: `https://api.yourdomain.com`

**No browser warnings!** ✅

---

## Understanding the Flow

### HTTP Request Flow (Local Development)
```
User Browser
    ↓
    http://www.payflow.local
    ↓
/etc/hosts (maps to ingress IP)
    ↓
Ingress Controller (Nginx)
    ↓
    Routes to: frontend service (port 80)
    ↓
Frontend Pod (Nginx serving React app)
```

### HTTPS Request Flow (Production-like)
```
User Browser
    ↓
    https://www.payflow.local
    ↓
/etc/hosts (maps to ingress IP)
    ↓
Ingress Controller (Nginx)
    ↓
    TLS Termination (decrypts HTTPS → HTTP)
    ↓
    Routes to: frontend service (port 80)
    ↓
Frontend Pod (Nginx serving React app)
```

**Key Point**: Services inside Kubernetes still use HTTP. Ingress handles HTTPS termination.

---

## Troubleshooting

### Issue: "Connection refused" or "This site can't be reached"

**Check**:
1. Ingress is running: `kubectl get ingress -n payflow`
2. Ingress has an IP: `kubectl get ingress payflow-local-ingress -n payflow -o wide`
3. /etc/hosts is correct: `cat /etc/hosts | grep payflow`
4. Services are running: `kubectl get svc -n payflow`

**Solution**:
```bash
# Check ingress status
kubectl describe ingress payflow-local-ingress -n payflow

# Check ingress controller
kubectl get pods -n ingress

# Verify services
kubectl get svc -n payflow
```

### Issue: "Your connection is not private" (Self-Signed Certificate)

**This is normal!** Self-signed certificates always show this warning.

**Solution**: Click "Advanced" → "Proceed to www.payflow.local (unsafe)"

**To avoid warnings**: Use Let's Encrypt (requires real domain)

### Issue: Certificate Secret Not Found

**Error**: `secret "payflow-local-tls" not found`

**Solution**:
```bash
# Regenerate certificate
cd k8s/ingress
./generate-tls-cert.sh

# Create secret
kubectl create secret tls payflow-local-tls \
  --cert=k8s/ingress/certs/tls.crt \
  --key=k8s/ingress/certs/tls.key \
  -n payflow
```

### Issue: Let's Encrypt Certificate Not Issuing

**Check**:
1. cert-manager is running: `kubectl get pods -n cert-manager`
2. Domain resolves to ingress IP: `nslookup api.yourdomain.com`
3. HTTP-01 challenge accessible: `curl http://api.yourdomain.com/.well-known/acme-challenge/test`

**Solution**:
```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check certificate status
kubectl get certificate -n payflow
kubectl describe certificate payflow-tls -n payflow
```

---

## Quick Reference

### Deploy HTTP Ingress (Simple)
```bash
kubectl apply -f k8s/ingress/http-ingress.yaml
```

### Deploy TLS Ingress (Local, Self-Signed)
```bash
# 1. Generate certificate
cd k8s/ingress && ./generate-tls-cert.sh

# 2. Create secret
kubectl create secret tls payflow-local-tls \
  --cert=k8s/ingress/certs/tls.crt \
  --key=k8s/ingress/certs/tls.key \
  -n payflow

# 3. Deploy ingress
kubectl apply -f k8s/ingress/tls-ingress-local.yaml

# 4. Get IP and update /etc/hosts
kubectl get ingress -n payflow
```

### Deploy TLS Ingress (Production, Let's Encrypt)
```bash
# 1. Enable cert-manager
microk8s enable cert-manager

# 2. Update email and domains in tls-ingress-letsencrypt.yaml

# 3. Deploy
kubectl apply -f k8s/ingress/tls-ingress-letsencrypt.yaml
```

### Check Ingress Status
```bash
# List all ingresses
kubectl get ingress -n payflow

# Detailed information
kubectl describe ingress payflow-local-ingress -n payflow

# Check ingress controller
kubectl get pods -n ingress
```

---

## Files in This Directory

- `http-ingress.yaml` - HTTP ingress (no TLS)
- `tls-ingress-local.yaml` - HTTPS with self-signed certificate (local)
- `tls-ingress-letsencrypt.yaml` - HTTPS with Let's Encrypt (production)
- `generate-tls-cert.sh` - Script to generate self-signed certificate
- `certs/` - Directory containing generated certificates (gitignored)
- `README.md` - This file

---

*Document created for PayFlow ingress configuration*  
*Last updated: December 25, 2025*

