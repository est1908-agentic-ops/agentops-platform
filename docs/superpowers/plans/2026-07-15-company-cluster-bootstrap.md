# Company Cluster Bootstrap (AX41) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the company-owned AgentOps platform on a Hetzner AX41: private detached-copy repo, company secrets, bootstrapped k3s + ArgoCD, all Applications `Synced/Healthy`, engine worker running.

**Architecture:** Sub-project 1 of [the company cluster design spec](../specs/2026-07-14-company-cluster-design.md). The company repo is a private detached copy of this repo (git history preserved, `upstream` remote for merges). The host is provisioned with `installimage` (RAID1) and bootstrapped by the existing `bootstrap.sh`; everything after that is GitOps from the company repo's `main`.

**Tech Stack:** k3s, ArgoCD + KSOPS, SOPS/age, Helm/kustomize, Hetzner installimage.

**Execution context:** Most tasks run against the *company* repo/org/host, not this repo — this plan is the record and script. Executors: Artem (holds the upstream age key needed in Task 3) plus a company dev with org admin and AX41 access. Placeholders the executor fills in: `<COMPANY_ORG>` (GitHub org), `<COMPANY_DOMAIN>` (public DNS domain), `<AX41_IP>` (server public IP). Everything else is literal.

## Global Constraints

- Every ArgoCD `Application` and `root-app.yaml` references the company repo as `repoURL: https://github.com/<COMPANY_ORG>/agentops-platform.git` — HTTPS, never `git@github.com:` (ArgoCD has no SSH credential; SSH form fails as `Sync: Unknown` silently). The engine's `oci://gitactions.est1908.top/agentic-ops/engine` repoURL is the one expected exception.
- Everything under `secrets/` MUST be SOPS/age-encrypted (`.sops.yaml` path rule); plaintext there is a CI failure and a security incident.
- ArgoCD syncs the company repo's `main`: merging to `main` **is** deploying. Verify `kubectl get applications -n argocd` after every merge — don't assume merge == deployed.
- `age.key` (company private key) never lives under a git-tracked path. Offline backup before first use.
- On the host, k3s's kubeconfig is root-only: `sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config && chmod 600 ~/.kube/config`, then `export KUBECONFIG=~/.kube/config` per shell.
- All `sops` commands assume `export SOPS_AGE_KEY_FILE=<path-to-company-age.key>` in the current shell.
- Commits are single-purpose; the repo history is the deployment history.

---

### Task 1: Create the private company repo (detached copy)

**Files:**
- Create: GitHub repo `<COMPANY_ORG>/agentops-platform` (private), populated from upstream

**Interfaces:**
- Produces: a local clone at `~/work/company-agentops` with remotes `origin` (company, push target) and `upstream` (public est1908 repo, fetch-only), used by every later task.

- [ ] **Step 1: Create the empty private repo**

In the company org (GitHub UI, or `gh` if authenticated against the org):

```bash
gh repo create <COMPANY_ORG>/agentops-platform --private --description "AgentOps platform (company instance)"
```

- [ ] **Step 2: Clone upstream and push to the company repo**

```bash
git clone https://github.com/est1908-agentic-ops/agentops-platform.git ~/work/company-agentops
cd ~/work/company-agentops
git remote rename origin upstream
git remote add origin git@github.com:<COMPANY_ORG>/agentops-platform.git
git push -u origin main
```

- [ ] **Step 3: Verify remotes and visibility**

```bash
git remote -v
gh repo view <COMPANY_ORG>/agentops-platform --json visibility -q .visibility
```

Expected: `origin` → company repo (fetch+push), `upstream` → est1908 repo; visibility `PRIVATE`.

Future upstream merges (not part of this plan): `git fetch upstream && git merge upstream/main`.

---

### Task 2: Company age key and SOPS recipient

**Files:**
- Create: `~/.agentops-company/age.key` (outside the repo, untracked)
- Modify: `.sops.yaml` (company repo)

**Interfaces:**
- Produces: `SOPS_AGE_KEY_FILE` pointing at the company key; the `.sops.yaml` recipient every Task-3 encryption uses.

