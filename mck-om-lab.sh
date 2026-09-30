#!/usr/bin/env bash
# mck-om-lab.sh
#
# One-command lab on a single EC2 host (Amazon Linux 2023, x86_64, >= 16 GiB RAM):
#   docker -> kind cluster -> MongoDB Controllers for Kubernetes (MCK) -> Ops Manager
#   -> a 3-member MongoDB Enterprise replica set managed by that Ops Manager.
# Versions and sizing live in config.env. No UI steps are needed.
#
# Usage:
#   ./mck-om-lab.sh          build the lab (re-runs itself with sudo; safe to run again)
#   ./mck-om-lab.sh status   show pods and resource phases
#   ./mck-om-lab.sh down     delete the kind cluster
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || { echo "Run this script as root." >&2; exit 1; }
  exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
fi

trap 'echo "ERROR: line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# sudo's secure_path omits /usr/local/bin, where kind, kubectl and helm are installed.
export PATH="/usr/local/bin:${PATH}"
set -a
# shellcheck source=config.env
source "${SCRIPT_DIR}/config.env"
set +a

LOG_FILE="${LOG_FILE:-/var/log/mck-om-lab.log}"
CREDS_FILE="/root/mck-om-credentials.txt"
OM_API="http://127.0.0.1:${OM_HOST_PORT}/api/public/v1.0"
OM_ADMIN_KEY_SECRET="${NAMESPACE}-${OM_NAME}-admin-key" # created by the operator once Ops Manager is up
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

# Only these variables are substituted into the templates under kind-config.yaml and manifests/.
# shellcheck disable=SC2016 # envsubst needs the literal ${VAR} names
TEMPLATE_VARS='${NAMESPACE} ${OM_NAME} ${OM_VERSION} ${OM_NODEPORT} ${OM_HOST_PORT} ${OM_HEAP} ${APPDB_VERSION}
  ${APPDB_STORAGE} ${MONGOD_CACHE_GB} ${RS_NAME} ${MDB_VERSION} ${RS_STORAGE}'

# Populated at runtime.
API_PUBLIC_KEY="" API_PRIVATE_KEY="" GROUP_ID="" ORG_ID="" PUBLIC_IP="" OM_ADMIN_PASSWORD=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo -e "\033[1;32m[mck-om-lab]\033[0m $*"; }
die() { echo "$*" >&2; exit 1; }
kc() { kubectl --namespace "$NAMESPACE" "$@"; }

# wait_for <label> <tries> <sleep-seconds> <command...>: retry until the command succeeds.
wait_for() {
  local label=$1 tries=$2 delay=$3 i
  shift 3
  for i in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    echo "  waiting for ${label} (${i}/${tries})"
    sleep "$delay"
  done
  return 1
}

# wait_for_phase <label> <kind> <name> <jsonpath> <tries> [hook]: wait until a CR status phase is Running.
# The optional hook (a function name) runs before every retry.
wait_for_phase() {
  local label=$1 kind=$2 name=$3 path=$4 tries=$5 hook=${6:-} i phase failed=0
  for i in $(seq 1 "$tries"); do
    phase=$(kc get "$kind" "$name" -o "jsonpath=${path}" 2>/dev/null || true)
    echo "  ${label}: ${phase:-pending} (${i}/${tries})"
    [ "$phase" = "Running" ] && return 0
    # The operator reports Failed while it retries, so give up only if it persists.
    if [ "$phase" = "Failed" ]; then failed=$((failed + 1)); else failed=0; fi
    if [ "$failed" -ge 8 ]; then diagnose; die "${label} has reported Failed for $((failed * 15))s"; fi
    if [ -n "$hook" ]; then "$hook"; fi
    sleep 15
  done
  diagnose
  die "${label} did not reach Running"
}

diagnose() {
  {
    echo "--- diagnostics ---"
    kc get pods,opsmanagers.mongodb.com,mongodb.mongodb.com 2>&1 | head -30
    kc describe opsmanagers.mongodb.com "$OM_NAME" 2>&1 | grep -A15 '^Status:'
    kc get events --sort-by=.lastTimestamp 2>&1 | tail -10 | cut -c1-300
    # Ops Manager names the failing pre-flight check just above this message.
    kc logs "${OM_NAME}-0" --previous --tail=400 2>/dev/null | grep -B10 'Pre-flight checks failed' | cut -c1-400 | tail -14
    kc logs deployment/mongodb-kubernetes-operator --tail=25 2>&1 | cut -c1-300
  } >&2 || true
}

