# Deploy runbook — fresh host to working platform

Copy-paste runbook for standing up the ops cluster on a **fresh Ubuntu/Debian LTS host** (VPS or bare metal). Single-node k3s, managed by ArgoCD watching this repo on `main`.

For the design rationale behind these steps, see [BOOTSTRAP.md](BOOTSTRAP.md). This doc is the operator checklist only.

---

## What you end up with

- k3s (Traefik bundled) + ArgoCD with KSOPS-decrypted SOPS secrets
- Platform components: cert-manager, step-ca, Let's Encrypt issuer, Technitium DNS, Postgres, Temporal, the `dev-agents` namespace
- Observability: Prometheus, Loki, Tempo, Alloy, Grafana, MailPit (Phase 7)
- `agentops_engine` database + postgres-exporter for size monitoring (Phase 9)
- Internal hostnames, e.g. `temporal.lab`, `grafana.lab`, `mail.lab` (Ingress + step-ca certs)

Everything after bootstrap is GitOps — no further `kubectl apply` for platform components.

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| Host | Ubuntu 22.04/24.04 or Debian 12+, root/sudo, ≥4 GB RAM, ≥40 GB disk |
| Network | Inbound 80/443 if exposing Ingress; UDP/TCP 53 if Technitium serves DNS externally |
| Workstation | Tools below, for generating secrets and editing the repo |
| Repo access | ArgoCD must be able to read this repo — a public repo needs nothing; a **private fork** needs a repo credential (Phase 4) |

### Workstation tools

```bash
brew install age sops git                          # required
brew install gh kubectl kustomize helm jq          # useful: cluster access, local render checks
```

(`jq` is required by `scripts/configure-technitium-dns.sh`; `openssl` ships with macOS.)

Once you have an age key (Phase 0.1), point SOPS at it for every encrypt/decrypt command — add to `~/.zshrc` if you use it often:

```bash
export SOPS_AGE_KEY_FILE="$HOME/.agentops/age.key"
```

**Keep `age.key` out of git** — store it beside or outside the checkout, never under a tracked path.

---

## Phase 0 — One-time repo prep (workstation)

Do this **before** touching the host. Order matters for the age key.

### 0.1 Generate the platform age keypair

```bash
age-keygen -o age.key
chmod 600 age.key
```

The output includes a public key line like `# public key: age1abc...`.

**Back up `age.key` offline now** (password manager, encrypted USB). If you lose it, every SOPS secret in this repo is unrecoverable. Never commit it.

### 0.2 Set the SOPS recipient in this repo

Put your public key into `.sops.yaml` (macOS `sed` needs the backup extension):

```bash
PUBKEY="$(grep '^# public key:' ../age.key | awk '{print $4}')"   # adjust path to age.key
sed -i.bak "s/age1[a-z0-9]*/${PUBKEY}/" .sops.yaml && rm -f .sops.yaml.bak
git add .sops.yaml
git commit -m "chore: set platform age recipient"
git push origin main
```

### 0.3 Create and encrypt Postgres credentials

ArgoCD cannot sync the `postgres` Application until this file exists.

```bash
export SOPS_AGE_KEY_FILE=/path/to/age.key

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

All ArgoCD Applications and `bootstrap/root-app.yaml` must reference your repo over HTTPS:

```yaml
repoURL: https://github.com/est1908-agentic-ops/agentops-platform.git
```

Push everything (age recipient, postgres secret) to `main` before bootstrapping the host.

---

## Phase 1 — Bootstrap the host

Choose **A** (manual script) or **B** (cloud-init). Do not run both on the same host.

### A. Manual bootstrap (existing VM or SSH session)

Clone the repo on the host. A public repo clones anonymously; a **private fork** needs a read-only [deploy key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys) — generate one (`ssh-keygen -t ed25519 -f agentops-platform-deploy-key -N ""`), add the public half under repo Settings → Deploy keys (write access unchecked), then clone with:

```bash
# public repo:
git clone https://github.com/est1908-agentic-ops/agentops-platform.git ~/agentops-platform