- [ ] **Step 1: Generate the keypair**

```bash
mkdir -p ~/.agentops-company
age-keygen -o ~/.agentops-company/age.key
chmod 600 ~/.agentops-company/age.key
export SOPS_AGE_KEY_FILE=~/.agentops-company/age.key
```

- [ ] **Step 2: Back up the key offline**

Password manager or encrypted USB — same rule as upstream (DEPLOY.md Phase 0.1): lose this key, lose every secret.

- [ ] **Step 3: Set the recipient in `.sops.yaml`**

```bash
cd ~/work/company-agentops
PUBKEY="$(grep '^# public key:' ~/.agentops-company/age.key | awk '{print $4}')"
sed -i.bak "s/age1[a-z0-9]*/${PUBKEY}/" .sops.yaml && rm -f .sops.yaml.bak
```

- [ ] **Step 4: Verify and commit**

```bash
grep "$PUBKEY" .sops.yaml   # expect the creation_rules line with the new key
git add .sops.yaml
git commit -m "chore: set company age recipient"
git push origin main
```

---

### Task 3: Re-key all SOPS secrets with company values

**Files:**
- Modify (replace content of all 14): every `secrets/**/*.enc.yaml` in the company repo

**Interfaces:**
- Consumes: upstream secret *structure* (Artem decrypts his copies with the upstream age key to see exact keys/format — no format guessing).
- Produces: 14 company-encrypted secrets; the new X25519 keypair whose public half Task 4 writes into `clusters/ops/engine/values.yaml` (`projectCredentialPublicKey`).

The upstream-encrypted files in the copy are undecryptable by the company key — every one must be recreated. Recipe per file: **Artem** (upstream key) prints the structure, values are replaced with company ones, the file is re-encrypted with the **company** key.

- [ ] **Step 1: For each file, dump the upstream structure (Artem, in his own checkout)**

```bash
# in Artem's est1908 checkout, with HIS SOPS_AGE_KEY_FILE:
sops -d secrets/<dir>/<name>.enc.yaml
```

Share only the *shape* (keys, namespaces) with whoever fills company values — never the decrypted upstream values themselves.

- [ ] **Step 2: Recreate each file in the company repo with company values**

Write the plaintext Secret manifest to the same path, then encrypt in place:

```bash
cd ~/work/company-agentops   # company SOPS_AGE_KEY_FILE exported
# (write the file with company values, matching the upstream structure)
sops --encrypt --in-place secrets/<dir>/<name>.enc.yaml
```

The full inventory — where each company value comes from:

| File | Contents | Company value source |
|---|---|---|
| `secrets/postgres/postgres-credentials.enc.yaml` | `password` for the `temporal` superuser (namespace `platform`) | `openssl rand -base64 32` (DEPLOY.md 0.3 recipe verbatim) |
| `secrets/grafana/grafana-credentials.enc.yaml` | `admin-user`/`admin-password` | `openssl rand -base64 24` (DEPLOY.md 7.1 recipe) |
| `secrets/litellm/litellm-credentials.enc.yaml` | proxy master key + `LITELLM_SALT_KEY` | freshly generated random values |
| `secrets/litellm/litellm-db-credentials.enc.yaml` | LiteLLM DB password | `openssl rand -base64 32` |
| `secrets/litellm/litellm-provider-keys.enc.yaml` | model-provider API keys | company's own provider accounts (placeholder `CHANGEME` is tolerated — proxy syncs Healthy, that provider fails auth until set; DEPLOY.md 8.1) |
| `secrets/model-tokens/claude-credentials.enc.yaml` | `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` on a company Claude subscription |
| `secrets/model-tokens/pi-credentials.enc.yaml` | pi CLI provider keys (incl. `OPENROUTER_API_KEY`) | company OpenRouter/provider accounts |
| `secrets/engine/project-credential-key.enc.yaml` | X25519 private key (`PROJECT_CREDENTIAL_PRIVATE_KEY`) | **new company keypair** — Step 3 below |
| `secrets/engine/control-crud-token.enc.yaml` | `CONTROL_CRUD_TOKEN` operator bearer token | `openssl rand -hex 32` |
| `secrets/engine/argocd-plugin-token.enc.yaml` | `ARGOCD_PLUGIN_TOKEN` gateway↔ApplicationSet bearer token | `openssl rand -hex 32` |
| `secrets/argocd/argocd-plugin-token.enc.yaml` | **same token value** as the engine one above (written together, argocd namespace) | copy from previous row |
| `secrets/engine/platform-agent-credentials.enc.yaml` | `TEMPORAL_HOST`, `GRAFANA_HOST`, `GRAFANA_USER`, `GRAFANA_PASSWORD` | in-cluster hosts unchanged; Grafana user/password = same values as grafana-credentials above |
| `secrets/gateway/gateway-webhook-secret.enc.yaml` | webhook shared secret | `openssl rand -hex 32` (register the same value in GitHub webhook config later, sub-project 2) |
| `secrets/forge/agents-github-token.enc.yaml` | per-project read PAT (est1908-specific example project) | company equivalent, or drop the file AND its line in `clusters/ops/engine-secrets/secret-generator.yaml` if no such project yet |