# Ops Manager API call authenticated with the operator-created global API key.
om_api() { curl --fail-with-body -sS --digest -u "${API_PUBLIC_KEY}:${API_PRIVATE_KEY}" "$@"; }

# Render a template with only the lab's variables substituted.
render() { envsubst "$TEMPLATE_VARS" < "$1"; }
apply_manifest() { render "$1" | kubectl apply -f - >/dev/null; }

# ---------------------------------------------------------------------------
# Step 0: fail fast on an unsuitable host
# ---------------------------------------------------------------------------
reachable() {
  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$1" || true)
  [ -n "$code" ] && [ "$code" != "000" ]
}

check_host() {
  [ "$(uname -m)" = "x86_64" ] || die "x86_64 is required: the Ops Manager container image is linux/amd64 only."

  local mem_kb disk_gb url
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  if [ "$mem_kb" -lt 15000000 ] && [ "${SKIP_RESOURCE_CHECK:-0}" != "1" ]; then
    die "This lab needs about 16 GiB of RAM (found $((mem_kb / 1024 / 1024)) GiB). Set SKIP_RESOURCE_CHECK=1 to ignore."
  fi
  disk_gb=$(df -PBG / | awk 'NR==2 {gsub("G", "", $4); print $4}')
  if [ "$disk_gb" -lt 20 ] && [ "${SKIP_RESOURCE_CHECK:-0}" != "1" ]; then
    die "Only ${disk_gb} GiB of disk is free on /; the container images alone need about 15 GiB (50 GiB recommended)."
  fi

  for url in https://registry-1.docker.io/v2/ https://quay.io/v2/ https://dl.k8s.io https://kind.sigs.k8s.io \
    https://mongodb.github.io/helm-charts/index.yaml https://raw.githubusercontent.com https://downloads.mongodb.com; do
    reachable "$url" || die "Cannot reach ${url}. The host needs outbound internet access."
  done
}

# ---------------------------------------------------------------------------
# Step 1: Docker, kind, kubectl, helm
# ---------------------------------------------------------------------------
install_docker() {
  log "Installing and starting Docker"
  # curl is intentionally omitted: AL2023 ships curl-minimal, which conflicts with curl.
  dnf install -y docker git jq openssl gettext tar gzip >/dev/null
  systemctl enable --now docker
  docker info >/dev/null 2>&1 || die "Docker is installed but not responding"
  # kind nodes run many watchers; the default inotify limits are too low for them.
  sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 >/dev/null
}

install_binary() { # <name> <version> <url>
  log "Installing $1 $2"
  curl -fsSLo "/usr/local/bin/$1" "$3"
  chmod +x "/usr/local/bin/$1"
}

install_tools() {
  if ! { command -v kind >/dev/null && kind version | grep -q "${KIND_VERSION}"; }; then
    install_binary kind "$KIND_VERSION" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  fi
  if ! { command -v kubectl >/dev/null && kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; }; then
    install_binary kubectl "$KUBECTL_VERSION" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  fi
  if ! command -v helm >/dev/null; then
    log "Installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Step 2: kind cluster
# ---------------------------------------------------------------------------
create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    log "kind cluster '${KIND_CLUSTER_NAME}' already exists"
  else
    if ss -ltn | awk '{print $4}' | grep -q ":${OM_HOST_PORT}\$"; then
      die "Host port ${OM_HOST_PORT} is already in use; free it or set OM_HOST_PORT in config.env."
    fi
    local kind_config
    kind_config=$(mktemp)
    render "${SCRIPT_DIR}/kind-config.yaml" > "$kind_config"
    log "Creating kind cluster '${KIND_CLUSTER_NAME}' (${KIND_NODE_IMAGE})"
    kind create cluster --name "$KIND_CLUSTER_NAME" --config "$kind_config" --image "$KIND_NODE_IMAGE" --wait 180s
    rm -f "$kind_config"
  fi
  kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null
  kubectl get nodes -o wide
}