# private fork:
GIT_SSH_COMMAND="ssh -i ~/.ssh/agentops-platform-deploy-key -o IdentitiesOnly=yes" \
  git clone git@github.com:<your-org>/agentops-platform.git ~/agentops-platform
```

Copy your `age.key` to the host securely (scp — never commit it), then:

```bash
cd ~/agentops-platform
sudo ./bootstrap/bootstrap.sh --age-key-file /path/to/age.key
```

Expected last line:

```text
[bootstrap] Bootstrap complete. ArgoCD is reconciling clusters/ops from the root app.
```

Re-running the same command is safe (idempotent).

### B. Cloud-init (fresh VPS)

1. On your workstation, edit `bootstrap/cloud-init.yaml`: replace the `age.key` `content:` block with your real private key (lines starting with `AGE-SECRET-KEY-`), and confirm the embedded `repoURL` points at your repo.
2. Paste the **entire file** into the provider's user-data / cloud-init field at VM creation.
3. Wait for first boot (~5–15 min depending on network).

**Never commit a real age private key** — only paste it into the provider's user-data at VM creation time.

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
- Child Applications appearing: `cert-manager`, `step-ca`, `letsencrypt`, `technitium`, `postgres`, `temporal`, `namespaces`, `prometheus`, `loki`, `tempo`, `alloy`, `grafana`, `mailpit`, `postgres-exporter`
- `grafana` stays `Degraded`/`Unknown` until its encrypted credentials exist — see [Phase 7](#phase-7--deploy-the-observability-stack); same dependency shape as `postgres`

Watch until stable:

```bash
kubectl get applications -n argocd -w
```

Typical sync order: `cert-manager` (CRDs) → `step-ca`/`letsencrypt` (need the CRDs) → everything else in parallel.

If `postgres` stays `Degraded`/`Unknown`, check that `secrets/postgres/postgres-credentials.enc.yaml` is on `main` and the age key in the `sops-age` secret matches the key that encrypted it:

```bash
kubectl -n argocd get secret sops-age -o yaml
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
```

If the error says `unable to find plugin root` instead — see [Troubleshooting](#postgres-stuck-on-unknown--ksops-plugin-not-found).

---

## Phase 3 — Post-sync manual steps

Intentional one-time operator actions not automated in GitOps.

### 3.1 Temporal databases (automatic — verify only)

Temporal's two databases (`temporal`, `temporal_visibility`) are created automatically at first boot of the Postgres StatefulSet (`POSTGRES_DB` + the initdb script in `clusters/ops/platform/postgres/initdb-configmap.yaml`). If Temporal schema Jobs failed *before* Postgres was healthy, delete them and let ArgoCD re-sync:

```bash
kubectl delete jobs -n platform -l app.kubernetes.io/instance=temporal
kubectl get jobs -n platform   # confirm they re-run and complete
```

Verify both databases exist:

```bash
kubectl exec -n platform postgres-postgresql-0 -- \
  psql -U temporal -d temporal -c "\l" | grep temporal
```

### 3.2 Configure Technitium DNS

Technitium needs a one-time zone (`lab`) plus an A record for `temporal.lab`. The script talks to Technitium's [REST API](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md) and is safe to re-run.

1. Port-forward to Technitium (leave running in a separate terminal):

   ```bash
   kubectl port-forward -n technitium svc/technitium 5380:5380
   ```

2. Find the target IP (Traefik's external/node IP):

   ```bash
   kubectl get svc -n kube-system traefik
   ```

3. Run the script. On first use, authenticate with the admin account (Technitium ships with `admin`/`admin` — change that password after first login) and pass `--print-token` to mint a reusable API token:

   ```bash
   TECHNITIUM_USER=admin TECHNITIUM_PASSWORD='<admin-password>' \
     ./scripts/configure-technitium-dns.sh --target-ip <traefik-ip> --print-token
   ```

   Save the printed token and use it for subsequent runs:

   ```bash
   TECHNITIUM_TOKEN='<token>' \
     ./scripts/configure-technitium-dns.sh --target-ip <traefik-ip>
   ```

   Re-running is a no-op once DNS is correct. `--help` lists all options (`--zone`, `--record`, `--ttl`, `--url`).

4. Point your workstation or lab router DNS at Technitium for `*.lab` (or use Technitium as upstream forwarder).

Manual fallback: open `http://localhost:5380` (same port-forward), complete initial setup, create the `lab` zone, and add an A record for `temporal.lab` pointing at Traefik's IP.