- [ ] **Step 3: Generate the company X25519 project-credential keypair**

```bash
openssl genpkey -algorithm X25519 -out /tmp/project-credential.key
openssl pkey -in /tmp/project-credential.key -pubout -outform DER | base64   # -> projectCredentialPublicKey for Task 4
```

Put the private key into `secrets/engine/project-credential-key.enc.yaml` in the same field/format the upstream file shows (Step 1 dump is the reference — the engine expects the format produced there, see agentops-engine PR #7). Record the base64 public key for Task 4. `rm /tmp/project-credential.key` after encrypting.

- [ ] **Step 4: Verify every file decrypts with the company key only**

```bash
for f in $(find secrets -name '*.enc.yaml'); do
  sops -d "$f" > /dev/null && echo "OK  $f" || echo "FAIL $f"
done
```

Expected: 14 × `OK` (13 if `forge/` was dropped).

- [ ] **Step 5: Run the repo's manifest validation and commit**

```bash
./scripts/validate-manifests.sh
git add secrets/ clusters/ops/engine-secrets/secret-generator.yaml
git commit -m "chore: re-key all SOPS secrets for the company instance"
git push origin main
```

---

### Task 4: Point manifests at the company repo and set company values

**Files:**
- Modify: `bootstrap/root-app.yaml`, every `clusters/**/application.yaml` and `clusters/ops/project-workers/applicationset.yaml` (repoURL), `clusters/ops/engine/values.yaml` (hostnames + public key)

**Interfaces:**
- Consumes: `projectCredentialPublicKey` base64 from Task 3 Step 3.
- Produces: manifests ArgoCD on the company box can actually sync.

- [ ] **Step 1: Rewrite repoURL everywhere**

```bash
cd ~/work/company-agentops
grep -rl "est1908-agentic-ops/agentops-platform" bootstrap/ clusters/ | \
  xargs sed -i.bak "s#est1908-agentic-ops/agentops-platform#<COMPANY_ORG>/agentops-platform#g"
find bootstrap clusters -name '*.bak' -delete
```

- [ ] **Step 2: Run the CLAUDE.md repoURL check**

```bash
grep -rn "repoURL" --include="*.yaml" clusters/ bootstrap/ | grep -v 'https://github.com'
```

Expected: only the engine's `oci://gitactions.est1908.top` line. Any `git@github.com:` or leftover est1908 HTTPS line is a failure.

- [ ] **Step 3: Set company values in `clusters/ops/engine/values.yaml`**

Replace these four values (leave image tags and everything else untouched):

```yaml
temporalUiBaseUrl: "https://temporal.<COMPANY_DOMAIN>"
projectCredentialPublicKey: "<base64 from Task 3 Step 3>"
gateway:
  ingress:
    host: agentic-ops.<COMPANY_DOMAIN>
control:
  ingress:
    host: console.<COMPANY_DOMAIN>
```

The internal `*.lab` zone stays as upstream — zero changes there (spec: company domain is for *public* hostnames only).

- [ ] **Step 4: Render-check and commit**

```bash
kustomize build --enable-helm clusters/ops/platform/grafana > /dev/null && echo RENDER-OK
git add bootstrap/ clusters/
git commit -m "chore: point Applications at the company repo; set company hostnames and credential pubkey"
git push origin main
```

---

### Task 5: Registry read access for the company cluster

**Files:** none (external systems)

**Interfaces:**
- Produces: read-only username/password for `gitactions.est1908.top`, consumed by Task 9 (kubelet pull secret + ArgoCD OCI chart credential).

The engine chart and all engine images live in Artem's basic-auth registry `gitactions.est1908.top` — the company cluster cannot pull either without credentials. Default: Artem mints a **read-only** account for the company. (Fallback if cross-org credential sharing is unacceptable: mirror chart+images into a company registry and change `image.repository` + the engine Application's `repoURL` — bigger change, out of scope unless forced.)

