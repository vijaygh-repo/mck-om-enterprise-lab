#!/usr/bin/env bash
# cleanup.sh - remove the lab from this host.
#
# Usage: ./cleanup.sh [--yes] [--purge]
#   (default)  delete the kind cluster (Ops Manager, the AppDB, the replica set and all their data),
#              the saved credentials, the log file and the kernel-settings file
#   --purge    also remove kind, kubectl, helm, their caches and the kind node image
#   --yes      do not ask for confirmation
# Docker and the base packages (git, jq, ...) are left installed; see the README to remove Docker too.
set -Eeuo pipefail

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || { echo "Run this script as root." >&2; exit 1; }
  exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# sudo's secure_path omits /usr/local/bin, where kind, kubectl and helm are installed.
export PATH="/usr/local/bin:${PATH}"
set -a
# shellcheck source=config.env
source "${SCRIPT_DIR}/config.env"
set +a

YES=0
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --yes | -y) YES=1 ;;
    --purge) PURGE=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

KIND_NODE="${KIND_CLUSTER_NAME}-control-plane"
LAB_FILES=("${LOG_FILE:-/var/log/mck-om-lab.log}" /root/mck-om-credentials.txt /etc/sysctl.d/99-mck-lab.conf)
TOOLS=(/usr/local/bin/kind /usr/local/bin/kubectl /usr/local/bin/helm)

log() { echo -e "\033[1;32m[cleanup]\033[0m $*"; }

confirm() {
  echo "This will remove:"
  echo "  - the kind cluster '${KIND_CLUSTER_NAME}' with Ops Manager, the AppDB, ${RS_NAME} and ALL their data"
  echo "  - ${LAB_FILES[*]}"
  if [ "$PURGE" = 1 ]; then
    echo "  - ${TOOLS[*]}, the helm caches and the image ${KIND_NODE_IMAGE}"
  fi
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || { echo "Not a terminal: pass --yes to confirm." >&2; exit 1; }
  read -r -p "Type 'delete' to continue: " answer
  [ "$answer" = "delete" ] || { echo "Nothing was removed."; exit 1; }
}

remove_cluster() {
  if command -v kind >/dev/null && kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    log "Deleting the kind cluster '${KIND_CLUSTER_NAME}'"
    kind delete cluster --name "$KIND_CLUSTER_NAME"
  elif command -v docker >/dev/null && docker inspect "$KIND_NODE" >/dev/null 2>&1; then
    log "Removing the kind node container ${KIND_NODE}"
    docker rm -f "$KIND_NODE" >/dev/null
  else
    log "No kind cluster '${KIND_CLUSTER_NAME}' found"
  fi
  if command -v kubectl >/dev/null; then
    kubectl config delete-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl config delete-cluster "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
    kubectl config unset "users.kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi
}

remove_files() {
  log "Removing saved credentials, log file and kernel settings"
  rm -f "${LAB_FILES[@]}"
}

purge_tools() {
  log "Removing kind, kubectl, helm and the kind node image"
  rm -f "${TOOLS[@]}"
  rm -rf /root/.config/helm /root/.cache/helm /root/.local/share/helm
  if command -v docker >/dev/null; then
    docker rmi "$KIND_NODE_IMAGE" >/dev/null 2>&1 || true
  fi
}

confirm
remove_cluster
remove_files
[ "$PURGE" = 0 ] || purge_tools
log "Done. The lab is removed."
echo "Docker and the base packages are still installed. To remove Docker as well:"
echo "  sudo systemctl disable --now docker && sudo dnf remove -y docker"
