#!/usr/bin/env bash
set -euo pipefail

readonly SOPS_VERSION="3.13.2"
readonly AGE_KEY_PATH="/var/lib/agentops/age.key"
readonly ARGOCD_NAMESPACE="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

AGE_KEY_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --age-key-file)
      AGE_KEY_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: bootstrap.sh [--age-key-file <path>]"
      echo "Reads the platform age private key from stdin by default,"
      echo "or from --age-key-file if given. Never pass the key as a"
      echo "literal argument or bake it into this script."
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log() {
  echo "[bootstrap] $*" >&2
}

install_os_packages() {
  local apt_missing=()
  command -v curl >/dev/null 2>&1 || apt_missing+=(curl)
  command -v age >/dev/null 2>&1 || apt_missing+=(age)

  if [[ ${#apt_missing[@]} -gt 0 ]]; then
    log "Installing missing apt packages: ${apt_missing[*]}"
    apt-get update -y
    apt-get install -y "${apt_missing[@]}"
  else
    log "curl and age already installed"
  fi

  if command -v sops >/dev/null 2>&1; then
    log "sops already installed"
  else
    log "Installing sops ${SOPS_VERSION}"
    local arch deb tmp_dir
    arch="$(dpkg --print-architecture)"
    deb="sops_${SOPS_VERSION}_${arch}.deb"
    tmp_dir="$(mktemp -d)"
    curl -sfL -o "${tmp_dir}/${deb}" \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/${deb}"
    dpkg -i "${tmp_dir}/${deb}"
    rm -rf "${tmp_dir}"
  fi

  if command -v helm >/dev/null 2>&1; then
    log "helm already installed"
  else
    log "Installing helm"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    curl -fsSL -o "${tmp_dir}/get_helm.sh" \
      https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 "${tmp_dir}/get_helm.sh"
    "${tmp_dir}/get_helm.sh"
    rm -rf "${tmp_dir}"
  fi
}

tune_kernel_params() {
  # Grafana Alloy (loki.source.kubernetes, clusters/ops/platform/alloy) opens
  # one inotify instance per pod log tailer and has a known fd/instance leak
  # under high pod churn (grafana/alloy#1217). dev-agents spawns one ephemeral
  # Job pod per runAgent call, which exhausts the Ubuntu default of 128 user
  # instances within minutes and silently drops all Loki log collection
  # cluster-wide (every container logs "failed to create fsnotify watcher:
  # too many open files" instead of its real output). max_user_watches is
  # already well above default on this image, but bump it too for headroom.
  local conf=/etc/sysctl.d/99-agentops-inotify.conf
  if [[ -f "${conf}" ]]; then
    log "inotify sysctls already configured at ${conf}"
  else
    log "Raising fs.inotify limits for Alloy's per-pod log tailers"
    cat > "${conf}" <<'EOF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
EOF
    sysctl --system >/dev/null
  fi
}

install_k3s() {
  if command -v k3s >/dev/null 2>&1; then
    log "k3s already installed ($(k3s -v | head -n1))"
  else
    log "Installing k3s"
    curl -sfL https://get.k3s.io | sh -
  fi
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
}

wait_for_k3s() {
  log "Waiting for k3s API to become ready"
  local i
  for ((i = 1; i <= 60; i++)); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
      log "k3s API ready"
      return 0
    fi
    sleep 2
  done
  log "ERROR: k3s API did not become ready in time"
  exit 1
}

place_age_key() {
  if [[ -f "${AGE_KEY_PATH}" ]]; then
    log "Age key already present at ${AGE_KEY_PATH}, leaving it alone"
    return 0
  fi

  mkdir -p "$(dirname "${AGE_KEY_PATH}")"

  if [[ -n "${AGE_KEY_FILE}" ]]; then
    log "Reading age key from ${AGE_KEY_FILE}"
    install -m 0600 "${AGE_KEY_FILE}" "${AGE_KEY_PATH}"
  else
    log "Reading age key from stdin"
    (umask 077 && cat > "${AGE_KEY_PATH}")
  fi

  chown root:root "${AGE_KEY_PATH}"
  chmod 0600 "${AGE_KEY_PATH}"
  log "Age key placed at ${AGE_KEY_PATH}"
}

install_argocd() {
  log "Installing/upgrading ArgoCD with KSOPS-patched repo-server"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --create-namespace \
    --version 10.1.1 \
    -f "${SCRIPT_DIR}/argocd-values.yaml"

  log "Waiting for argocd-repo-server rollout"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-repo-server --timeout=300s

  if kubectl -n "${ARGOCD_NAMESPACE}" get secret sops-age >/dev/null 2>&1; then
    log "sops-age secret already exists"
  else
    log "Creating sops-age secret from ${AGE_KEY_PATH}"
    kubectl -n "${ARGOCD_NAMESPACE}" create secret generic sops-age \
      --from-file=key.txt="${AGE_KEY_PATH}"
  fi
}

apply_root_app() {
  log "Applying root-app.yaml"
  kubectl apply -f "${SCRIPT_DIR}/root-app.yaml"
}

main() {
  install_os_packages
  tune_kernel_params
  install_k3s
  wait_for_k3s
  place_age_key
  install_argocd
  apply_root_app
  log "Bootstrap complete. ArgoCD is reconciling clusters/ops from the root app."
}

main "$@"