- [ ] **Step 1: Mint read-only registry credentials (Artem, registry admin UI/config)**

Record as `REGISTRY_USER` / `REGISTRY_PASS`.

- [ ] **Step 2: Verify they pull both artifact types**

```bash
helm registry login gitactions.est1908.top -u "$REGISTRY_USER" -p "$REGISTRY_PASS"
helm pull oci://gitactions.est1908.top/agentic-ops/engine --version "$(grep targetRevision ~/work/company-agentops/clusters/ops/engine/application.yaml | awk '{print $2}' | tr -d '\"')"
docker login gitactions.est1908.top -u "$REGISTRY_USER" -p "$REGISTRY_PASS"
docker manifest inspect gitactions.est1908.top/agentic-ops/worker:$(grep workerTag ~/work/company-agentops/clusters/ops/engine/values.yaml | awk '{print $2}' | tr -d '\"') > /dev/null && echo PULL-OK
```

Expected: chart `.tgz` downloaded; `PULL-OK`.

---

### Task 6: Provision the AX41 (installimage, RAID1)

**Files:** none (Hetzner console + host)

**Interfaces:**
- Produces: fresh Ubuntu 24.04 host at `<AX41_IP>`, RAID1 over both NVMe drives, SSH root access.

- [ ] **Step 1: Boot the server into the Rescue System** (Hetzner Robot → Rescue → linux64, then reset). SSH in with the printed root password.

- [ ] **Step 2: Run `installimage` with RAID1**

In the installimage editor set exactly:

```text
DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1
SWRAID 1
SWRAIDLEVEL 1
HOSTNAME agentops-company
PART swap swap 8G
PART /boot ext3 1G
PART / ext4 all
IMAGE /root/.oldroot/nfs/images/Ubuntu-2404-noble-amd64-base.tar.gz
```

Save, let it run, reboot.

- [ ] **Step 3: Verify the base OS**

```bash
ssh root@<AX41_IP>
cat /proc/mdstat        # expect md raids on nvme0n1/nvme1n1, [UU]
lsb_release -a          # expect Ubuntu 24.04
df -h /                 # expect ~450G+ on /
```

- [ ] **Step 4: Open required ports / DNS prep**