# ---------------------------------------------------------------------------
# Step 3: MCK operator (CRDs are part of the Helm chart)
# ---------------------------------------------------------------------------
install_operator() {
  log "Installing MCK ${MCK_VERSION} into namespace '${NAMESPACE}'"
  helm repo add mongodb https://mongodb.github.io/helm-charts --force-update >/dev/null
  helm repo update >/dev/null
  helm upgrade --install mongodb-kubernetes mongodb/mongodb-kubernetes \
    --namespace "$NAMESPACE" --create-namespace --version "$MCK_VERSION" \
    --set operator.watchNamespace="$NAMESPACE" --wait --timeout 5m >/dev/null
  kc get pods
}

# ---------------------------------------------------------------------------
# Step 4: Ops Manager (3-member Enterprise AppDB)
# ---------------------------------------------------------------------------
create_admin_secret() {
  if kc get secret ops-manager-admin-secret >/dev/null 2>&1; then
    log "Ops Manager admin secret already exists, keeping it"
    OM_ADMIN_PASSWORD=$(kc get secret ops-manager-admin-secret -o jsonpath='{.data.Password}' | base64 -d)
    return 0
  fi
  OM_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=')Aa1!"
  kc create secret generic ops-manager-admin-secret \
    --from-literal=Username="$OM_ADMIN_USER" --from-literal=Password="$OM_ADMIN_PASSWORD" \
    --from-literal=FirstName="Ops" --from-literal=LastName="Admin" >/dev/null
}

