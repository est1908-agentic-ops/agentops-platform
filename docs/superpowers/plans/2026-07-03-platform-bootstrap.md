# Platform Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fresh Linux host (or VPS on first boot) runs `bootstrap.sh` once and ends up with k3s + ArgoCD installed, ArgoCD able to decrypt SOPS/age secrets, and watching this repo's `clusters/ops` path — after which ArgoCD reconciles everything else with no further manual `kubectl apply`.

**Architecture:** One idempotent, checks-before-acting shell script (`bootstrap/bootstrap.sh`) with five ordered steps (OS packages → k3s → age key → ArgoCD w/ KSOPS → root app), a `bootstrap/cloud-init.yaml` that embeds the same script for first-boot VPS provisioning, a checked-in `bootstrap/argocd-values.yaml` pinning the KSOPS repo-server patch, and completed `bootstrap/root-app.yaml` / `.sops.yaml`.

**Tech Stack:** Bash (target: Ubuntu/Debian LTS), `shellcheck` for static analysis, YAML (Helm values, cloud-init, ArgoCD `Application`), Python 3 + PyYAML for local YAML-syntax verification. No new application-code dependency — this is infra scripting, not the TS monorepo.

**Design doc:** `docs/superpowers/specs/2026-07-03-platform-bootstrap-design.md`

**Note on "tests" for this plan:** the design doc's own Testing Strategy is explicit — "No unit tests — this is shell script + YAML manifests, not application code." Verification here is `shellcheck` (real, automated, added to CI) plus a manual dry run on a throwaway VM (real commands given in Task 11, but not something CI or an agent can execute without a real host). Every task's "Test" step is the closest real, runnable equivalent: `shellcheck` for the script, a Python/PyYAML syntax check for the YAML files.

**Known gap fixed vs. the design doc:** the design doc's OS-packages step (Step 1) doesn't mention `helm`, but Step 4 (ArgoCD install) requires it. This plan installs `helm` alongside `curl`/`age`/`sops` in Task 1 — a correction needed for the script to actually work, not a scope change.

**Unresolved external fact:** the real git clone URL for this repo doesn't exist yet (confirmed with the user — no remote configured). `bootstrap/root-app.yaml` and `bootstrap/cloud-init.yaml` use the literal token `<AGENTOPS_PLATFORM_GIT_URL>` — Task 6 and Task 7 call this out explicitly; whoever runs this against a real cluster must replace it first.

---

### Task 1: `bootstrap/bootstrap.sh` — scaffold + OS packages step

**Files:**
- Create: `bootstrap/bootstrap.sh`
- Test: shellcheck (no unit test framework applies to shell scripts in this repo)

- [ ] **Step 1: Write `bootstrap/bootstrap.sh` with the OS-packages step**

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly SOPS_VERSION="3.13.2"

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

main() {
  install_os_packages
}

main "$@"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x bootstrap/bootstrap.sh
```

- [ ] **Step 3: Verify it's shellcheck-clean**

Run: `shellcheck bootstrap/bootstrap.sh`
(If `shellcheck` isn't installed: `brew install shellcheck` on macOS, `apt-get install -y shellcheck` on Linux — GitHub's `ubuntu-latest` runners have it preinstalled, so CI in Task 8 needs no install step.)
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add bootstrap/bootstrap.sh
git commit -m "feat(bootstrap): OS packages step (curl, age, sops, helm)"
```

---

### Task 2: `bootstrap/bootstrap.sh` — k3s install step

**Files:**
- Modify: `bootstrap/bootstrap.sh`
- Test: shellcheck

- [ ] **Step 1: Add the k3s install + readiness-wait functions**

Insert these two functions between `install_os_packages()` and `main()`:

```bash
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
  for i in $(seq 1 60); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
      log "k3s API ready"
      return 0
    fi
    sleep 2
  done
  log "ERROR: k3s API did not become ready in time"
  exit 1
}
```

- [ ] **Step 2: Wire both into `main()`**

Replace:
```bash
main() {
  install_os_packages
}
```
with:
```bash
main() {
  install_os_packages
  install_k3s
  wait_for_k3s
}
```

- [ ] **Step 3: Verify shellcheck is still clean**

Run: `shellcheck bootstrap/bootstrap.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add bootstrap/bootstrap.sh
git commit -m "feat(bootstrap): k3s install + readiness wait"
```

