#!/bin/bash
# =============================================================================
# PayFlow – One-shot MicroK8s deploy for beginners
# =============================================================================
# Installs MicroK8s if missing, enables addons, optionally builds/pushes images,
# deploys PayFlow (k8s/overlays/local).
#
# Platforms
# ---------
# • macOS  — Multipass + Homebrew microk8s installer; can auto-create microk8s-vm
#            and 0–3 worker VMs (Multipass), then join them to the cluster.
# • Linux  — MicroK8s via snap on the host (single-node in this script). Extra
#            workers are not auto-provisioned; use microk8s add-node manually.
# • Windows — Native Git Bash / CMD / PowerShell are NOT supported here. Use
#            WSL2 with Ubuntu (or another Linux distro): uname is Linux, so the
#            Linux path runs. Install Docker (Desktop WSL integration or docker.io
#            in WSL) and snap microk8s inside WSL, then run this script from bash
#            in that environment.
#
# Usage (from repo root):
#   ./scripts/deploy-microk8s.sh                    full deploy (prompts for build + worker count)
#   WORKER_COUNT=0 ./scripts/deploy-microk8s.sh       skip worker prompt (single-node)
#   ./scripts/deploy-microk8s.sh add-worker [NAME] [CPUS] [MEMORY_GB] [DISK_GB]
#                                                     add one Multipass worker (macOS); NAME defaults to next payflow-worker-N
#   ./scripts/deploy-microk8s.sh remove-workers       drain/remove payflow-worker-* nodes, purge VMs, delete payflow namespace
#
# Requires: Docker running (full deploy only). macOS also needs Multipass.
# =============================================================================
set -e

# -----------------------------------------------------------------------------
# Colours (printf-based — avoids echo -e portability issues on bash 3.2/macOS)
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Use unicode symbols inline
OK="${GREEN}✓${NC}"
ARROW="${BLUE}→${NC}"
WARN="${YELLOW}⚠${NC}"
CROSS="${RED}✗${NC}"

ok()   { printf "%b %s\n" "$OK"    "$*"; }
info() { printf "%b %s\n" "$ARROW" "$*"; }
warn() { printf "%b  %s\n" "$WARN"  "$*"; }
die()  { printf "%b %s\n" "$CROSS" "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Timeout command detection
# -----------------------------------------------------------------------------
# macOS uses `gtimeout` (brew install coreutils). Linux typically has `timeout`.
if command -v gtimeout > /dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout > /dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
else
  TIMEOUT_CMD=""
fi

# -----------------------------------------------------------------------------
# Resources — sized for 7 services + infra + full addon stack
# 1 control-plane + 3 workers, each 4 CPU / 6 GB RAM / 20 GB disk
# Total cluster: 16 CPU / 24 GB RAM
# -----------------------------------------------------------------------------
CONTROL_CPU="${CONTROL_CPU:-4}"
CONTROL_MEM_GB="${CONTROL_MEM_GB:-6}"
CONTROL_DISK_GB="${CONTROL_DISK_GB:-20}"

# Set only via env or the interactive prompt below (freshers choose 0–3 workers).
WORKER_CPU=4
WORKER_MEM_GB=6
WORKER_DISK_GB=20

DOCKER_REGISTRY="localhost:32000"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Subcommands (skip full deploy prompts; macOS Multipass only for worker ops)
DEPLOY_MODE="full"
ADD_WORKER_VM=""
ADD_WORKER_CPU=""
ADD_WORKER_MEM_GB=""
ADD_WORKER_DISK_GB=""
case "${1:-}" in
  add-worker)
    DEPLOY_MODE="add-worker"
    shift
    ADD_WORKER_VM="${1:-}"
    ADD_WORKER_CPU="${2:-2}"
    ADD_WORKER_MEM_GB="${3:-4}"
    ADD_WORKER_DISK_GB="${4:-20}"
    ;;
  remove-workers)
    DEPLOY_MODE="remove-workers"
    shift
    ;;
  help|-h|--help)
    printf '%s\n' \
      "Usage: ./scripts/deploy-microk8s.sh [add-worker [NAME] [CPUS] [MEM_GB] [DISK_GB] | remove-workers | help]" \
      "  (no args)       — full PayFlow deploy to MicroK8s" \
      "  add-worker      — create one worker VM and join cluster (macOS Multipass)" \
      "  remove-workers  — remove payflow-worker-* from cluster, purge VMs, delete namespace payflow" \
      "  WORKER_COUNT=N  — set in environment to skip worker-count prompt on full deploy"
    exit 0
    ;;
esac

if [ "$DEPLOY_MODE" != "full" ] && [ "$(uname -s)" != "Darwin" ]; then
  die "Subcommands add-worker and remove-workers require macOS with Multipass."
fi

# Space-separated list — no arrays with inline comments (bash 3.2 macOS compat)
SERVICES="api-gateway auth-service wallet-service transaction-service notification-service frontend"

printf "\n${BLUE}=============================================================${NC}\n"
case "$DEPLOY_MODE" in
  add-worker)  printf "${BLUE}   PayFlow – MicroK8s add worker${NC}\n" ;;
  remove-workers) printf "${BLUE}   PayFlow – MicroK8s remove workers${NC}\n" ;;
  *)           printf "${BLUE}   PayFlow – MicroK8s 4-node cluster deploy${NC}\n" ;;
esac
printf "${BLUE}=============================================================${NC}\n\n"

# -----------------------------------------------------------------------------
# 1) Prompt: build and push images?
# -----------------------------------------------------------------------------
if [ "$DEPLOY_MODE" != "full" ]; then
  DO_BUILD=false
  PUSH_HUB=false
  DOCKER_USER=""
  DOCKERHUB_TAG=""
  WORKER_COUNT=0
  ok "Mode: ${DEPLOY_MODE} — skipping image-build prompts"
else
printf "${YELLOW}Do you want to build and push Docker images before deploying?${NC}\n"
printf "  (Answer no to skip — useful if images are already in the registry)\n\n"
printf "  Build and push images? [y/N]: "
read -r BUILD_ANSWER
BUILD_ANSWER="$(printf '%s' "$BUILD_ANSWER" | tr '[:upper:]' '[:lower:]')"

DO_BUILD=false
PUSH_HUB=false
DOCKER_USER=""
DOCKERHUB_TAG=""