### 3.3 Trust the step-ca root on admin machines

Export the root CA and install it in your OS/browser trust store:

```bash
kubectl get secrets -n step-ca            # find the CA secret name
```

Follow the [smallstep docs](https://smallstep.com/docs/) for your platform. Without this, `https://temporal.lab` shows a certificate warning even when cert-manager issued the cert correctly.

### 3.4 Confirm the Temporal UI

After DNS and CA trust, open `https://temporal.lab` — expect a valid cert from step-ca and the Temporal Web UI.

---

## Phase 4 — Repo credential for ArgoCD (private forks only)

If ArgoCD can't read the repo, `root` sits at sync status `Unknown` with no child Applications — this is almost always why. A public repo needs no credential. For a **private fork**, register a token-based HTTPS credential (ArgoCD's repo-server uses this — it is separate from Phase 1A's deploy key, which only the host's own `git clone` uses):

Generate a PAT with read access to the repo (fine-grained, scoped to just this repo), then:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n argocd create secret generic repo-agentops-platform \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<your-org>/agentops-platform.git \
  --from-literal=username=<your-user> \
  --from-literal=password=<PAT>

kubectl -n argocd label secret repo-agentops-platform \
  argocd.argoproj.io/secret-type=repository

# refresh the root app
kubectl -n argocd patch application root --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl get applications -n argocd -w
```

Expect `root` to flip to `Synced` and child Applications to appear.

**Cloud-init path:** `cloud-init.yaml` provisions the age key but not this credential — create it manually after first boot.

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

The `engine` Application (`clusters/ops/engine/`) deploys the Temporal worker, gateway, and console, and wires agent runs to launch as k8s Jobs in `dev-agents`. Its Helm chart is pulled as an **OCI artifact** from the self-hosted registry (`oci://gitactions.est1908.top/agentic-ops/engine`) — not from a git repo — and image tags in `values.yaml` are bumped automatically by `agentops-engine` CI on every merge to its `main`.

The registry is basic-auth-gated, so two credentials are involved: one for **kubelet** pulling images (6.3), one for **ArgoCD's repo-server** pulling the chart (6.4). Same underlying username/password, two different consumers.

### 6.1 Create the `github-token` Secret in `dev-agents`

The worker needs this to open PRs (`githubTokenSecretName` chart value, default `github-token`):

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl create namespace dev-agents --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dev-agents create secret generic github-token \
  --from-literal=GITHUB_TOKEN=ghp_YOUR_TOKEN
```

Use a PAT with repo write access to whichever repo you point the engine at. The chart references `GITHUB_TOKEN` as a required env var, so the Secret must exist or the worker pod stays in `CreateContainerConfigError` — if you don't need PR-opening yet, a placeholder value is fine (`--from-literal=GITHUB_TOKEN=placeholder-unused`).

### 6.2 Create the Claude auth Secret

Key name is `CLAUDE_CODE_OAUTH_TOKEN`, Secret name matches the chart's `claudeAuthSecretName` value (default `claude-credentials`):

```bash
kubectl -n dev-agents create secret generic claude-credentials \
  --from-literal=CLAUDE_CODE_OAUTH_TOKEN="$(claude setup-token)"