---

### Task 3: `bootstrap/bootstrap.sh` — age key placement step

**Files:**
- Modify: `bootstrap/bootstrap.sh`
- Test: shellcheck

- [ ] **Step 1: Add argument parsing and the age-key constant**

Replace the top of the file (after `set -euo pipefail`):
```bash
readonly SOPS_VERSION="3.13.2"
```
with:
```bash
readonly SOPS_VERSION="3.13.2"
readonly AGE_KEY_PATH="/var/lib/agentops/age.key"

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
```

- [ ] **Step 2: Add the `place_age_key` function**

Insert between `wait_for_k3s()` and `main()`:

```bash
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
```

- [ ] **Step 3: Wire it into `main()`**

Replace:
```bash
main() {
  install_os_packages
  install_k3s
  wait_for_k3s
}
```
with:
```bash
main() {
  install_os_packages
  install_k3s
  wait_for_k3s
  place_age_key
}
```

- [ ] **Step 4: Verify shellcheck is still clean**

Run: `shellcheck bootstrap/bootstrap.sh`
Expected: no output, exit code 0.
(Note: the argument-parsing loop runs before `main "$@"` at the bottom of the file — this is intentional so `-h`/`--help` works even if a future step needs to exit early before `main` runs.)

- [ ] **Step 5: Commit**

```bash
git add bootstrap/bootstrap.sh
git commit -m "feat(bootstrap): age key placement (stdin or --age-key-file)"
```

---

### Task 4: `bootstrap/argocd-values.yaml` — KSOPS-patched repo-server

**Files:**
- Create: `bootstrap/argocd-values.yaml`
- Test: Python/PyYAML syntax check (no cluster/Helm needed to validate this is well-formed YAML)

- [ ] **Step 1: Write the file**

```yaml
# ArgoCD Helm values — KSOPS-patched repo-server so ArgoCD can decrypt
# SOPS/age-encrypted resources in this repo before applying them.
# Ref: https://github.com/viaduct-ai/kustomize-sops
configs:
  cm:
    kustomize.buildOptions: "--enable-alpha-plugins --enable-exec --enable-helm"

repoServer:
  volumes:
    - name: custom-tools
      emptyDir: {}
  initContainers:
    - name: install-ksops
      image: viaductoss/ksops:v4.5.1
      command: ["/usr/local/bin/ksops", "install", "--with-kustomize", "/custom-tools"]
      volumeMounts:
        - mountPath: /custom-tools
          name: custom-tools
  volumeMounts:
    - mountPath: /usr/local/bin/kustomize
      name: custom-tools
      subPath: kustomize
    - mountPath: /usr/local/bin/ksops
      name: custom-tools
      subPath: ksops
```

- [ ] **Step 2: Verify it's valid YAML**

If PyYAML isn't installed yet: `pip3 install --user pyyaml`

Run:
```bash
python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1])); print('OK')" bootstrap/argocd-values.yaml
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add bootstrap/argocd-values.yaml
git commit -m "feat(bootstrap): ArgoCD KSOPS repo-server Helm values"
```

---

### Task 5: `bootstrap/bootstrap.sh` — ArgoCD install step

**Files:**
- Modify: `bootstrap/bootstrap.sh`
- Test: shellcheck

- [ ] **Step 1: Add the `ARGOCD_NAMESPACE`/`SCRIPT_DIR` constants**