case "$BUILD_ANSWER" in
  y|yes)
    DO_BUILD=true
    printf "\n  Where should images be pushed?\n"
    printf "    registry  — local MicroK8s registry (%s)\n" "$DOCKER_REGISTRY"
    printf "    dockerhub — Docker Hub (you will need to be logged in)\n\n"
    printf "  registry or dockerhub? [registry/dockerhub]: "
    read -r PUSH_TARGET
    PUSH_TARGET="$(printf '%s' "$PUSH_TARGET" | tr '[:upper:]' '[:lower:]')"
    case "$PUSH_TARGET" in
      dockerhub)
        PUSH_HUB=true
        printf "  Docker Hub username: "
        read -r DOCKER_USER
        [ -n "$DOCKER_USER" ] || die "Docker Hub username is required. Re-run and enter a username."
        DOCKERHUB_TAG="$(git rev-parse --short HEAD 2>/dev/null || printf 'build-%s' "$(date +%s)")"
        info "Images will be tagged ${DOCKER_USER}/<service>:${DOCKERHUB_TAG} and pushed to Docker Hub"
        ;;
      *)
        info "Images will be pushed to local registry at ${DOCKER_REGISTRY}/<service>:latest"
        ;;
    esac
    ;;
  *)
    ok "Skipping image build — using existing images"
    ;;
esac

printf "\n"

# -----------------------------------------------------------------------------
# 1b) Prompt: how many Multipass worker VMs? (macOS — still spins up workers; skip only if already in cluster)
# -----------------------------------------------------------------------------
if [ -z "${WORKER_COUNT+set}" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    printf "${YELLOW}MicroK8s worker nodes${NC} are extra Multipass VMs that join your cluster so pods have more CPU/RAM.\n"
    printf "  ${GREEN}0${NC} — control-plane only (simplest; best on smaller Macs)\n"
    printf "  ${GREEN}1–3${NC} — add workers (more capacity; each worker needs several GB RAM)\n"
    printf "  ${GREEN}Enter${NC} — default ${GREEN}3${NC} workers (full multi-node walkthrough)\n\n"
  else
    printf "${YELLOW}Worker nodes${NC} — on Linux (and WSL2), this script only manages a ${GREEN}single${NC} MicroK8s node.\n"
    printf "  Extra workers are ${GREEN}not${NC} created automatically; use ${GREEN}microk8s add-node${NC} on the host if you need a multi-node cluster.\n"
    printf "  ${GREEN}0${NC} — single-node (recommended on Linux / WSL2)\n"
    printf "  ${GREEN}1–3${NC} — same single-node run; the number is ignored for provisioning (macOS-only Multipass workers)\n\n"
  fi
  printf "  How many workers? [0-3, default 3; macOS=Multipass VMs, Linux/WSL=ignored for auto-join]: "
  read -r WC_ANSWER
  WC_ANSWER="$(printf '%s' "${WC_ANSWER:-3}" | tr -d '[:space:]')"
  case "$WC_ANSWER" in
    0) WORKER_COUNT=0 ;;
    1|2|3) WORKER_COUNT="$WC_ANSWER" ;;
    '') WORKER_COUNT=3 ;;
    *) warn "Unrecognized input — using 3 workers"; WORKER_COUNT=3 ;;
  esac
  ok "Using WORKER_COUNT=${WORKER_COUNT} (set WORKER_COUNT in the environment next time to skip this question)"
fi

printf "\n"

fi

# -----------------------------------------------------------------------------
# 2) Check Docker (full deploy only — add-worker/remove-workers do not need Docker)
# -----------------------------------------------------------------------------
if [ "$DEPLOY_MODE" = "full" ]; then
  command -v docker > /dev/null 2>&1 \
    || die "Docker not found. Install Docker Desktop or Docker Engine then re-run."
  docker info > /dev/null 2>&1 \
    || die "Docker daemon is not running. Start Docker then re-run."
  ok "Docker is available"
fi

# -----------------------------------------------------------------------------
# 3) Install MicroK8s if not present
# -----------------------------------------------------------------------------
install_microk8s_mac() {
  # On macOS the control plane lives in Multipass 'microk8s-vm'. The Homebrew `microk8s` binary
  # is only the installer CLI — having it on PATH does NOT mean the VM exists (e.g. after
  # `multipass delete --purge microk8s-vm`). Always key off the VM first.
  if multipass list --format csv 2>/dev/null | grep -q "^microk8s-vm,"; then
    ok "MicroK8s VM (microk8s-vm) already present"
    return 0
  fi

  # No control-plane VM — need the installer CLI, then microk8s install creates microk8s-vm.
  if ! command -v microk8s > /dev/null 2>&1; then
    info "MicroK8s CLI not on PATH — installing via Homebrew..."
    command -v brew > /dev/null 2>&1 \
      || die "Homebrew is required on macOS. Install from https://brew.sh then re-run."
    brew install ubuntu/microk8s/microk8s
  else
    ok "MicroK8s CLI on PATH — creating control-plane VM (none in Multipass yet)"
  fi

  info "Creating control-plane VM (${CONTROL_CPU} CPU, ${CONTROL_MEM_GB}GB RAM, ${CONTROL_DISK_GB}GB disk)..."
  microk8s install \
    --cpu="$CONTROL_CPU" \
    --memory="$CONTROL_MEM_GB" \
    --disk="$CONTROL_DISK_GB"
  ok "MicroK8s control-plane VM created"
}

install_microk8s_linux() {
  if command -v microk8s > /dev/null 2>&1; then
    ok "MicroK8s already installed"
    return 0
  fi
  info "MicroK8s not found — installing via snap..."
  sudo snap install microk8s --classic
  sudo usermod -a -G microk8s "$USER"
  ok "MicroK8s installed."
  ok "Log out and back in (or run: newgrp microk8s), then re-run this script."
  exit 0
}

OS="$(uname -s)"
case "$OS" in
  MINGW*|MSYS*|CYGWIN*)
    die "Native Windows shells are not supported (OS reports: ${OS}). Use WSL2 + Ubuntu: install Docker and MicroK8s inside WSL, open bash there, clone the repo, run ./scripts/deploy-microk8s.sh — see docs/microk8s-deployment.md (Platforms)."
    ;;
esac

case "$OS" in
  Darwin)
    command -v multipass > /dev/null 2>&1 \
      || die "Multipass is required on macOS. Install: brew install multipass"
    install_microk8s_mac
    # Always proxy into microk8s-vm (brew CLI alone is inconsistent for add-node / status after a fresh install).
    microk8s() { multipass exec microk8s-vm -- sudo microk8s "$@"; }
    ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      ok "WSL2 detected — using Linux MicroK8s path (ensure Docker reaches this distro: Docker Desktop → Resources → WSL integration)"
    fi
    install_microk8s_linux
    ;;
  *)
    die "Unsupported OS: ${OS}. Supported: macOS (Darwin), Linux (including WSL2). Windows: use WSL2 — see script header and docs/microk8s-deployment.md."
    ;;