```

### 6.3 Create the registry pull Secret

Secret name matches the chart's `imagePullSecretName` value (default `registry-credentials`) — needed by the worker Deployment and every `agent-runner` Job pod:

```bash
kubectl -n dev-agents create secret docker-registry registry-credentials \
  --docker-server=gitactions.est1908.top \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_PASSWORD
```

### 6.4 Register the ArgoCD OCI chart credential

```bash
kubectl -n argocd create secret generic repo-gitactions-registry \
  --from-literal=type=helm \
  --from-literal=name=gitactions-registry \
  --from-literal=url=oci://gitactions.est1908.top \
  --from-literal=enableOCI=true \
  --from-literal=username=YOUR_USERNAME \
  --from-literal=password=YOUR_PASSWORD

# repo-creds (a credential *template*), NOT repository: it matches every repoURL
# under the oci://gitactions.est1908.top prefix, so it keeps working when CI
# bumps the chart tag/path. The url MUST carry the oci:// scheme — ArgoCD
# matches credentials against the Application's repoURL by string; a
# scheme-less url silently fails to match ("basic credential not found" in the
# repo-server logs).
kubectl -n argocd label secret repo-gitactions-registry \
  argocd.argoproj.io/secret-type=repo-creds
```

Without this, the `engine` chart can't be pulled — same failure shape as Phase 4 (stuck, no obvious error until you check `argocd-repo-server` logs).

### 6.5 Sanity-check image tags

CI auto-bump should already have set real values:

```bash
grep -n "CHANGEME" clusters/ops/engine/values.yaml clusters/ops/engine/application.yaml
```

If anything prints, set the offending tag in `values.yaml` to a real git SHA from `agentops-engine`'s `main` (confirm the matching image exists in the registry), and `application.yaml`'s chart `targetRevision` to `"0.0.0-<same sha>"`, commit, push.

### 6.6 Watch it sync and smoke-test

```bash
kubectl get applications -n argocd -w
kubectl get pods -n dev-agents
kubectl logs -n dev-agents deploy/engine-worker -f
```

`engine` reaches `Synced`/`Healthy` once the platform components are up (it needs `temporal-frontend.platform.svc.cluster.local:7233` reachable). Then run a real task end-to-end — from your workstation, port-forward Temporal's frontend and start a run against a test repo:

```bash
kubectl port-forward -n platform svc/temporal-frontend 7233:7233 &
TEMPORAL_ADDRESS=localhost:7233 engine start --issue <N>
```

Expect a real merge-ready PR, with each agent stage showing up in `kubectl get pods -n dev-agents` as a Job pod. That — not just "Applications are Healthy" — is what proves the platform works.

---

## Phase 7 — Deploy the observability stack

`prometheus`, `loki`, `tempo`, `alloy`, and `mailpit` sync automatically at Phase 2 with no manual step. `grafana` needs its admin credentials encrypted first — same dependency shape as Postgres. Design doc: [observability stack](superpowers/specs/2026-07-07-observability-stack-design.md).

### 7.1 Create and encrypt Grafana credentials

```bash
export SOPS_AGE_KEY_FILE=/path/to/age.key

PASSWORD="$(openssl rand -base64 24)"
cat > secrets/grafana/grafana-credentials.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-credentials
  namespace: platform
stringData:
  admin-user: admin
  admin-password: "${PASSWORD}"
EOF

sops --encrypt --in-place secrets/grafana/grafana-credentials.enc.yaml
git add secrets/grafana/grafana-credentials.enc.yaml
git commit -m "chore: add encrypted grafana credentials"
git push origin main
```

Store the password somewhere safe — it's the only way into `https://grafana.lab`.

### 7.2 Confirm the stack is healthy

```bash
kubectl get applications -n argocd | grep -E 'prometheus|loki|tempo|alloy|grafana|mailpit'
```

All six should reach `Synced`/`Healthy` (`grafana` only after 7.1). Add Technitium A records for `grafana.lab` and `mail.lab` (same as Phase 3.2), then:

```bash
curl -I https://grafana.lab   # expect Grafana's login page
curl -I https://mail.lab      # expect MailPit's web UI
```

Log in to Grafana and confirm **Prometheus**, **Loki**, and **Tempo** all appear under Connections → Data sources with no error.

The in-cluster OTLP endpoint the engine exports to is `alloy.platform.svc.cluster.local:4317` (OTLP/gRPC) — Alloy routes traces to Tempo and tails every pod's logs to Loki with no further config.

---

## Phase 8 — Engine database and size monitoring

`postgres` creates the `agentops_engine` database automatically on fresh installs (`postgres/initdb-configmap.yaml`). On an **already-bootstrapped** cluster initdb won't run again — the `agent-stats-db-bootstrap` Job (`clusters/ops/platform/postgres/agent-stats-db-bootstrap-job.yaml`) handles that case on sync: it renames the legacy `agent_run_stats` database if present, then creates `agentops_engine` if still missing.

`postgres-exporter` also syncs automatically, reusing `postgres-credentials`. The worker creates its own tables inside `agentops_engine` at startup — nothing to do once the database exists.

Confirm size metrics are flowing:

```bash
kubectl get applications -n argocd | grep postgres-exporter   # expect Synced/Healthy
```

In Grafana → Explore → Prometheus, query `pg_database_size_bytes` or `pg_stat_user_tables_n_live_tup{relname="agent_run_stats"}`.

---

## Rebuild from scratch

Disaster recovery = new host + the same three assets:

1. **Age private key** (offline backup)
2. **This repo** at `main` (including SOPS secrets)
3. **Postgres backup** (`pg_dump` — set up separately; not yet automated)

Steps: provision host → Phase 1 bootstrap with the backed-up age key → ArgoCD re-syncs everything from git. Restore Postgres from dump if you need historical Temporal data. Target time: ~30 minutes for infra.

---

## Troubleshooting

### ArgoCD repo-server crash loop

KSOPS init-container failed or age secret missing:

```bash
kubectl -n argocd logs deploy/argocd-repo-server -c install-ksops
kubectl -n argocd get secret sops-age
```

### postgres stuck on Unknown — ksops plugin not found

Error looks like `Failed to load target state: ... unable to find plugin root - tried: ...`. The `install-ksops` init container ran fine (binaries exist at `/usr/local/bin/`), but kustomize's generator loader for `apiVersion: viaduct.ai/v1, kind: ksops` searches `$XDG_CONFIG_HOME/kustomize/plugin/viaduct.ai/v1/ksops/ksops` — unrelated to `$PATH`. `bootstrap/argocd-values.yaml` mounts the `ksops` binary there too. If you hit this on a from-scratch bootstrap, confirm that third `volumeMounts` entry is present on the live `argocd-repo-server` Deployment (`kubectl -n argocd get deploy argocd-repo-server -o yaml`); if it's missing, the ArgoCD Helm release predates the fix and needs a `helm upgrade` (a plain `bootstrap.sh` re-run skips ArgoCD once installed).

### Application `Unknown` / `ComparisonError`

Usually a render failure — bad YAML, missing encrypted secret, or chart pull error:

```bash
kubectl -n argocd get application <name> -o yaml
kubectl -n argocd logs deploy/argocd-repo-server --tail=100
```

Reproduce locally:

```bash
kustomize build --enable-helm clusters/ops/platform/<component>
```

(Postgres and Grafana additionally need the encrypted secret file and the KSOPS plugin locally.)

### step-ca ACME / cert-manager issues

The `ClusterIssuer` uses `skipTLSVerify: true` until the step-ca root is trusted by cert-manager. Check cert-manager logs:

```bash
kubectl logs -n cert-manager deploy/cert-manager -f
```

### NetworkPolicy not enforcing

k3s's default CNI (flannel) does **not** enforce `NetworkPolicy`. The `dev-agents` policy documents intent only until the CNI is swapped for Cilium/Calico.