Replace:
```bash
readonly SOPS_VERSION="3.13.2"
readonly AGE_KEY_PATH="/var/lib/agentops/age.key"
```
with:
```bash
readonly SOPS_VERSION="3.13.2"
readonly AGE_KEY_PATH="/var/lib/agentops/age.key"
readonly ARGOCD_NAMESPACE="argocd"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- [ ] **Step 2: Add the `install_argocd` function**

Insert between `place_age_key()` and `main()`:

```bash
install_argocd() {
  if helm status argocd -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    log "ArgoCD already installed"
  else
    log "Installing ArgoCD with KSOPS-patched repo-server"
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
    helm repo update argo >/dev/null
    helm install argocd argo/argo-cd \
      --namespace "${ARGOCD_NAMESPACE}" \
      --create-namespace \
      --version 10.1.1 \
      -f "${SCRIPT_DIR}/argocd-values.yaml"
  fi

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
```

Chart version pinned (`10.1.1`, latest stable as of this plan) per the design doc's own mitigation for the KSOPS-fragility risk ("pinning exact chart/image versions... checked in, reviewable") — an unpinned `helm install` would install whatever the latest chart happens to be on each fresh bootstrap, undermining the "rebuild from git, get the same result" guarantee this whole script exists for.

- [ ] **Step 3: Wire it into `main()`**

Replace:
```bash
main() {
  install_os_packages
  install_k3s
  wait_for_k3s
  place_age_key
}
```
with:
```bash
main() {
  install_os_packages
  install_k3s
  wait_for_k3s
  place_age_key
  install_argocd
}
```

- [ ] **Step 4: Verify shellcheck is still clean**

Run: `shellcheck bootstrap/bootstrap.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add bootstrap/bootstrap.sh
git commit -m "feat(bootstrap): ArgoCD install + sops-age secret"
```

---

### Task 6: `bootstrap/root-app.yaml` completed + apply step

**Files:**
- Modify: `bootstrap/root-app.yaml`
- Modify: `bootstrap/bootstrap.sh`
- Test: shellcheck (script) + Python/PyYAML syntax check (manifest)

- [ ] **Step 1: Complete `root-app.yaml`**

Current content:
```yaml
# ArgoCD app-of-apps entrypoint — to be completed during M2 (docs/BOOTSTRAP.md step 4).
# Applied once manually; afterwards ArgoCD manages everything, including itself.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<agentops-platform repo URL — set during M2>"
    targetRevision: main
    path: clusters/ops
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Replace with:
```yaml
# ArgoCD app-of-apps entrypoint. Applied once by bootstrap.sh;
# afterwards ArgoCD manages everything, including itself.
#
# <AGENTOPS_PLATFORM_GIT_URL> is a placeholder — replace it with this
# repo's real clone URL before running bootstrap.sh against a real
# cluster. Not decided as of this plan being written (no git remote
# configured yet for this repo).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
    targetRevision: main
    path: clusters/ops
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Add the `apply_root_app` function to `bootstrap.sh`**

Insert between `install_argocd()` and `main()`:

```bash
apply_root_app() {
  log "Applying root-app.yaml"
  kubectl apply -f "${SCRIPT_DIR}/root-app.yaml"
}
```

- [ ] **Step 3: Wire it into `main()`**

Replace:
```bash
main() {
  install_os_packages
  install_k3s
  wait_for_k3s
  place_age_key
  install_argocd
}
```
with:
```bash
main() {
  install_os_packages
  install_k3s
  wait_for_k3s
  place_age_key
  install_argocd
  apply_root_app
  log "Bootstrap complete. ArgoCD is reconciling clusters/ops from the root app."
}
```

- [ ] **Step 4: Verify both files**

```bash
shellcheck bootstrap/bootstrap.sh
python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1])); print('OK')" bootstrap/root-app.yaml
```
Expected: shellcheck prints nothing (exit 0); PyYAML check prints `OK`.

- [ ] **Step 5: Commit**

```bash
git add bootstrap/root-app.yaml bootstrap/bootstrap.sh
git commit -m "feat(bootstrap): complete root-app.yaml, apply it from bootstrap.sh"
```

---

### Task 7: `bootstrap/cloud-init.yaml` — first-boot VPS wrapper

**Files:**
- Create: `bootstrap/cloud-init.yaml`
- Test: Python/PyYAML syntax check

By this point `bootstrap/bootstrap.sh` is complete (Tasks 1–6). This task embeds its final content verbatim into `write_files`, per the design doc ("embedding `bootstrap.sh` verbatim").

- [ ] **Step 1: Write the file**

```yaml
#cloud-config
# First-boot provisioning for a fresh VPS. Provider-agnostic: paste
# this into any cloud-init-compatible provider's user-data field.
#
# Before use:
#   1. Replace <AGENTOPS_PLATFORM_GIT_URL> below (inside the embedded
#      root-app.yaml) with this repo's real clone URL.
#   2. Replace the age.key file's placeholder content with the real
#      platform age private key (generate it first — see
#      docs/BOOTSTRAP.md's age key backup runbook). Never commit a
#      real key to this file in git; only paste it into the
#      provider's user-data field at VM-creation time.
write_files:
  - path: /opt/agentops/age.key
    permissions: '0600'
    owner: root:root
    content: |
      # REPLACE THIS ENTIRE BLOCK WITH YOUR REAL AGE PRIVATE KEY
      # (the line starting with AGE-SECRET-KEY-) before pasting this
      # file into your cloud provider's user-data field.
      AGE-SECRET-KEY-REPLACE-ME-DO-NOT-COMMIT-A-REAL-KEY-HERE

  - path: /opt/agentops/argocd-values.yaml
    permissions: '0644'
    owner: root:root
    content: |
      configs:
        cm:
          kustomize.buildOptions: "--enable-alpha-plugins --enable-exec --enable-helm"

      repoServer:
        volumes:
          - name: custom-tools
            emptyDir: {}
        initContainers:
          - name: install-ksops
            image: viaductoss/ksops:v4.5.1
            command: ["/usr/local/bin/ksops", "install", "--with-kustomize", "/custom-tools"]
            volumeMounts:
              - mountPath: /custom-tools
                name: custom-tools
        volumeMounts:
          - mountPath: /usr/local/bin/kustomize
            name: custom-tools
            subPath: kustomize
          - mountPath: /usr/local/bin/ksops
            name: custom-tools
            subPath: ksops

  - path: /opt/agentops/root-app.yaml
    permissions: '0644'
    owner: root:root
    content: |
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: root
        namespace: argocd
      spec:
        project: default
        source:
          repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
          targetRevision: main
          path: clusters/ops
        destination:
          server: https://kubernetes.default.svc
        syncPolicy:
          automated:
            prune: true
            selfHeal: true

  - path: /opt/agentops/bootstrap.sh
    permissions: '0700'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      readonly SOPS_VERSION="3.13.2"
      readonly AGE_KEY_PATH="/var/lib/agentops/age.key"
      readonly ARGOCD_NAMESPACE="argocd"
      readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

      AGE_KEY_FILE=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --age-key-file)
            AGE_KEY_FILE="$2"
            shift 2
            ;;
          -h|--help)
            echo "Usage: bootstrap.sh [--age-key-file <path>]"
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
        for i in $(seq 1 60); do
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
        if helm status argocd -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
          log "ArgoCD already installed"
        else
          log "Installing ArgoCD with KSOPS-patched repo-server"
          helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
          helm repo update argo >/dev/null
          helm install argocd argo/argo-cd \
            --namespace "${ARGOCD_NAMESPACE}" \
            --create-namespace \
            --version 10.1.1 \
            -f "${SCRIPT_DIR}/argocd-values.yaml"
        fi

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
        install_k3s
        wait_for_k3s
        place_age_key
        install_argocd
        apply_root_app
        log "Bootstrap complete. ArgoCD is reconciling clusters/ops from the root app."
      }

      main "$@"