esac

# -----------------------------------------------------------------------------
# 4) Ensure control-plane VM is running (macOS only)
# -----------------------------------------------------------------------------
if [ "$OS" = "Darwin" ]; then
  if multipass list --format csv 2>/dev/null | grep -q "microk8s-vm,Stopped"; then
    info "Starting MicroK8s VM..."
    multipass start microk8s-vm
    sleep 5
  fi
fi

info "Waiting for MicroK8s control-plane to be ready..."
microk8s status --wait-ready
ok "Control-plane ready"

# -----------------------------------------------------------------------------
# kubeconfig from the real control plane (macOS: Multipass + sudo inside VM)
# -----------------------------------------------------------------------------
#
# On macOS, `microk8s config` on the host can fail or be unreliable; the
# canonical kubeconfig is produced inside microk8s-vm. On Linux/WSL2, use the
# host snap as usual.
#
# Also: Multipass VM IP can change across restarts — always refresh so kubectl
# points at the correct API server (avoids stale 192.168.64.x timeouts).
refresh_microk8s_kubeconfig() {
  mkdir -p "${HOME}/.kube"
  if [ "$OS" = "Darwin" ] && multipass list --format csv 2>/dev/null | grep -q "^microk8s-vm,"; then
    multipass exec microk8s-vm -- sudo microk8s config > "${HOME}/.kube/microk8s-config" \
      || die "Failed to write kubeconfig. Try: multipass exec microk8s-vm -- sudo microk8s status"
  else
    microk8s config > "${HOME}/.kube/microk8s-config" \
      || die "Failed to write kubeconfig (microk8s config)"
  fi
  export KUBECONFIG="${HOME}/.kube/microk8s-config"
}

# Tear down Multipass payflow-worker-* VMs and PayFlow workloads (macOS). Safe to re-run.
# MicroK8s creates one-off hostpath "mkdir" pods with nodeSelector kubernetes.io/hostname=<node>.
# After a worker node is removed, those pods stay Pending and can confuse storage provisioning.
delete_orphan_kube_system_node_selector_pods() {
  local valid pname nh
  valid="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')"
  while IFS="$(printf '\t')" read -r pname nh; do
    [ -n "$pname" ] || continue
    [ -n "$nh" ] || continue
    echo "$valid" | grep -qx "$nh" && continue
    info "Deleting orphan kube-system pod ${pname} (nodeSelector hostname=${nh} — node no longer exists)..."
    kubectl delete pod "$pname" -n kube-system --ignore-not-found 2>/dev/null || true
  done <<EOF
$(kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeSelector.kubernetes\.io/hostname}{"\n"}{end}' 2>/dev/null)
EOF
}

remove_payflow_workers_mac() {
  info "Removing payflow-worker-* Kubernetes nodes and Multipass VMs..."
  k_nodes=""
  if command -v kubectl > /dev/null 2>&1; then
    k_nodes="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep '^payflow-worker-' || true)"
  fi
  vms="$(multipass list --format csv 2>/dev/null | awk -F, 'NR>1 && $1 ~ /^payflow-worker-/ {print $1}' | tr '\n' ' ')"

  for node in $k_nodes; do
    info "Draining ${node}..."
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --grace-period=15 --timeout=180s 2>/dev/null \
      || warn "  drain ${node} had issues (continuing)"
  done

  for vm in $vms; do
    if multipass list --format csv 2>/dev/null | grep -q "^${vm},Running,"; then
      multipass exec "$vm" -- sudo microk8s leave 2>/dev/null || true
    fi
  done

  for node in $k_nodes; do
    multipass exec microk8s-vm -- sudo microk8s remove-node "$node" --force 2>/dev/null || true
    kubectl delete node "$node" --ignore-not-found 2>/dev/null || true
  done

  for vm in $vms; do
    info "Purging Multipass VM ${vm}..."
    multipass delete "$vm" --purge 2>/dev/null || true
  done

  delete_orphan_kube_system_node_selector_pods

  info "Deleting namespace payflow (if present)..."
  kubectl delete namespace payflow --ignore-not-found --wait=false 2>/dev/null || true
  ok "remove-workers finished. If payflow was deleting, wait until: kubectl get ns payflow (NotFound)"
}

# -----------------------------------------------------------------------------
# 5) KUBECONFIG — set early so kubectl works for worker checks and addons
# -----------------------------------------------------------------------------
info "Writing kubeconfig for kubectl (refreshed from control plane)..."
refresh_microk8s_kubeconfig
ok "KUBECONFIG=$KUBECONFIG"

if [ "$DEPLOY_MODE" = "remove-workers" ]; then
  remove_payflow_workers_mac
  exit 0
fi

# -----------------------------------------------------------------------------
# 6) Spin up and join worker nodes (macOS via Multipass)
# -----------------------------------------------------------------------------

# Polls until microk8s snap is installed AND the daemon is ready inside a VM.
# Avoids the "install-snap change in progress" join error from the previous run.
wait_for_worker_ready() {
  NODE="$1"
  info "Waiting for MicroK8s to be ready on ${NODE}..."
  attempt=0
  while [ "$attempt" -lt 40 ]; do
    attempt=$((attempt + 1))
    if multipass exec "$NODE" -- test -x /snap/bin/microk8s 2>/dev/null; then
      if multipass exec "$NODE" -- sudo microk8s status --wait-ready 2>/dev/null; then
        ok "${NODE} is ready"
        return 0
      fi
    fi
    if [ "$attempt" -eq 1 ] || [ $((attempt % 6)) -eq 0 ]; then
      warn "  still waiting on ${NODE} (attempt ${attempt}/40, up to ~6 min total)..."
    fi
    sleep 10
  done
  warn "Timed out waiting for MicroK8s on ${NODE}. Check: multipass exec ${NODE} -- sudo snap changes"
  return 1
}