Firewall (Hetzner Robot or host): inbound 22, 80, 443. Create public DNS A records at the company DNS provider: `agentic-ops.<COMPANY_DOMAIN>`, `console.<COMPANY_DOMAIN>`, `temporal.<COMPANY_DOMAIN>` → `<AX41_IP>` (port 80 must be reachable for Let's Encrypt HTTP-01).

---

### Task 7: Bootstrap the host

**Files:** none (host)

**Interfaces:**
- Consumes: company repo `main` (Tasks 2–4 merged), company `age.key`, a read-only deploy key for the private repo.
- Produces: k3s + ArgoCD reconciling `clusters/ops` from the company repo.

- [ ] **Step 1: Create a read-only deploy key and clone (private-repo path, DEPLOY.md Phase 1A)**

```bash
# workstation:
ssh-keygen -t ed25519 -f agentops-platform-deploy-key -N ""
# add .pub under company repo Settings -> Deploy keys (write access UNCHECKED)
scp agentops-platform-deploy-key root@<AX41_IP>:~/.ssh/
scp ~/.agentops-company/age.key root@<AX41_IP>:/root/age.key

# host:
GIT_SSH_COMMAND="ssh -i ~/.ssh/agentops-platform-deploy-key -o IdentitiesOnly=yes" \
  git clone git@github.com:<COMPANY_ORG>/agentops-platform.git ~/agentops-platform
```

- [ ] **Step 2: Run bootstrap**

```bash
cd ~/agentops-platform
sudo ./bootstrap/bootstrap.sh --age-key-file /root/age.key
```

Expected last line: `[bootstrap] Bootstrap complete. ArgoCD is reconciling clusters/ops from the root app.`
Re-running is safe (idempotent). Then `rm /root/age.key` once the `sops-age` secret exists in the argocd namespace.

- [ ] **Step 3: Set up kubeconfig per convention and verify pods**

```bash
sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config && chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config
kubectl get pods -n argocd    # expect all Running
```

---

### Task 8: ArgoCD repo credential (private repo) and first full sync

**Files:** none (cluster secrets — intentionally not GitOps, DEPLOY.md Phase 4)

**Interfaces:**
- Consumes: a fine-grained GitHub PAT, read-only, scoped to `<COMPANY_ORG>/agentops-platform`.
- Produces: `root` Synced with all child Applications appearing.

- [ ] **Step 1: Register the credential**

```bash
kubectl -n argocd create secret generic repo-agentops-platform \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<COMPANY_ORG>/agentops-platform.git \
  --from-literal=username=<company-bot-user> \
  --from-literal=password=<PAT>
kubectl -n argocd label secret repo-agentops-platform argocd.argoproj.io/secret-type=repository
kubectl -n argocd patch application root --type merge -p \
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

- [ ] **Step 2: Watch children appear and settle**

```bash
kubectl get applications -n argocd -w
```

Expected within minutes: `cert-manager`, `step-ca`, `letsencrypt`, `technitium`, `postgres`, `temporal`, `namespaces`, `prometheus`, `loki`, `tempo`, `alloy`, `grafana`, `mailpit`, `litellm`, `postgres-exporter`, `engine`, `engine-secrets`, `project-workers`, `project-workers-secret` — trending to `Synced/Healthy`. (`engine` stays stuck until Task 9's registry credentials; that's expected here.) `postgres` and `grafana` sync directly because Task 3 already shipped their secrets — the upstream runbook's "Degraded until credentials exist" phase doesn't apply.

If `root` sits at `Unknown` with no children: the Phase-4 credential is wrong — recheck URL is the HTTPS form.

---

### Task 9: Engine registry credentials and engine sync

**Files:** none (cluster secrets, DEPLOY.md Phase 6)

**Interfaces:**
- Consumes: `REGISTRY_USER`/`REGISTRY_PASS` (Task 5); a company PAT with write access to target repos (or placeholder).
- Produces: `engine` Application `Synced/Healthy`, worker Deployment `Running`.

- [ ] **Step 1: dev-agents secrets that are intentionally manual**

```bash
kubectl create namespace dev-agents --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dev-agents create secret generic github-token \
  --from-literal=GITHUB_TOKEN=<company-PAT-or-placeholder-unused>
kubectl -n dev-agents create secret docker-registry registry-credentials \
  --docker-server=gitactions.est1908.top \
  --docker-username="$REGISTRY_USER" --docker-password="$REGISTRY_PASS"
```

(`claude-credentials`, `pi-credentials`, and the rest arrive via the `engine-secrets` ksops generator — already re-keyed in Task 3, no kubectl needed, superseding DEPLOY.md 6.1–6.2's manual path.)

- [ ] **Step 2: ArgoCD OCI chart credential (repo-creds template — url MUST carry `oci://`)**

```bash
kubectl -n argocd create secret generic repo-gitactions-registry \
  --from-literal=type=helm \
  --from-literal=name=gitactions-registry \
  --from-literal=url=oci://gitactions.est1908.top \
  --from-literal=enableOCI=true \
  --from-literal=username="$REGISTRY_USER" \
  --from-literal=password="$REGISTRY_PASS"
kubectl -n argocd label secret repo-gitactions-registry argocd.argoproj.io/secret-type=repo-creds
```

- [ ] **Step 3: Verify the engine comes up**

```bash
grep -n "CHANGEME" clusters/ops/engine/values.yaml   # expect no output
kubectl get applications -n argocd | grep engine     # expect Synced/Healthy
kubectl get pods -n dev-agents                       # expect engine-worker/gateway/control Running
kubectl logs -n dev-agents deploy/engine-worker --tail=20   # expect Temporal connection, no crash loop
```

---

### Task 10: Post-sync manual steps (DNS, CA trust, UI checks)

**Files:** none (DEPLOY.md Phase 3, 7.2, 8.2)

**Interfaces:**
- Produces: working internal hostnames, trusted step-ca, verified UIs — the operator-facing proof.

- [ ] **Step 1: Technitium internal DNS** — port-forward `svc/technitium 5380:5380`, find Traefik's IP (`kubectl get svc -n kube-system traefik`), then:

```bash
TECHNITIUM_USER=admin TECHNITIUM_PASSWORD='<admin-password>' \
  ./scripts/configure-technitium-dns.sh --target-ip <traefik-ip> --print-token
```

Add A records for `grafana.lab` and `mail.lab` the same way (DEPLOY.md 7.2). Change the default admin password.

- [ ] **Step 2: Trust step-ca root on admin machines** (DEPLOY.md 3.3), then confirm `https://temporal.lab` serves the Temporal UI with a valid cert.

- [ ] **Step 3: Observability + LiteLLM smoke**

```bash
kubectl get applications -n argocd | grep -E 'prometheus|loki|tempo|alloy|grafana|mailpit|litellm'
curl -I https://grafana.lab      # Grafana login page
curl -I https://mail.lab         # MailPit UI
curl -s http://litellm.platform.svc.cluster.local:4000/health/readiness   # from a cluster shell
```

In Grafana: Prometheus, Loki, Tempo data sources all green. If provider keys were left `CHANGEME`, set them now via `sops secrets/litellm/litellm-provider-keys.enc.yaml` + commit + `kubectl rollout restart deployment/litellm -n platform`.

- [ ] **Step 4: Public ingress proof (Let's Encrypt path)**

```bash
curl -I https://console.<COMPANY_DOMAIN>    # expect a publicly-trusted cert, console responds
```

---

### Task 11: Final acceptance checklist

**Files:**
- Modify: company repo `README.md` (one line noting this is the company instance + upstream link) — optional but recommended.

- [ ] **Step 1: Full smoke table (DEPLOY.md Phase 5)**

```bash
kubectl get applications -n argocd          # ALL Synced/Healthy
kubectl get crd | grep cert-manager
kubectl get clusterissuer step-ca letsencrypt
kubectl get pods -n platform
kubectl get ns dev-agents
sudo ./bootstrap/bootstrap.sh --age-key-file <key>   # idempotency: "already installed" messages
```

- [ ] **Step 2: Confirm disaster-recovery assets exist** — company age key offline backup; company repo `main` is the full cluster state; note that Postgres backups are not yet automated (same as upstream — carry the gap forward consciously).

- [ ] **Step 3: Declare sub-project 1 done** — spec's exit criterion: *fresh bootstrap per DEPLOY.md; all Applications Synced/Healthy*. Sub-project 2 (Rollbar workflow) starts from here.

---

## Self-review notes

- **Spec coverage:** spec §1 (deployment shape) maps to Tasks 1–8; registry dependency (spec Non-goals, engine images) to Tasks 5+9; verification section to Tasks 10–11. Telemetry (§2) and Rollbar (§3) are sub-projects 2–3 — intentionally absent.
- **Deviation from DEPLOY.md called out inline:** Phase 6.1–6.2 manual secrets are superseded by the engine-secrets ksops generator (Task 9 Step 1 note); Phase 0.3/7.1 secrets land earlier via Task 3.
- **Known unknowns made explicit:** exact field format of `project-credential-key` is read from the upstream decrypt in Task 3 Step 1 rather than guessed; `forge/agents-github-token` may be dropped with its generator line.