runcmd:
  - [ /opt/agentops/bootstrap.sh, --age-key-file, /opt/agentops/age.key ]
```

- [ ] **Step 2: Verify it's valid YAML**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1])); print('OK')" bootstrap/cloud-init.yaml
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add bootstrap/cloud-init.yaml
git commit -m "feat(bootstrap): cloud-init wrapper embedding bootstrap.sh"
```

---

### Task 8: `.github/workflows/lint.yaml` — shellcheck CI

**Files:**
- Create: `.github/workflows/lint.yaml`
- Test: none (this task's own effect is verified by Task 10's full gate; GitHub-hosted `ubuntu-latest` runners ship `shellcheck` preinstalled, no install step needed)

This is the first CI this repo has — not an extension of anything existing.

- [ ] **Step 1: Write the workflow**

```yaml
name: Lint

on:
  pull_request:
  push:
    branches: [main]

jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: shellcheck bootstrap.sh
        run: shellcheck bootstrap/bootstrap.sh
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/lint.yaml
git commit -m "ci: add shellcheck lint workflow (first CI in this repo)"
```

---

### Task 9: `docs/BOOTSTRAP.md` — fill in steps 2–4, add the age-key backup runbook

**Files:**
- Modify: `docs/BOOTSTRAP.md`
- Test: none (documentation)

- [ ] **Step 1: Replace the "Order of operations" step 1 placeholder wording**