# Launch a worker VM (cloud-init installs microk8s). Returns 0 on success.
# WORKER_SNAP_CHANNEL must match microk8s-vm's snap tracking (see spin_up_workers_mac).
launch_worker_vm() {
  NODE="$1"
  ch="${WORKER_SNAP_CHANNEL:-latest/stable}"
  case "$ch" in
    '' | *[!a-zA-Z0-9._/-]*)
      warn "Invalid WORKER_SNAP_CHANNEL '${ch}' — using latest/stable"
      ch="latest/stable"
      ;;
  esac
  multipass launch \
    --name "$NODE" \
    --cpus "$WORKER_CPU" \
    --memory "${WORKER_MEM_GB}G" \
    --disk "${WORKER_DISK_GB}G" \
    --cloud-init - \
    22.04 \
    <<CLOUDINIT
#cloud-config
packages:
  - snapd
runcmd:
  - snap install microk8s --classic --channel=${ch}
  - usermod -a -G microk8s ubuntu
CLOUDINIT
}

# Worker VM already running MicroK8s as a cluster node (re-runs: do not join again).
worker_vm_reports_joined() {
  NODE="$1"
  multipass exec "$NODE" -- sudo microk8s status 2>/dev/null | grep -qi "acting as a node in a cluster"
}

fetch_worker_snap_channel_mac() {
  multipass exec microk8s-vm -- bash -lc \
    "snap list microk8s --color=never 2>/dev/null | awk '/^microk8s[[:space:]]/ {print \$4; exit}'" 2>/dev/null || true
}

get_join_command_mac() {
  multipass exec microk8s-vm -- sudo microk8s add-node --format short 2>/dev/null | head -n 1
}

# Max ~4 minutes per node (CNI/kubelet can be slow right after join).
wait_kubectl_node_ready() {
  NODE="$1"
  max_attempts="${2:-48}"
  info "Waiting for Kubernetes node ${NODE} to be Ready (up to ~$((max_attempts * 5 / 60)) min)..."
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    st="$(kubectl get node "$NODE" --no-headers 2>/dev/null | awk '{print $2}' || true)"
    if [ "$st" = "Ready" ]; then
      ok "${NODE} is Ready"
      return 0
    fi
    if [ "$attempt" -eq 1 ] || [ $((attempt % 12)) -eq 0 ]; then
      warn "  ${NODE} status=${st:-unknown} (attempt ${attempt}/${max_attempts})..."
    fi
    sleep 5
  done
  warn "${NODE} not Ready after ~$((max_attempts * 5 / 60))m — check: kubectl describe node ${NODE}"
  return 1
}

# Join token always comes from the control-plane VM (reliable on macOS Multipass).
join_worker_node_mac() {
  NODE="$1"
  JOIN_CMD="$(get_join_command_mac)"
  [ -n "$JOIN_CMD" ] || die "Could not get join command from microk8s-vm (is the control plane healthy?)"
  info "Joining ${NODE} to cluster..."
  multipass exec "$NODE" -- sudo $JOIN_CMD --worker
  wait_kubectl_node_ready "$NODE" \
    || die "Worker ${NODE} did not become Ready after join. Try: kubectl describe node ${NODE} — or remove-workers and re-run with matching MicroK8s snap channel."
}

spin_up_workers_mac() {
  # Refresh kubeconfig so kubectl sees the real API IP (Multipass IP can change).
  # Without this, kubectl get node fails and the script wrongly tries to join every time.
  refresh_microk8s_kubeconfig

  WORKER_SNAP_CHANNEL="$(fetch_worker_snap_channel_mac)"
  if [ -z "$WORKER_SNAP_CHANNEL" ]; then
    warn "Could not read MicroK8s snap tracking on microk8s-vm; workers will use latest/stable."
    warn "  If that mismatches the control plane, use WORKER_COUNT=0 or fix the VM, then re-run."
    WORKER_SNAP_CHANNEL="latest/stable"
  else
    info "Worker VMs will install MicroK8s --channel=${WORKER_SNAP_CHANNEL} (matches control plane)"
  fi

  i=1
  while [ "$i" -le "$WORKER_COUNT" ]; do
    NODE="payflow-worker-${i}"

    # Re-runs / manual setup: node already registered — no create, wait, or join.
    if kubectl get node "$NODE" > /dev/null 2>&1; then
      ok "${NODE} already in cluster — skipping create/join"
      i=$((i + 1))
      continue
    fi

    if ! multipass list --format csv 2>/dev/null | grep -q "^${NODE},"; then
      info "Creating ${NODE} (${WORKER_CPU} CPU, ${WORKER_MEM_GB}GB RAM, ${WORKER_DISK_GB}GB disk)..."
      created=false
      attempt=0
      while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        if launch_worker_vm "$NODE"; then
          ok "VM ${NODE} created"
          created=true
          break
        fi
        warn "  multipass launch failed (attempt ${attempt}/3; often cloud-init/host load). Waiting 45s before retry..."
        multipass delete "$NODE" --purge 2>/dev/null || true
        sleep 45
      done
      if [ "$created" != true ]; then
        warn "Could not create ${NODE} after 3 tries (e.g. 'timed out waiting for initialization')."
        warn "  Fix: free CPU/RAM, or run with fewer workers: WORKER_COUNT=$((i - 1)) (current partial workers kept)."
        warn "  Or remove a stuck VM: multipass delete ${NODE} --purge"
        i=$((i + 1))
        continue
      fi
    else
      ok "VM ${NODE} already exists — skipping creation"
      if multipass list --format csv 2>/dev/null | grep -q "^${NODE},Stopped,"; then
        info "Starting stopped VM ${NODE}..."
        multipass start "$NODE" || warn "  multipass start ${NODE} had issues — check: multipass list"
        sleep 5
      fi
    fi

    # Wait for snap to be fully settled before joining
    if ! wait_for_worker_ready "$NODE"; then
      warn "  ${NODE} never became ready — skipping join. Try: multipass exec ${NODE} -- sudo snap changes"
      i=$((i + 1))
      continue
    fi

    if kubectl get node "$NODE" > /dev/null 2>&1; then
      ok "${NODE} already in cluster — skipping join"
    elif worker_vm_reports_joined "$NODE"; then
      ok "${NODE} MicroK8s already reports cluster member — skipping join (if kubectl was wrong, run: multipass exec microk8s-vm -- sudo microk8s config > ~/.kube/microk8s-config && export KUBECONFIG=\$HOME/.kube/microk8s-config)"
    else
      join_worker_node_mac "$NODE"
      ok "${NODE} join step completed"
    fi

    i=$((i + 1))
  done
}

