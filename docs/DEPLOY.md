# Real cluster deploy — flair-hr/agentops-platform

Copy-paste runbook for standing up the ops cluster on a **fresh Ubuntu/Debian LTS host** (VPS or bare metal). Assumes a single-node k3s cluster managed by ArgoCD watching this repo.

**Repo:** [github.com/flair-hr/agentops-platform](https://github.com/flair-hr/agentops-platform)  
**Git URL (ArgoCD):** `git@github.com:flair-hr/agentops-platform.git` (SSH deploy key — see Phase 4)  
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
repoURL: git@github.com:flair-hr/agentops-platform.git
```

Push any local changes (age recipient, postgres secret, bootstrap manifests) to `main` before bootstrapping the host.

---

## Phase 1 — Bootstrap the host

Choose **A** (manual script) or **B** (cloud-init). Do not run both on the same host.

### A. Manual bootstrap (existing VM or SSH session)

`agentops-platform` is a **private** repo, so the host needs its own read-only credential to clone it. A deploy key is the right tool here — scoped to exactly this repo, read-only, no dependency on any person's GitHub account (same reasoning as `agentops-engine`'s `bump-platform` CI, which uses one for write access; this one only needs read).

**Generate and register the deploy key** (once, from your workstation):

```bash
ssh-keygen -t ed25519 -f agentops-platform-deploy-key -N ""
```

Add the **public** key (`agentops-platform-deploy-key.pub`) at `flair-hr/agentops-platform` → Settings → Deploy keys → Add deploy key. Leave "Allow write access" **unchecked** — the host only reads.

**On the host:**

```bash
# Copy agentops-platform-deploy-key (private half) and age.key to the host
# securely (scp, etc.) — never commit either
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# (after copying the private key to ~/.ssh/agentops-platform-deploy-key)
chmod 600 ~/.ssh/agentops-platform-deploy-key

GIT_SSH_COMMAND="ssh -i ~/.ssh/agentops-platform-deploy-key -o IdentitiesOnly=yes" \
  git clone git@github.com:flair-hr/agentops-platform.git ~/agentops-platform
cd ~/agentops-platform

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
   - Confirm embedded `repoURL` is `git@github.com:flair-hr/agentops-platform.git`.
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

If `postgres` stays `Degraded` or `Unknown`, check that `secrets/postgres/postgres-credentials.enc.yaml` is on `main` and the age key in the `sops-age` secret matches the key that encrypted it:

```bash
kubectl -n argocd get secret sops-age -o yaml
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
```

If the error instead says `unable to find plugin root` — see [Troubleshooting → postgres stuck on Unknown](#postgres-stuck-on-unknown--ksops-plugin-not-found).

---

## Phase 3 — Post-sync manual steps

These are intentional one-time operator actions not automated in GitOps yet.

### 3.1 Temporal visibility database (now automatic)

Temporal needs two databases: `temporal` and `temporal_visibility`. Both are
created automatically at first boot of the Postgres StatefulSet — `temporal`
from `POSTGRES_DB`, and `temporal_visibility` from the initdb script in
`clusters/ops/platform/postgres/initdb-configmap.yaml`. No manual step is
required on a clean bootstrap.

> Historical note: this used to be a manual `CREATE DATABASE temporal_visibility`
> because the old Bitnami chart only created the one database. The Postgres
> component is now a plain StatefulSet on the official image (see the
> `kustomization.yaml` comment for why Bitnami was dropped), and its initdb
> script handles the second database.

If Temporal schema Jobs failed *before* Postgres was healthy (e.g. the
`postgres-credentials` secret didn't exist yet), delete them and let ArgoCD
re-sync once Postgres is up:

```bash
kubectl delete jobs -n platform -l app.kubernetes.io/instance=temporal
kubectl get jobs -n platform   # confirm they re-run and complete
```

To verify both databases exist:

```bash
kubectl exec -n platform postgres-postgresql-0 -- \
  psql -U temporal -d temporal -c "\l" | grep temporal
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

`flair-hr/agentops-platform` is **private**, so ArgoCD needs credentials before it can clone it — required before Phase 2's `root` Application can ever reach `Synced` (every `repoURL` in this repo, including `bootstrap/root-app.yaml`, is now the SSH form `git@github.com:flair-hr/agentops-platform.git`, matching the deploy key generated in Phase 1A).

**Do this before or immediately after Phase 1** — if `root`'s sync status is stuck on `Unknown` with no child Applications appearing in Phase 2, this is almost always why.

Reuse the same deploy key from Phase 1A if you still have its private half, or generate a fresh one (Settings → Deploy keys, read access is enough — ArgoCD only needs to read):

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n argocd create secret generic repo-flair-hr-agentops \
  --from-literal=type=git \
  --from-literal=url=git@github.com:flair-hr/agentops-platform.git \
  --from-file=sshPrivateKey=/path/to/agentops-platform-deploy-key

kubectl -n argocd label secret repo-flair-hr-agentops \
  argocd.argoproj.io/secret-type=repository
```

Refresh the root app:

```bash
kubectl -n argocd patch application root --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl get applications -n argocd -w
```

Expect `root` to flip to `Synced` and the six child Applications (`cert-manager`, `step-ca`, `technitium`, `postgres`, `temporal`, `namespaces`) to appear.

**Cloud-init path:** this secret still has to be created manually after first boot — `cloud-init.yaml` provisions the age key but not an ArgoCD repo credential, so `root` will sit on `Unknown` until you run the two commands above once, post-boot.

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

## Phase 6 — Deploy the engine

The `engine` Application (`clusters/ops/engine/`) deploys the Temporal worker + wires `runAgent` to launch `agent-claude` as a K8s Job in `dev-agents`. Its Helm chart is pulled as an **OCI artifact** from `oci://gitactions.est1908.top/agentic-ops/engine` (`chart: engine`) — not from `agentops-engine`'s git repo — so ArgoCD needs no git credential for `agentops-engine` at all, only the registry credential in 6.2.6.

**Do not sync this yet if the blocker below is unresolved** — the worker will come up but every real task will fail.

### 6.0 Status (as of 2026-07-06)

- ~~No auth secret wired for `agent-claude` Jobs~~ — **fixed**: `claudeAuthSecretName` chart value (default `claude-credentials`) + `CLAUDE_AUTH_SECRET_NAME` env var wire `authSecretName` into every `claude` `K8sJobRunner`/Job pod (`agentops-engine#4`).
- Images and the **Helm chart itself** now come from a self-hosted registry (`gitactions.est1908.top/agentic-ops`), not GHCR and not git. `agentops-engine` CI packages `charts/engine` as an OCI artifact (version `0.0.0-<git-sha>`) alongside the `worker`/`agent-claude` images on every merge to `main`. Since it's basic-auth-gated: images need a K8s `imagePullSecrets` entry (6.2.5), and ArgoCD's own chart pull needs a separate Helm-type repository credential (6.2.6) — same underlying username/password, two different consumers.
- ~~`bump-platform` CI job fails~~ — **fixed**: swapped `PLATFORM_REPO_TOKEN` (a PAT that never had real access) for a write-enabled deploy key scoped to `agentops-platform` (`agentops-engine#6`), and fixed a Python regex crash the auth failure had been masking (`agentops-engine#7`). Confirmed working end-to-end: `workerTag`/`agentClaudeTag`/chart `targetRevision` now auto-bump on every merge to `agentops-engine` main. 6.3 below is now just a sanity check, not a required manual step.

Also confirm before starting: you (or whoever ran the earlier `.sops.yaml`/postgres-secret setup) still has the **age private key** file backed up and accessible — it's required for Phase 1 and isn't recoverable from either repo.

### 6.1 Create the `github-token` Secret in `dev-agents`

The worker needs this to open PRs (`githubTokenSecretName` chart value, default `github-token`):

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl create namespace dev-agents --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dev-agents create secret generic github-token \
  --from-literal=GITHUB_TOKEN=ghp_YOUR_TOKEN
```

(A PAT or GitHub App token with repo write access to whichever test repo you point the engine at — same one M1 used.)

> The engine chart references `GITHUB_TOKEN` as a **required** env var (a
> non-optional `secretKeyRef`), so the Secret must exist or the worker pod stays
> in `CreateContainerConfigError`. The value is only *used* when an agent opens a
> PR at the end of a task. If you only need to bring the platform up / run the M2
> gate and don't need PR-opening yet, a placeholder value is fine:
> `--from-literal=GITHUB_TOKEN=placeholder-unused`. Making the token genuinely
> optional (it arguably belongs to a future component, not the engine) is an
> `agentops-engine` chart change.

### 6.2 Create the Claude auth Secret

Key name is `CLAUDE_CODE_OAUTH_TOKEN`, Secret name matches the chart's `claudeAuthSecretName` value (default `claude-credentials`):

```bash
kubectl -n dev-agents create secret generic claude-credentials \
  --from-literal=CLAUDE_CODE_OAUTH_TOKEN="$(claude setup-token)"
```

### 6.2.5 Create the registry pull Secret

Images are pulled from `gitactions.est1908.top` (basic auth). Secret name matches the chart's `imagePullSecretName` value (default `registry-credentials`) — needed by both the worker Deployment and every `agent-claude` Job pod:

```bash
kubectl -n dev-agents create secret docker-registry registry-credentials \
  --docker-server=gitactions.est1908.top \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_PASSWORD
```

### 6.2.6 Register the ArgoCD OCI chart credential

Different from 6.2.5 above — that Secret is for **kubelet** pulling container images; this one is for **ArgoCD's repo-server** pulling the `engine` Helm chart itself, which is also published to `gitactions.est1908.top` (as an OCI artifact, `agentops-engine` CI pushes it alongside the images). Same underlying credentials, different consumer:

```bash
kubectl -n argocd create secret generic repo-gitactions-registry \
  --from-literal=type=helm \
  --from-literal=name=gitactions-registry \
  --from-literal=url=oci://gitactions.est1908.top \
  --from-literal=enableOCI=true \
  --from-literal=username=YOUR_USERNAME \
  --from-literal=password=YOUR_PASSWORD

# repo-creds (a credential *template*), NOT repository: it matches every repoURL
# under the oci://gitactions.est1908.top prefix by prefix, so it keeps working when
# CI bumps the chart tag/path. The url MUST carry the oci:// scheme — ArgoCD matches
# repo credentials against the Application's repoURL by string, and the engine source
# repoURL is oci://… ; a scheme-less url silently fails to match ("basic credential
# not found" in the repo-server logs).
kubectl -n argocd label secret repo-gitactions-registry \
  argocd.argoproj.io/secret-type=repo-creds
```

Without this, the `engine` Application's chart source (`oci://gitactions.est1908.top/agentic-ops/engine`, `chart: engine`) can't be pulled — same failure shape as Phase 4's missing git credential (stuck, no error obvious until you check `argocd-repo-server` logs).

### 6.3 Confirm real image tags and chart version (sanity check — auto-bump should already have set these)

```bash
grep -n "CHANGEME" clusters/ops/engine/values.yaml clusters/ops/engine/application.yaml
```

If anything prints, manually set `workerTag`/`agentClaudeTag` in `values.yaml` to a real git SHA from `agentops-engine`'s `main` (confirm the matching images exist: `gitactions.est1908.top/agentic-ops/{worker,agent-claude}:<sha>`), and `application.yaml`'s chart `targetRevision` to `"0.0.0-<same sha>"` (confirm that chart version was actually pushed — `agentops-engine`'s `build-images` job pushes it on every merge to `main`), commit, push.

### 6.4 Watch it sync

```bash
kubectl get applications -n argocd -w
```

Expect `engine` to reach `Synced`/`Healthy` after `cert-manager`/`step-ca`/`technitium`/`postgres`/`temporal`/`namespaces` are already up (it needs `temporal-frontend.platform.svc.cluster.local:7233` reachable).

```bash
kubectl get pods -n dev-agents
kubectl logs -n dev-agents deploy/engine-worker -f
```

### 6.5 Smoke test — the actual M2 gate

From your workstation, with `kubectl port-forward` to Temporal's frontend (M2 has no external gRPC exposure by design — see `agentops-engine`'s M2 wiring doc):

```bash
kubectl port-forward -n platform svc/temporal-frontend 7233:7233 &
```

Then run the engine CLI against the same test repo M1 used:

```bash
TEMPORAL_ADDRESS=localhost:7233 engine start --issue <N>
```

Expect: a real merge-ready PR, with the `claude` invocation for each stage showing up in `kubectl get pods -n dev-agents` as a Job pod (not a process on the worker itself). This — not just "Applications are Healthy" — is what actually proves the M2 gate (`ARCHITECTURE.md` §8.1: "M1's scenario runs entirely in-cluster").

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

### postgres stuck on Unknown — ksops plugin not found

Error looks like `Failed to load target state: ... unable to find plugin root - tried: ...`. This means the `install-ksops` init container ran fine (binaries exist at `/usr/local/bin/kustomize`/`/usr/local/bin/ksops`), but that's a *different* lookup than the one kustomize's generator loader actually uses for `apiVersion: viaduct.ai/v1, kind: ksops` (`postgres/secret-generator.yaml`) — it searches `$XDG_CONFIG_HOME/kustomize/plugin/viaduct.ai/v1/ksops/ksops`, unrelated to `$PATH`. `argocd-values.yaml` mounts the `ksops` binary there too (in addition to `/usr/local/bin`) — if you still hit this on a from-scratch bootstrap, confirm that third `volumeMounts` entry is present on the live `argocd-repo-server` Deployment (`kubectl -n argocd get deploy argocd-repo-server -o yaml`); if it's missing, the ArgoCD Helm release predates this fix and needs `helm upgrade` to pick it up (a plain `bootstrap.sh` re-run doesn't touch it, since ArgoCD install is idempotent-skip once already installed).

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

- Model tokens and forge secrets under `secrets/` beyond what Phase 6 needs
- LGTM, LiteLLM, MailPit, GlitchTip (M4+)
- GitHub Actions self-hosted runner on the host (operator-managed)
- `pi`/`cursor`/`codex` agent-runner images — M2 ships `claude` only

See [BOOTSTRAP.md](BOOTSTRAP.md) steps 6–9 for the full M2 roadmap.