Find:
```markdown
1. **Host prep** (`bootstrap/bootstrap.sh` / `cloud-init.yaml`, to be written): Linux host (local or VPS), open ports, install k3s (Traefik bundled). Single node.
```
Replace with:
```markdown
1. **Host prep** (`bootstrap/bootstrap.sh` / `bootstrap/cloud-init.yaml`, done): Linux host (local or VPS) — run `sudo bootstrap/bootstrap.sh` (reads the age private key from stdin, or pass `--age-key-file <path>`), or paste `bootstrap/cloud-init.yaml` into a fresh VPS's user-data (after replacing its `<AGENTOPS_PLATFORM_GIT_URL>` placeholder and the age-key template with real values — never commit either). Installs k3s (Traefik bundled), single node.
```

- [ ] **Step 2: Replace steps 2–4 with concrete detail**

Find:
```markdown
2. **Age key**: generate the platform age keypair; private key goes to the host (and an offline admin backup), *never* into git. Public key → `.sops.yaml` recipients.
3. **ArgoCD**: install via Helm with the KSOPS/helm-secrets repo-server patch so ArgoCD can decrypt SOPS secrets; create the age key secret in the `argocd` namespace.
4. **Root app**: `kubectl apply -f bootstrap/root-app.yaml` — the app-of-apps pointing at `clusters/ops/`. From here on, ArgoCD reconciles everything; no further manual applies.
```
Replace with:
```markdown
2. **Age key**: `age-keygen -o age.key` generates the platform keypair. Back up `age.key`'s contents to at least one offline location (password manager entry, encrypted USB — whatever you already trust) *before* it touches the host — this is the one point of failure for every secret in this repo, per the rebuild story below. Never commit the private key. Its public key line (`# public key: age1...`) replaces `.sops.yaml`'s `age1PLACEHOLDER_REPLACE_DURING_M2`. The private key itself is what `bootstrap.sh --age-key-file age.key` (or stdin) places at `/var/lib/agentops/age.key` on the host.
3. **ArgoCD**: `bootstrap.sh` installs it via Helm with `bootstrap/argocd-values.yaml`'s KSOPS repo-server patch (pinned `viaductoss/ksops:v4.5.1`) so ArgoCD can decrypt SOPS secrets, then creates the `sops-age` secret in the `argocd` namespace from the placed age key. Idempotent — re-running `bootstrap.sh` skips both if already done.
4. **Root app**: `bootstrap.sh` runs `kubectl apply -f bootstrap/root-app.yaml` — the app-of-apps pointing at `clusters/ops/`. **`root-app.yaml`'s `repoURL` must be this repo's real clone URL before this step means anything** — it ships with the literal placeholder `<AGENTOPS_PLATFORM_GIT_URL>` until that's decided. From here on, ArgoCD reconciles everything; no further manual applies.
```

- [ ] **Step 3: Commit**

```bash
git add docs/BOOTSTRAP.md
git commit -m "docs: fill in bootstrap steps 2-4 with concrete commands"
```

---

### Task 10: Full local verification gate

**Files:** none (verification only; fix forward into whichever file if something fails).

- [ ] **Step 1: Run every check added by this plan**

```bash
shellcheck bootstrap/bootstrap.sh
python3 -c "import yaml, sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print('OK')" \
  bootstrap/argocd-values.yaml bootstrap/root-app.yaml bootstrap/cloud-init.yaml