# Block full deploy until every expected worker is registered and Ready (macOS Multipass).
verify_payflow_workers_ready_mac() {
  [ "$WORKER_COUNT" -gt 0 ] || return 0
  info "Confirming ${WORKER_COUNT} worker node(s) are joined and Ready before continuing..."
  i=1
  while [ "$i" -le "$WORKER_COUNT" ]; do
    NODE="payflow-worker-${i}"
    if ! kubectl get node "$NODE" > /dev/null 2>&1; then
      die "Worker ${NODE} is not in the cluster (kubectl get nodes). Re-run remove-workers, fix Multipass/join, or use WORKER_COUNT=0."
    fi
    if ! wait_kubectl_node_ready "$NODE"; then
      die "Worker ${NODE} is not Ready — aborting deploy before addons/app. Fix the node or run WORKER_COUNT=0. Hint: kubectl describe node ${NODE}"
    fi
    i=$((i + 1))
  done
  ok "All ${WORKER_COUNT} worker(s) joined and Ready"
}

add_payflow_worker_mac() {
  VM="${ADD_WORKER_VM}"
  if [ -z "$VM" ]; then
    n=1
    while multipass list --format csv 2>/dev/null | grep -q "^payflow-worker-${n},"; do
      n=$((n + 1))
    done
    VM="payflow-worker-${n}"
  fi
  if multipass list --format csv 2>/dev/null | grep -q "^${VM},"; then
    die "Multipass VM '${VM}' already exists. Pick another name or: multipass delete ${VM} --purge"
  fi

  refresh_microk8s_kubeconfig
  WORKER_SNAP_CHANNEL="$(fetch_worker_snap_channel_mac)"
  if [ -z "$WORKER_SNAP_CHANNEL" ]; then
    warn "Could not read MicroK8s snap tracking on microk8s-vm; using latest/stable."
    WORKER_SNAP_CHANNEL="latest/stable"
  else
    info "Worker will use MicroK8s --channel=${WORKER_SNAP_CHANNEL} (matches control plane)"
  fi

  WORKER_CPU="$ADD_WORKER_CPU"
  WORKER_MEM_GB="$ADD_WORKER_MEM_GB"
  WORKER_DISK_GB="$ADD_WORKER_DISK_GB"

  info "Creating ${VM} (${WORKER_CPU} CPU, ${WORKER_MEM_GB}GB RAM, ${WORKER_DISK_GB}GB disk)..."
  launch_worker_vm "$VM" || die "multipass launch failed for ${VM}"
  wait_for_worker_ready "$VM" || die "MicroK8s did not become ready on ${VM}"

  if kubectl get node "$VM" > /dev/null 2>&1; then
    ok "${VM} already registered in the cluster"
  elif worker_vm_reports_joined "$VM"; then
    ok "${VM} already reports cluster membership"
  else
    join_worker_node_mac "$VM"
  fi

  printf "\n"
  info "Cluster nodes:"
  kubectl get nodes -o wide
  ok "add-worker complete: ${VM}"
}

if [ "$DEPLOY_MODE" = "add-worker" ]; then
  add_payflow_worker_mac
  exit 0
fi

spin_up_workers_linux() {
  warn "Automatic worker provisioning on Linux/WSL2 is not implemented (macOS Multipass only)."
  warn "To add workers: on the control plane run 'microk8s add-node' and join each node manually."
  warn "Continuing as single-node..."
}

if [ "$WORKER_COUNT" -gt 0 ]; then
  printf "\n"
  info "Setting up ${WORKER_COUNT} worker node(s)..."
  case "$OS" in
    Darwin)
      spin_up_workers_mac
      verify_payflow_workers_ready_mac
      ;;
    Linux) spin_up_workers_linux ;;
  esac
  printf "\n"
  info "Cluster nodes:"
  kubectl get nodes
  printf "\n"
else
  info "WORKER_COUNT=0 — running single-node (skipping worker setup)"
fi

# -----------------------------------------------------------------------------
# 7) Enable addons
#
# IMPORTANT — no inline comments inside shell lists or variable assignments.
# bash 3.2 (default on macOS) misparses them and throws syntax errors.
# Each addon is enabled individually with error handling.
# -----------------------------------------------------------------------------

# Waits for the ingress namespace to fully terminate before enabling the addon.
# This prevents the "namespaces ingress not found" race that occurs after reset.
wait_ingress_ns_gone() {
  if ! kubectl get ns ingress > /dev/null 2>&1; then
    return 0
  fi

  attempt=0
  while [ "$attempt" -lt 18 ]; do
    attempt=$((attempt + 1))
    if ! kubectl get ns ingress > /dev/null 2>&1; then
      return 0
    fi
    warn "  ingress namespace still terminating — waiting 10s (attempt ${attempt}/18)..."
    sleep 10
  done
  warn "  ingress namespace did not terminate cleanly — attempting enable anyway"
}

# MicroK8s control-plane runs inside microk8s-vm on macOS — use a real binary under timeout.
microk8s_runs_in_multipass_vm() {
  multipass list --format csv 2>/dev/null | grep -q "^microk8s-vm,"
}

patch_metrics_server() {
  if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    return 0
  fi

  if kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
    | grep -q -- '--kubelet-insecure-tls'; then
    return 0
  fi

  info "  Patching metrics-server for local kubelet scraping..."
  PATCH=$(printf '%s' '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP"}]')
  kubectl patch deployment metrics-server -n kube-system --type=json -p "$PATCH" >/dev/null 2>&1 \
    || warn "  metrics-server patch failed — you may need to patch it manually"
}

# Use multipass exec directly (real binary) so pipeline subshells on
# macOS bash 3.2 don't drop the microk8s shell function wrapper.
# Bash 3.2 does not support nested function definitions (syntax error),
# so this helper must live at the top level, not inside enable_addon.
microk8s_status_output() {
  if microk8s_runs_in_multipass_vm; then
    multipass exec microk8s-vm -- sudo microk8s status 2>/dev/null
  else
    microk8s status 2>/dev/null
  fi
}

