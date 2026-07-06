# Real cluster deploy — flair-hr/agentops-platform

Copy-paste runbook for standing up the ops cluster on a **fresh Ubuntu/Debian LTS host** (VPS or bare metal). Assumes a single-node k3s cluster managed by ArgoCD watching this repo.

**Repo:** [github.com/flair-hr/agentops-platform](https://github.com/flair-hr/agentops-platform)  
**Git URL (ArgoCD):** `https://github.com/flair-hr/agentops-platform.git`  
**Branch:** `main`

For design rationale and decisions, see [BOOTSTRAP.md](BOOTSTRAP.md). This doc is the operator checklist only.

---

## What you end up with

After this runbook:

- k3s (Traefik bundled) + ArgoCD with KSOPS-decrypted SOPS secrets
- Platform components: cert-manager, step-ca, Technitium DNS, Postgres, Temporal, `dev-agents` namespace
- Internal hostname example: `temporal.lab` (Ingress + step-ca certs)

Everything after bootstrap is GitOps — no further `kubectl apply` for platform components.

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| Host | Ubuntu 22.04/24.04 or Debian 12+, root/sudo, ≥4 GB RAM, ≥40 GB disk |
| Network | Inbound 80/443 if exposing Ingress; UDP/TCP 53 if Technitium serves DNS externally |
| Workstation | macOS or Linux — see [Workstation setup (macOS)](#workstation-setup-macos) for tools |
| GitHub access | ArgoCD must read `flair-hr/agentops-platform` — for a **private** repo, configure a repo credential in ArgoCD (see [Private repo access](#private-repo-access)) |

---

## Workstation setup (macOS)

Do this on your Mac **before** Phase 0. The cluster host is Linux; your Mac is only for generating secrets, editing the repo, and (optionally) talking to the cluster over SSH/`kubectl`.

### Install Homebrew (if needed)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow the post-install instructions to add `brew` to your `PATH` (Apple Silicon Macs often need the `/opt/homebrew/bin` line in `~/.zprofile`).

### Install required tools

```bash
brew install age sops git
```

| Tool | Purpose |
|------|---------|
| `age` | Provides `age-keygen` and decryption; SOPS uses age under the hood |
| `sops` | Encrypt/decrypt files under `secrets/` |
| `git` | Clone, commit, and push to `flair-hr/agentops-platform` |

`openssl` is already on macOS (used to generate the Postgres password).

### Optional but useful

```bash
brew install gh kubectl kustomize helm jq
```

| Tool | Purpose |
|------|---------|
| `gh` | GitHub CLI — auth, PRs, checking repo access |
| `kubectl` | Inspect the remote cluster after bootstrap (copy kubeconfig from the host) |
| `kustomize` / `helm` | Local render checks (`kustomize build --enable-helm clusters/ops/platform/...`) |
| `jq` | Required by `scripts/configure-technitium-dns.sh` to parse API responses |

### Authenticate with GitHub

```bash
gh auth login
gh repo view flair-hr/agentops-platform
```

If the repo is private, ensure your account has read access before pushing secrets.

### Clone the repo

```bash
git clone https://github.com/flair-hr/agentops-platform.git
cd agentops-platform
```

### Point SOPS at your age key (after Phase 0.1)

Once you have `age.key`, tell SOPS where it lives for every encrypt/decrypt command:

```bash
export SOPS_AGE_KEY_FILE="$PWD/age.key"    # if age.key is in the repo checkout dir
# or
export SOPS_AGE_KEY_FILE="$HOME/.agentops/age.key"   # if stored outside the repo
```

Add the `export` line to `~/.zshrc` if you will run `sops` often.

**Keep `age.key` out of git** — it should live beside or outside the checkout, never under a tracked path. The repo `.gitignore` blocks `*.agekey` but not `age.key`; be deliberate about location.

---

## Phase 0 — One-time repo prep (workstation)

Do this **before** touching the host. Order matters for the age key.

### 0.1 Generate the platform age keypair

From your Mac (repo checkout or any directory — **not** inside a path you will commit):

```bash
age-keygen -o age.key
chmod 600 age.key
```

The output includes a public key line like `# public key: age1abc...`.

**Back up `age.key` offline now** (password manager, encrypted USB, etc.). If you lose it, every SOPS secret in this repo is unrecoverable.

Never commit `age.key`.

### 0.2 Set the SOPS recipient in this repo

Replace the placeholder in `.sops.yaml` with your real public key.

**macOS** (`sed -i` requires a backup extension):

```bash
cd agentops-platform   # your clone

PUBKEY="$(grep '^# public key:' ../age.key | awk '{print $4}')"   # adjust path to age.key
sed -i.bak "s/age1PLACEHOLDER_REPLACE_DURING_M2/${PUBKEY}/" .sops.yaml
rm -f .sops.yaml.bak
git add .sops.yaml
git commit -m "chore: set platform age recipient"
git push origin main
```

### 0.3 Create and encrypt Postgres credentials

ArgoCD cannot sync the `postgres` Application until this file exists.

```bash
cd agentops-platform

export SOPS_AGE_KEY_FILE=/path/to/age.key   # e.g. $HOME/.agentops/age.key

PASSWORD="$(openssl rand -base64 32)"
cat > secrets/postgres/postgres-credentials.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: platform
stringData:
  password: "${PASSWORD}"
EOF

sops --encrypt --in-place secrets/postgres/postgres-credentials.enc.yaml
git add secrets/postgres/postgres-credentials.enc.yaml
git commit -m "chore: add encrypted postgres credentials"
git push origin main
```

Store the password somewhere safe if you need manual `psql` access later.

### 0.4 Confirm manifests are on `main`

All ArgoCD Applications and `bootstrap/root-app.yaml` should reference:

```yaml
repoURL: https://github.com/flair-hr/agentops-platform.git
```

Push any local changes (age recipient, postgres secret, bootstrap manifests) to `main` before bootstrapping the host.

---

## Phase 1 — Bootstrap the host

Choose **A** (manual script) or **B** (cloud-init). Do not run both on the same host.

### A. Manual bootstrap (existing VM or SSH session)

On the host:

```bash
git clone https://github.com/flair-hr/agentops-platform.git /opt/agentops-platform
cd /opt/agentops-platform

# Copy age.key to the host securely (scp, etc.) — never commit it
sudo ./bootstrap/bootstrap.sh --age-key-file /path/to/age.key
```

Expected last line:

```text
[bootstrap] Bootstrap complete. ArgoCD is reconciling clusters/ops from the root app.
```

Re-running the same command is safe (idempotent).

### B. Cloud-init (fresh VPS)

1. On your workstation, edit `bootstrap/cloud-init.yaml`:
   - Replace the `age.key` `content:` block with your real private key (lines starting with `AGE-SECRET-KEY-`).
   - Confirm embedded `repoURL` is `https://github.com/flair-hr/agentops-platform.git`.
2. Paste the **entire file** into the provider's user-data / cloud-init field at VM creation.
3. Wait for first boot (~5–15 min depending on network).

**Never commit a real age private key to git** — only paste it into the provider's user-data at VM creation time.

---

## Phase 2 — Verify bootstrap

On the host (k3s kubeconfig is at `/etc/rancher/k3s/k3s.yaml`):

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get pods -n argocd
kubectl get applications -n argocd
```

Expect:

- ArgoCD pods `Running`
- Application `root` present and moving toward `Synced` / `Healthy`
- Child Applications appearing: `cert-manager`, `step-ca`, `technitium`, `postgres`, `temporal`, `namespaces`

Watch until stable:

```bash
kubectl get applications -n argocd -w
```

### Typical sync order

1. `cert-manager` — installs CRDs
2. `step-ca` — needs cert-manager CRDs for `ClusterIssuer`
3. `technitium`, `postgres`, `temporal`, `namespaces` — can proceed in parallel once deps are met

If `postgres` stays `Degraded`, check that `secrets/postgres/postgres-credentials.enc.yaml` is on `main` and the age key in the `sops-age` secret matches the key that encrypted it:

```bash
kubectl -n argocd get secret sops-age -o yaml
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
```

---

## Phase 3 — Post-sync manual steps

These are intentional one-time operator actions not automated in GitOps yet.

### 3.1 Create the Temporal visibility database

Bitnami Postgres only creates the `temporal` database from chart values. Temporal also needs `temporal_visibility`:

```bash
kubectl exec -n platform -it postgres-postgresql-0 -- \
  psql -U temporal -d temporal -c "CREATE DATABASE temporal_visibility;"
```

If Temporal schema Jobs already failed, delete them after creating the DB and let ArgoCD re-sync:

```bash
kubectl delete jobs -n platform -l app.kubernetes.io/instance=temporal
```

Confirm Jobs complete:

```bash
kubectl get jobs -n platform
```

### 3.2 Configure Technitium DNS

Technitium needs a one-time zone (`lab`) plus an A record for `temporal.lab`. Use the script below (quick path) — it talks to Technitium's own [REST API](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md) and is safe to re-run. The manual web UI steps underneath remain as a fallback for when the API isn't reachable/authenticated yet (e.g. before Technitium's initial setup has run, or to troubleshoot).

#### Quick path: `scripts/configure-technitium-dns.sh`

1. Port-forward to Technitium's web UI/API (leave this running in a separate terminal):

   ```bash
   kubectl port-forward -n technitium svc/technitium 5380:5380
   ```

2. Find the target IP (Traefik's external/node IP):

   ```bash
   kubectl get svc -n kube-system traefik
   ```

3. Run the script. On first use, authenticate with the admin account (Technitium ships with `admin`/`admin` — change this password after first login) and pass `--print-token` to mint a reusable API token:

   ```bash
   TECHNITIUM_USER=admin TECHNITIUM_PASSWORD='<admin-password>' \
     ./scripts/configure-technitium-dns.sh --target-ip <traefik-ip> --print-token
   ```

   Save the printed token (e.g. in your password manager) and use it for subsequent runs instead of the admin password:

   ```bash
   TECHNITIUM_TOKEN='<token-from-above>' \
     ./scripts/configure-technitium-dns.sh --target-ip <traefik-ip>
   ```

   The script creates the `lab` zone only if it doesn't already exist, and creates/updates the `temporal.lab` A record only if it doesn't already point at `--target-ip` — re-running it is a no-op once DNS is already correct. Run `./scripts/configure-technitium-dns.sh --help` for all options (`--zone`, `--record`, `--ttl`, `--url`).

4. Point your workstation or lab router DNS at Technitium for `*.lab` (or use Technitium as upstream forwarder).

#### Manual fallback (web UI)

Use this if the script can't reach Technitium's API, credentials/token aren't set up yet, or you want to inspect the zone visually:

1. Port-forward or reach Technitium web UI (port 5380):

   ```bash
   kubectl port-forward -n technitium svc/technitium 5380:5380
   ```

   Open `http://localhost:5380` and complete initial setup.

2. Create a zone for your internal TLD (default in configs: **`lab`**).
3. Add an A/AAAA or CNAME record for `temporal.lab` pointing at Traefik's external IP or the node IP:

   ```bash
   kubectl get svc -n kube-system traefik
   ```

4. Point your workstation or lab router DNS at Technitium for `*.lab` (or use Technitium as upstream forwarder).

### 3.3 Trust step-ca root on admin machines

Export the root CA and install it in your OS/browser trust store:

```bash
# Exact secret name may vary — list first:
kubectl get secrets -n step-ca

kubectl get secret -n step-ca step-certificates-ca-password \
  -o jsonpath='{.data}'   # inspect; or use step CLI inside the pod
```

Follow [smallstep documentation](https://smallstep.com/docs/) for your platform, or copy the root from the step-ca pod/config. Without this, `https://temporal.lab` will show a certificate warning even when cert-manager issued the cert correctly.

### 3.4 Confirm Temporal UI

After DNS and CA trust:

```bash
curl -I https://temporal.lab
```

Or open `https://temporal.lab` in a browser — expect a valid cert from step-ca and the Temporal Web UI.

---

## Phase 4 — Private repo access

If `flair-hr/agentops-platform` is **private**, ArgoCD needs credentials before it can clone.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# GitHub PAT with repo read scope
kubectl -n argocd create secret generic repo-flair-hr-agentops \
  --from-literal=username=git \
  --from-literal=password="ghp_YOUR_TOKEN"

# Label so ArgoCD picks it up
kubectl -n argocd label secret repo-flair-hr-agentops \
  argocd.argoproj.io/secret-type=repository

# Register the repo (or use argocd CLI / UI)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: repo-flair-hr-agentops
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/flair-hr/agentops-platform.git
  username: git
  password: ghp_YOUR_TOKEN
EOF
```

Refresh the root app in the ArgoCD UI or:

```bash
kubectl -n argocd patch application root --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

For SSH deploy keys, use ArgoCD's SSH repo secret format instead.

---

## Phase 5 — Smoke checklist

| Check | Command / action |
|-------|------------------|
| All Applications healthy | `kubectl get applications -n argocd` |
| cert-manager CRDs | `kubectl get crd \| grep cert-manager` |
| step-ca ClusterIssuer | `kubectl get clusterissuer step-ca` |
| Postgres pod | `kubectl get pods -n platform -l app.kubernetes.io/name=postgresql` |
| Temporal pods | `kubectl get pods -n platform -l app.kubernetes.io/instance=temporal` |
| dev-agents namespace | `kubectl get ns dev-agents` |
| Bootstrap idempotent | Re-run `sudo bootstrap/bootstrap.sh --age-key-file age.key` — expect "already installed" messages |

---

## Rebuild from scratch

Disaster recovery = new host + same three assets:

1. **Age private key** (offline backup)
2. **This repo** at `main` (including SOPS secrets)
3. **Postgres backup** (`pg_dump` — set up separately; not automated in M2)

Steps: provision host → Phase 1 bootstrap with backed-up age key → ArgoCD re-syncs everything from git. Restore Postgres from dump if you need historical Temporal data.

Target time: ~30 minutes for infra; longer if restoring large DB backups.

---

## Troubleshooting

### ArgoCD repo-server crash loop

KSOPS init-container failed or age secret missing:

```bash
kubectl -n argocd logs deploy/argocd-repo-server -c install-ksops
kubectl -n argocd get secret sops-age
```

### Application `Unknown` / `ComparisonError`

Usually render failure — bad YAML, missing encrypted secret, or helm chart pull error:

```bash
kubectl -n argocd get application <name> -o yaml
kubectl -n argocd logs deploy/argocd-repo-server --tail=100
```

Reproduce locally:

```bash
kustomize build --enable-helm clusters/ops/platform/<component>
```

(Postgres requires the encrypted secret file and KSOPS plugin locally.)

### step-ca ACME / cert-manager issues

`ClusterIssuer` uses `skipTLSVerify: true` until step-ca root is trusted by cert-manager. Check cert-manager logs:

```bash
kubectl logs -n cert-manager deploy/cert-manager -f
```

### NetworkPolicy not enforcing

k3s default CNI (flannel) does **not** enforce `NetworkPolicy`. The `dev-agents` policy documents intent only until you swap to Cilium/Calico. See platform-components design doc.

---

## What comes next (out of scope for this doc)

- Engine chart under `clusters/ops/engine/` ([agentops-engine](https://github.com/flair-hr/agentops-engine))
- Model tokens and forge secrets under `secrets/`
- LGTM, LiteLLM, MailPit, GlitchTip (M4+)
- GitHub Actions self-hosted runner on the host (operator-managed)

See [BOOTSTRAP.md](BOOTSTRAP.md) steps 6–9 for the full M2 roadmap.