```
Expected: `shellcheck` prints nothing (exit 0); the Python check prints `OK`.

- [ ] **Step 2: If anything failed, fix it in the relevant file and commit the fix**

```bash
git add -A
git commit -m "fix(bootstrap): address verification gate failures"
```
(Skip this step entirely if Step 1 was clean — don't create an empty commit.)

---

### Task 11: Manual dry-run verification (operator-performed, not automated)

**Files:** none — this is a runbook, not a code change. Per the design doc's Testing Strategy, this step needs a real disposable host and cannot be run by CI or an agent without one.

- [ ] **Step 1: Provision a throwaway VM** (any cloud provider or local VM), Ubuntu/Debian LTS, and get root/sudo access.

- [ ] **Step 2: Generate a throwaway age key for this test only**

```bash
age-keygen -o /tmp/test-age.key
```

- [ ] **Step 3: Run bootstrap.sh the first time**

```bash
sudo bootstrap/bootstrap.sh --age-key-file /tmp/test-age.key
```
Expected: completes with `[bootstrap] Bootstrap complete. ArgoCD is reconciling clusters/ops from the root app.` as the last line.

- [ ] **Step 4: Confirm ArgoCD is up and the root app registered**

```bash
sudo kubectl get applications -n argocd
```
Expected: an `Application` named `root`, `Synced`/`Healthy` (or `Synced` with no children yet, since `clusters/ops/{platform,engine,products}` are still `.gitkeep`-only until the platform-components plan lands).

- [ ] **Step 5: Re-run bootstrap.sh and confirm idempotency**

```bash
sudo bootstrap/bootstrap.sh --age-key-file /tmp/test-age.key
```
Expected: every step logs "already installed" / "already present" / "already exists" — no re-installation, no changes, exit code 0.

- [ ] **Step 6: Tear down the throwaway VM and discard the throwaway age key** (it was never meant to protect real secrets).

> **Note — this task tests the mechanism, not the real production key.** The design doc lists `.sops.yaml` as "completed" during M2, but that's a separate, one-time production action, not something this disposable dry-run (or this plan) should perform with a throwaway key: when actually standing up the real host, generate the real keypair (`age-keygen -o age.key`), back its private key up offline first, then update `.sops.yaml` for real:
> ```bash
> sed -i 's/age1PLACEHOLDER_REPLACE_DURING_M2/<real age1... public key from age-keygen output>/' .sops.yaml
> git add .sops.yaml && git commit -m "chore: set real platform age recipient"
> ```
> Only then run `bootstrap.sh --age-key-file age.key` against the real host. `docs/BOOTSTRAP.md`'s step 2 (Task 9 of this plan) documents this same sequence for whoever does it.

---

### Task 12: Open the PR, pass CI, and resolve the Bugbot review

**Files:** none (integration / review).

> Sequential and partly asynchronous — CI and Bugbot run on the remote PR.
> **HARD GATE: Do not mark this task complete until ALL Bugbot comments are
> resolved (fixed or replied to) AND CI is green. Check with
> `gh pr view --json reviews,comments` before claiming done.**

- [ ] **Step 1: Sync the latest `main`**

```bash
git fetch origin
git merge origin/main
shellcheck bootstrap/bootstrap.sh   # resolve conflicts + commit first if any; fix fallout
```

- [ ] **Step 2: Push and open the PR**

```bash
git status --short && git rev-parse --abbrev-ref HEAD   # clean tree, on feature branch (not main)
git push -u origin HEAD
gh pr create --base main --fill --title "Platform bootstrap: bootstrap.sh, cloud-init, ArgoCD+KSOPS"
```

- [ ] **Step 3: Subagent code review**

REQUIRED SUB-SKILL: `requesting-code-review`. Dispatch a code reviewer subagent (BASE_SHA = merge-base with `main`, HEAD_SHA = HEAD). Fix Critical and Important findings, commit, push, then proceed.

- [ ] **Step 4: Make every CI check pass**

```bash
gh pr checks --watch
```
On failure: `gh run view --log-failed`, reproduce locally, fix, commit, push, re-watch. Do not proceed while red.

- [ ] **Step 5: Wait for the Bugbot review**

```bash
gh pr view --json reviews,comments
gh pr comment --body "bugbot run"   # only if it hasn't reviewed yet
```

- [ ] **Step 6: Address each Bugbot comment**

REQUIRED SUB-SKILL: `receiving-code-review`. Verify before acting — reply to false positives; TDD-fix real findings, commit each referencing the finding, push once.

**Then mark each addressed thread resolved** (completion is gated on the unresolved-thread count, not just on having replied/fixed):

```bash
gh api graphql -f query='query($o:String!,$r:String!,$p:Int!){repository(owner:$o,name:$r){pullRequest(number:$p){reviewThreads(first:100){nodes{id isResolved path comments(first:1){nodes{body}}}}}}}' -F o=<owner> -F r=<repo> -F p=<number>
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -F id=<thread-id>
```

**After pushing:** return to Step 4 (re-watch CI), then Step 5 (wait for re-review). Loop until Bugbot reports no unresolved comments.

- [ ] **Step 7: Final verification**

```bash
gh pr checks                          # all green
gh pr view --json reviews,comments    # no comment left unaddressed
shellcheck bootstrap/bootstrap.sh     # suite green locally
python3 -c "import yaml, sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print('OK')" bootstrap/argocd-values.yaml bootstrap/root-app.yaml bootstrap/cloud-init.yaml
```
Confirm no unresolved review threads remain, then mark this task complete.