enable_addon() {
  TIMEOUT_SECS=90
  ADDON="$1"
  rc=0
  info "  Enabling: ${ADDON}"

  # Check if addon is already enabled before calling `microk8s enable`.
  if microk8s_status_output | awk '
      $1=="enabled:" { in_enabled=1; next }
      $1=="disabled:" { in_enabled=0 }
      in_enabled==1 && $1 ~ /^[a-z0-9-]+$/ { print $1 }
    ' | grep -qx "$ADDON"; then
    ok "  ${ADDON} (already enabled)"
    return 0
  fi

  if [ "$ADDON" = "ingress" ]; then
    wait_ingress_ns_gone
  fi

  attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    # Capture stdout+stderr so failures are visible. Print output immediately via printf.
    # `&& rc=0 || rc=$?` is the only set -e-safe exit-code capture pattern.
    if [ -n "$TIMEOUT_CMD" ]; then
      if microk8s_runs_in_multipass_vm; then
        addon_out=$( $TIMEOUT_CMD "$TIMEOUT_SECS" multipass exec microk8s-vm -- sudo microk8s enable "$ADDON" 2>&1 ) && rc=0 || rc=$?
      else
        addon_out=$( $TIMEOUT_CMD "$TIMEOUT_SECS" microk8s enable "$ADDON" 2>&1 ) && rc=0 || rc=$?
      fi
    else
      warn "  No timeout command available. Install coreutils on macOS: brew install coreutils"
      addon_out=$( microk8s enable "$ADDON" 2>&1 ) && rc=0 || rc=$?
    fi
    [ -n "$addon_out" ] && printf '%s\n' "$addon_out"
    if [ "$rc" -eq 0 ]; then
      ok "  ${ADDON}"
      return 0
    fi
    warn "  ${ADDON} failed (exit ${rc}): attempt ${attempt}/3 — retrying in 10s..."
    sleep 10
  done
  warn "  ${ADDON} skipped after 3 attempts — enable manually: multipass exec microk8s-vm -- sudo microk8s enable ${ADDON}"
}

printf "\n"
info "Enabling addons..."

# Core — required for PayFlow
enable_addon dns
enable_addon hostpath-storage
enable_addon registry
enable_addon ingress
enable_addon metrics-server

patch_metrics_server

enable_addon rbac

# RBAC restarts the API server — wait for it to come back before proceeding.
# Without this, microk8s enable observability hangs immediately because the
# cluster is not yet accepting requests.
info "  Waiting for API server to recover after RBAC restart..."
sleep 15
microk8s status --wait-ready || warn "  API server slow to recover after RBAC — continuing anyway"
ok "  API server ready after RBAC"

# Observability stack (Prometheus + Grafana + Alertmanager + Loki + Tempo)
# Optional — PayFlow works without it. Defaults to skip (prompt) to avoid
# a 10-min hang on first deploy.
# Override: INSTALL_OBSERVABILITY=true ./scripts/deploy-microk8s.sh
#           INSTALL_OBSERVABILITY=false ./scripts/deploy-microk8s.sh
if [ -z "${INSTALL_OBSERVABILITY+set}" ]; then
  printf "\n"
  printf "  ${YELLOW}Install observability?${NC} (Prometheus + Grafana + Loki + Tempo)\n"
  printf "  Takes 5-10 min to download. ${GREEN}PayFlow runs fine without it.${NC}\n"
  printf "  Add it later:  multipass exec microk8s-vm -- sudo microk8s enable observability\n\n"
  printf "  Install now? [y/N]: "
  read -r OBS_ANSWER
  case "$(printf '%s' "${OBS_ANSWER:-n}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    y|yes) INSTALL_OBSERVABILITY=true ;;
    *)     INSTALL_OBSERVABILITY=false ;;
  esac
fi

if [ "$INSTALL_OBSERVABILITY" = "true" ]; then
  # Use kubectl (real binary) for the already-enabled check.
  # microk8s is a shell function; pipeline subshells on macOS bash 3.2
  # don't reliably inherit functions, so `microk8s status | awk` silently
  # returns nothing and the check always falls through to re-enable.
  if kubectl get namespace observability >/dev/null 2>&1; then
    ok "  observability (already enabled)"
  else
    info "  Enabling: observability (5-10 min — output streams below)..."
    rc=0
    set +e
    if [ -n "$TIMEOUT_CMD" ]; then
      if microk8s_runs_in_multipass_vm; then
        $TIMEOUT_CMD 600 multipass exec microk8s-vm -- sudo microk8s enable observability
        rc=$?
      else
        $TIMEOUT_CMD 600 microk8s enable observability
        rc=$?
      fi
    else
      microk8s enable observability
      rc=$?
    fi
    set -e
    if [ "$rc" -eq 0 ]; then
      ok "  observability"
      info "  Waiting for API server to recover after observability install..."
      sleep 15
      microk8s status --wait-ready || warn "  API server slow to recover — continuing anyway"
    else
      warn "  observability failed (exit ${rc})"
      warn "  Add later: multipass exec microk8s-vm -- sudo microk8s enable observability"
    fi
  fi
else
  ok "  observability skipped — add later: multipass exec microk8s-vm -- sudo microk8s enable observability"
fi

# Extras
enable_addon dashboard
enable_addon helm3
enable_addon cert-manager

ok "All addons enabled"