# A StatefulSet never replaces a pod that is not Ready, so a crash-looping Ops Manager pod keeps its old spec
# after the manifest is fixed. Delete it so it is recreated from the current revision.
recycle_stale_om_pod() {
  local pod="${OM_NAME}-0" pod_rev sts_rev reason
  pod_rev=$(kc get pod "$pod" -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || true)
  sts_rev=$(kc get statefulset "$OM_NAME" -o jsonpath='{.status.updateRevision}' 2>/dev/null || true)
  reason=$(kc get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
  if [ -n "$pod_rev" ] && [ -n "$sts_rev" ] && [ "$pod_rev" != "$sts_rev" ] && [ "$reason" = "CrashLoopBackOff" ]; then
    log "${pod} is crash-looping on an outdated spec; recreating it"
    kc delete pod "$pod" --wait=false >/dev/null
  fi
}

deploy_ops_manager() {
  log "Deploying Ops Manager ${OM_VERSION} with a 3-member Enterprise ${APPDB_VERSION} AppDB"
  apply_manifest "${SCRIPT_DIR}/manifests/ops-manager.yaml"
  # The AppDB reports Running only after Ops Manager is up (the operator then enables AppDB monitoring in it).
  log "Waiting for Ops Manager (image pull plus first-start data migration; several minutes)"
  wait_for_phase "Ops Manager" opsmanagers.mongodb.com "$OM_NAME" '{.status.opsManager.phase}' 90 recycle_stale_om_pod
  log "Waiting for the AppDB to finish enabling monitoring"
  wait_for_phase "AppDB" opsmanagers.mongodb.com "$OM_NAME" '{.status.applicationDatabase.phase}' 40
}

# ---------------------------------------------------------------------------
# Step 5: project and credentials for the operator, with no UI steps
# ---------------------------------------------------------------------------
admin_key_ready() {
  API_PUBLIC_KEY=$(kc get secret "$OM_ADMIN_KEY_SECRET" -o jsonpath='{.data.publicKey}' 2>/dev/null | base64 -d)
  API_PRIVATE_KEY=$(kc get secret "$OM_ADMIN_KEY_SECRET" -o jsonpath='{.data.privateKey}' 2>/dev/null | base64 -d)
  [ -n "$API_PUBLIC_KEY" ] && [ -n "$API_PRIVATE_KEY" ]
}

create_project_and_credentials() {
  log "Creating project '${PROJECT_NAME}' with the operator-created global API key"
  wait_for "operator admin key secret ${OM_ADMIN_KEY_SECRET}" 30 10 admin_key_ready \
    || die "Secret ${OM_ADMIN_KEY_SECRET} was not created by the operator"

  local project
  if ! project=$(om_api "${OM_API}/groups/byName/${PROJECT_NAME}" 2>/dev/null); then
    project=$(om_api --header "Content-Type: application/json" --request POST "${OM_API}/groups" \
      --data "$(jq -n --arg n "$PROJECT_NAME" '{name: $n}')")
  fi
  GROUP_ID=$(jq -r '.id' <<<"$project")
  ORG_ID=$(jq -r '.orgId' <<<"$project")
  [ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "null" ] || die "Could not create project: ${project}"
  log "Project id ${GROUP_ID}, organization id ${ORG_ID}"

  # The operator reads the project and API key from a ConfigMap and a Secret (same structure as its own admin key).
  kc create secret generic my-credentials \
    --from-literal=publicKey="$API_PUBLIC_KEY" --from-literal=privateKey="$API_PRIVATE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kc create configmap my-project \
    --from-literal=baseUrl="http://${OM_NAME}-svc.${NAMESPACE}.svc.cluster.local:8080" \
    --from-literal=projectName="$PROJECT_NAME" --from-literal=orgId="$ORG_ID" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# ---------------------------------------------------------------------------
# Step 6: 3-member MongoDB Enterprise replica set
# ---------------------------------------------------------------------------
goal_reached() {
  om_api "${OM_API}/groups/${GROUP_ID}/automationStatus" \
    | jq -e '(.processes | length) == 3 and ([.processes[].lastGoalVersionAchieved] | min) == .goalVersion' >/dev/null
}

deploy_replica_set() {
  log "Deploying ${RS_NAME}: 3 members, MongoDB Enterprise ${MDB_VERSION}"
  apply_manifest "${SCRIPT_DIR}/manifests/replica-set.yaml"
  wait_for_phase "${RS_NAME}" mongodb.mongodb.com "$RS_NAME" '{.status.phase}' 90
  wait_for "Ops Manager to report all 3 processes at goal state" 20 15 goal_reached \
    || die "The replica set processes did not reach the automation goal state"
}

# ---------------------------------------------------------------------------
# Step 7: credentials and summary
# ---------------------------------------------------------------------------
detect_public_ip() {
  local token
  token="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)"
  PUBLIC_IP="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: ${token}" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  [ -n "$PUBLIC_IP" ] || PUBLIC_IP="localhost"
}

print_summary() {
  detect_public_ip
  (umask 077; cat > "$CREDS_FILE" <<EOF
Ops Manager URL: http://${PUBLIC_IP}:${OM_HOST_PORT}
Username:        ${OM_ADMIN_USER}
Password:        ${OM_ADMIN_PASSWORD}
EOF
  )
  kc get pods
  cat <<EOF

===================================================================
MCK + Ops Manager lab is up (finished in $((SECONDS / 60)) min).

HOW TO LOG IN:
  1. Open http://${PUBLIC_IP}:${OM_HOST_PORT} (port ${OM_HOST_PORT} must be open in the security group)
     or tunnel: ssh -L ${OM_HOST_PORT}:localhost:${OM_HOST_PORT} <user>@${PUBLIC_IP}, then http://localhost:${OM_HOST_PORT}
  2. Username: ${OM_ADMIN_USER}
     Password: ${OM_ADMIN_PASSWORD}
  Also saved on this host at ${CREDS_FILE} (root-readable only).

  Kubernetes:   kind cluster '${KIND_CLUSTER_NAME}' (${KIND_NODE_IMAGE}), namespace '${NAMESPACE}'
  Operator:     MCK ${MCK_VERSION}
  Ops Manager:  ${OM_VERSION}, AppDB MongoDB Enterprise ${APPDB_VERSION} (3 members)
  Project:      ${PROJECT_NAME}
  Deployment:   ${RS_NAME}, MongoDB Enterprise ${MDB_VERSION} (3 members)

  Useful:  kubectl -n ${NAMESPACE} get om,mdb,pods
  Log:     ${LOG_FILE}
  Remove:  ./mck-om-lab.sh down
===================================================================
EOF
}

# ---------------------------------------------------------------------------
build() {
  # The log contains the generated admin password, so keep it readable by root only.
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Starting; output is also written to ${LOG_FILE}"
  check_host
  install_docker
  install_tools
  create_cluster
  install_operator
  create_admin_secret
  deploy_ops_manager
  create_project_and_credentials
  deploy_replica_set
  print_summary
}

main() {
  case "${1:-up}" in
    up) build ;;
    status) kc get pods,opsmanagers.mongodb.com,mongodb.mongodb.com ;;
    down)
      kind delete cluster --name "$KIND_CLUSTER_NAME"
      rm -f "$CREDS_FILE"
      ;;
    *) die "Usage: $0 [up|status|down]" ;;
  esac
}

# Run only when executed, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