# -----------------------------------------------------------------------------
# 8) Build and push images
# -----------------------------------------------------------------------------
if [ "$DO_BUILD" = true ]; then
  printf "\n"

  # Use a reproducible tag (git SHA) instead of :latest so rollouts are explicit.
  # Falls back to timestamp when not in a git repo (or git not available).
  IMAGE_TAG="$(git rev-parse --short HEAD 2>/dev/null || printf 'build-%s' "$(date +%s)")"

  if [ "$PUSH_HUB" = false ]; then
    IMAGE_PREFIX="${DOCKER_REGISTRY}"
    if microk8s_runs_in_multipass_vm; then
      # On macOS + Multipass, Docker on the host cannot reach localhost:32000 (that port
      # lives inside the VM, not on the Mac's loopback). docker push fails with i/o timeout.
      # Instead: build tagged as localhost:32000/<svc>:<tag>, save to a tar stream, and
      # pipe it into the VM's containerd via `ctr image import`. No registry, no network.
      info "Building images and importing into MicroK8s containerd (tag: ${IMAGE_TAG})..."
    else
      info "Building images and pushing to local registry (${DOCKER_REGISTRY}) (tag: ${IMAGE_TAG})..."
      attempt=0
      while [ "$attempt" -lt 6 ]; do
        attempt=$((attempt + 1))
        if curl -sf "http://${DOCKER_REGISTRY}/v2/" > /dev/null 2>&1; then
          break
        fi
        warn "  Registry not reachable yet — waiting 10s (attempt ${attempt}/6)..."
        sleep 10
      done
    fi
  else
    DOCKERHUB_TAG="$IMAGE_TAG"
    info "Building images and pushing to Docker Hub (tag: ${IMAGE_TAG})..."
    IMAGE_PREFIX="${DOCKER_USER}"
  fi

  for SERVICE in $SERVICES; do
    SERVICE_DIR="services/${SERVICE}"
    if [ ! -f "${SERVICE_DIR}/Dockerfile" ]; then
      warn "No Dockerfile at ${SERVICE_DIR}/Dockerfile — skipping ${SERVICE}"
      continue
    fi

    # Skip if the image is already present in the destination.
    # Saves time on reruns — only rebuilds what changed.
    if [ "$PUSH_HUB" = false ] && microk8s_runs_in_multipass_vm; then
      FULL_IMAGE="${DOCKER_REGISTRY}/${SERVICE}:${IMAGE_TAG}"
      if multipass exec microk8s-vm -- sudo microk8s ctr image ls 2>/dev/null \
          | grep -qF "$FULL_IMAGE"; then
        ok "  ${SERVICE} already in containerd at ${IMAGE_TAG} — skipping"
        continue
      fi
    fi

    info "  Building ${SERVICE}..."
    # --provenance=false disables Docker Desktop's BuildKit attestation manifest.
    # Without it, `docker save` produces a manifest list that `ctr image import`
    # cannot ingest (unexpected EOF). Plain image = single manifest = importable.
    # Build with ./services as context so shared/ is included (matches docker compose builds).
    if [ "$PUSH_HUB" = false ]; then
      docker build --provenance=false \
        -t "${DOCKER_REGISTRY}/${SERVICE}:${IMAGE_TAG}" \
        -f "${SERVICE_DIR}/Dockerfile" ./services
    else
      docker build --provenance=false \
        -t "${DOCKER_USER}/${SERVICE}:${IMAGE_TAG}" \
        -f "${SERVICE_DIR}/Dockerfile" ./services
    fi

    if [ "$PUSH_HUB" = false ]; then
      if microk8s_runs_in_multipass_vm; then
        # `multipass exec` pipes through a thin SSH channel that truncates large
        # binary stdin streams (unexpected EOF). Use multipass transfer instead:
        # save to a temp file on the Mac, transfer the file to the VM, import, clean up.
        info "  Importing ${SERVICE} into containerd (via file transfer)..."
        _TMPTAR="$(mktemp /tmp/payflow-${SERVICE}-XXXXXX.tar)"
        docker save "${DOCKER_REGISTRY}/${SERVICE}:${IMAGE_TAG}" > "$_TMPTAR"
        multipass transfer "$_TMPTAR" "microk8s-vm:/tmp/${SERVICE}-import.tar"
        multipass exec microk8s-vm -- sudo microk8s ctr image import "/tmp/${SERVICE}-import.tar"
        multipass exec microk8s-vm -- rm -f "/tmp/${SERVICE}-import.tar"
        rm -f "$_TMPTAR"
        # Push from the control-plane's containerd into the registry pod so
        # worker nodes can pull. --plain-http required: local registry is HTTP.
        multipass exec microk8s-vm -- \
          sudo microk8s ctr image push --plain-http \
          "${DOCKER_REGISTRY}/${SERVICE}:${IMAGE_TAG}"
        # Use ASCII -> instead of Unicode arrow: bash 3.2 multibyte lexer bug
        # misreads \x92 (last byte of UTF-8 arrow) when ( ) also appear on the
        # same line, causing "syntax error near unexpected token ')'".
        ok "  ${SERVICE} -> registry ${DOCKER_REGISTRY}/${SERVICE}:${IMAGE_TAG}"
      else
        docker push "${DOCKER_REGISTRY}/${SERVICE}:${IMAGE_TAG}"
        ok "  ${SERVICE} -> local registry ${DOCKER_REGISTRY}/${SERVICE}:${IMAGE_TAG}"
      fi
    else
      docker push "${DOCKER_USER}/${SERVICE}:${IMAGE_TAG}"
      ok "  ${SERVICE} -> Docker Hub ${DOCKER_USER}/${SERVICE}:${IMAGE_TAG}"
    fi
  done

  ok "All images built and loaded"
fi

# -----------------------------------------------------------------------------
# 9) Deploy PayFlow
# -----------------------------------------------------------------------------
printf "\n"
info "Deploying PayFlow (k8s/overlays/local)..."
kubectl apply -k k8s/overlays/local

# If we built images, update ONLY the local overlay to the exact tag and re-apply.
# This avoids relying on :latest and does not affect EKS/AKS overlays.
if [ "$DO_BUILD" = true ]; then
  printf "\n"
  info "Updating local overlay images to tag ${IMAGE_TAG}..."

  # Only rewrite the local overlay. EKS/AKS overlays remain unchanged.
  (
    cd k8s/overlays/local || exit 1
    # kustomize edit is the safest way to update images without manual YAML surgery.
    # It will add/update the images: block in this kustomization.yaml only.
    for SERVICE in $SERVICES; do
      kustomize edit set image "veeno/${SERVICE}=${IMAGE_PREFIX}/${SERVICE}:${IMAGE_TAG}" >/dev/null 2>&1 \
        && ok "  ${SERVICE} → ${IMAGE_PREFIX}/${SERVICE}:${IMAGE_TAG}" \
        || warn "  Failed to set image for ${SERVICE} in local overlay"
    done
  )

  info "Re-applying local overlay with updated images..."
  kubectl apply -k k8s/overlays/local

  info "Waiting for rollouts..."
  for SERVICE in $SERVICES; do
    kubectl -n payflow rollout status "deployment/${SERVICE}" --timeout=180s >/dev/null 2>&1 || true
  done
fi

# -----------------------------------------------------------------------------
# 9.1) Self-heal: hostpath PV node-affinity mismatch (local-only)
# -----------------------------------------------------------------------------
# In local student environments, MicroK8s hostpath PVs are pinned to the node
# hostname that first consumed the PVC. If the cluster is recreated and node
# names change, Postgres/Redis can get stuck Pending with:
#   "didn't match PersistentVolume's node affinity"
# This preflight detects that specific failure mode and automatically recreates
# the affected PVCs, then restarts the workloads.
get_pod_scheduling_message() {
  NS="$1"
  POD="$2"
  kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .status.conditions[?(@.type=="PodScheduled")]}{.message}{"\n"}{end}' 2>/dev/null
}

self_heal_hostpath_affinity() {
  NS="payflow"
  # Only relevant for our local MicroK8s overlay
  if [ ! -d "k8s/overlays/local" ]; then
    return 0
  fi

  NEED_HEAL=false

  POSTGRES_MSG="$(get_pod_scheduling_message "$NS" "postgres-0" || true)"
  if printf '%s' "$POSTGRES_MSG" | grep -q "didn't match PersistentVolume's node affinity"; then
    NEED_HEAL=true
  fi

  REDIS_POD="$(kubectl get pods -n "$NS" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$REDIS_POD" ]; then
    REDIS_MSG="$(get_pod_scheduling_message "$NS" "$REDIS_POD" || true)"
    if printf '%s' "$REDIS_MSG" | grep -q "didn't match PersistentVolume's node affinity"; then
      NEED_HEAL=true
    fi
  fi

  if [ "$NEED_HEAL" != "true" ]; then
    return 0
  fi

  warn "Detected local hostpath PV node-affinity mismatch. Recreating Postgres/Redis PVCs..."

  if kubectl get statefulset postgres -n "$NS" >/dev/null 2>&1; then
    info "  Postgres: scaling down, recreating PVC, scaling up..."
    kubectl scale statefulset postgres -n "$NS" --replicas=0 >/dev/null 2>&1 || true
    kubectl delete pvc -n "$NS" postgres-storage-postgres-0 >/dev/null 2>&1 || true
    kubectl scale statefulset postgres -n "$NS" --replicas=1 >/dev/null 2>&1 || true
  fi

  if kubectl get deployment redis -n "$NS" >/dev/null 2>&1; then
    info "  Redis: recreating PVC and restarting deployment..."
    kubectl delete pvc -n "$NS" redis-pvc >/dev/null 2>&1 || true
    kubectl rollout restart deployment/redis -n "$NS" >/dev/null 2>&1 || true
  fi

  ok "Self-heal applied. Continuing deployment..."
}

self_heal_hostpath_affinity

# -----------------------------------------------------------------------------
# 9.2) Self-heal: JWT secret drift (local-only)
# -----------------------------------------------------------------------------
# Pods don't automatically restart when a Secret changes, so it's possible to end
# up with auth-service signing tokens with the current JWT_SECRET while the
# api-gateway is still verifying with an older value. That breaks all protected
# routes (wallets/transactions) after login.
sha256_or_empty() {
  # Reads stdin, prints sha256 hash, or empty if input empty
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    # Worst case: no hash tool. Return empty (skip drift check).
    cat >/dev/null
    printf ""
  fi
}

self_heal_jwt_secret_drift() {
  NS="payflow"
  if ! kubectl get secret -n "$NS" db-secrets >/dev/null 2>&1; then
    return 0
  fi
  if ! kubectl get deployment -n "$NS" api-gateway >/dev/null 2>&1; then
    return 0
  fi

  SECRET_HASH="$(kubectl get secret -n "$NS" db-secrets -o jsonpath='{.data.JWT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null | sha256_or_empty || true)"
  [ -n "$SECRET_HASH" ] || return 0

  # Pick one pod (deployment is homogeneous); compare runtime env JWT_SECRET to current Secret
  POD="$(kubectl get pods -n "$NS" -l app=api-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$POD" ] || return 0

  POD_HASH="$(kubectl exec -n "$NS" "$POD" -- sh -c 'if [ -n "$JWT_SECRET" ]; then echo -n "$JWT_SECRET" | (sha256sum 2>/dev/null || shasum -a 256) | awk "{print \\$1}"; fi' 2>/dev/null || true)"

  if [ -n "$POD_HASH" ] && [ "$POD_HASH" != "$SECRET_HASH" ]; then
    warn "Detected api-gateway JWT_SECRET drift vs db-secrets. Restarting api-gateway pods..."
    kubectl rollout restart deployment/api-gateway -n "$NS" >/dev/null 2>&1 || true
    ok "api-gateway restarted to pick up current JWT_SECRET"
  fi
}

self_heal_jwt_secret_drift

printf "\n"
info "Waiting for infrastructure pods..."
kubectl wait --for=condition=ready pod -l app=postgres  -n payflow --timeout=180s \
  || warn "postgres not ready — check: kubectl describe pod -l app=postgres -n payflow"
kubectl wait --for=condition=ready pod -l app=redis     -n payflow --timeout=120s \
  || warn "redis not ready — check: kubectl describe pod -l app=redis -n payflow"
kubectl wait --for=condition=ready pod -l app=rabbitmq  -n payflow --timeout=120s \
  || warn "rabbitmq not ready — check: kubectl describe pod -l app=rabbitmq -n payflow"

info "Waiting for DB migration to complete..."
kubectl wait --for=condition=complete job/db-migration-job -n payflow --timeout=180s \
  || warn "DB migration incomplete — check: kubectl logs job/db-migration-job -n payflow"

printf "\n"
info "Waiting for application services..."
kubectl wait --for=condition=ready pod -l app=api-gateway          -n payflow --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=auth-service         -n payflow --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=wallet-service       -n payflow --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=transaction-service  -n payflow --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=notification-service -n payflow --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=frontend             -n payflow --timeout=180s || true

printf "\n"
info "Cluster nodes:"
kubectl get nodes
printf "\n"
info "Pod status:"
kubectl get pods -n payflow

# -----------------------------------------------------------------------------
# 10) Done
# -----------------------------------------------------------------------------
printf "\n"
printf "${GREEN}=============================================================${NC}\n"
printf "${GREEN}   PayFlow deployed!${NC}\n"
printf "${GREEN}=============================================================${NC}\n\n"
printf "  Access the app:\n\n"
printf "  A) Port-forward (no /etc/hosts setup needed):\n"
printf "       kubectl port-forward service/frontend 8080:80 -n payflow &\n"
printf "       Open: http://localhost:8080\n\n"
printf "  B) Ingress (hostname routing):\n"
printf "       ./scripts/setup-hosts-payflow-local.sh\n"
printf "       Open: http://www.payflow.local\n\n"
printf "  Grafana (observability):\n"
printf "       kubectl port-forward -n observability svc/kube-prom-stack-grafana 3000:80 &\n"
printf "       Open: http://localhost:3000  (admin / prom-operator)\n\n"
printf "  Kubernetes dashboard:\n"
printf "       microk8s dashboard-proxy\n\n"
printf "  Useful commands:\n"
printf "       kubectl get pods -n payflow            # service health\n"
printf "       kubectl get pods -n observability      # monitoring stack\n"
printf "       kubectl logs -f <pod> -n payflow       # tail a log\n"
printf "       kubectl top pods -n payflow            # resource usage\n\n"
printf "  Tear down:\n"
printf "       ./scripts/teardown-microk8s.sh\n\n"
