# agentops-platform

GitOps **state** of the agentic ops platform: everything ArgoCD deploys and reconciles — platform components, engine deployment (pinned image tags), product registry, and SOPS-encrypted secrets. The **code** lives in the sibling repo `agentops-engine`; that repo builds images, this repo pins and deploys them.

Design authority: `agentops-engine/docs/ARCHITECTURE.md` (§5.1 cluster base, §5.7 multi-product topology, §5.8 repo layout). Bootstrap procedure: [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md). **Real cluster deploy runbook:** [docs/DEPLOY.md](docs/DEPLOY.md).

## Principles

- **Config is the state.** If it's not in this repo, it doesn't exist in the cluster. Manual `kubectl apply`/`helm install` is a bug — fix by PR.
- **Rollback = `git revert`.** This repo's history is the deployment history; keep commits single-purpose (one component bump / one product change per commit).
- **Secrets are SOPS/age-encrypted, always.** Plaintext secrets must never be committed — `.sops.yaml` defines which paths must be encrypted. The age private key exists only in the ArgoCD namespace and admin backups; agents work in this repo without ever seeing plaintext.
- **Agents change infra by PR** like everyone else; ArgoCD is the only thing that touches the cluster.

## How ArgoCD uses this repo

This repo *is* the GitOps source of truth ArgoCD watches — not where application code lives (that's `agentops-engine`).

1. `bootstrap/bootstrap.sh` installs k3s + ArgoCD on a fresh host, then applies `bootstrap/root-app.yaml`.
2. `root-app.yaml` is an ArgoCD "app-of-apps" `Application` pointing at this repo's `clusters/ops` path on `main`.
3. ArgoCD reconciles everything under `clusters/ops/{platform,engine,products}/` — each subdirectory is one or more `Application` CRs defined here.

Merging a PR to `main` is what changes the cluster; there is no other path.

## Deploy to a VPS

Fresh Ubuntu 22.04/24.04 or Debian 12+, ≥4 GB RAM / ≥40 GB disk. Two ways to bootstrap:

**A. Manual (existing VM / SSH session):**

```bash
git clone https://github.com/flair-hr/agentops-platform.git /opt/agentops-platform
cd /opt/agentops-platform
# copy your age.key to the host first (scp, etc.) — never commit it
sudo ./bootstrap/bootstrap.sh --age-key-file /path/to/age.key
```

**B. Cloud-init (fresh VPS):** paste `bootstrap/cloud-init.yaml` (with your real age private key filled in) into the provider's user-data field at VM creation — the host boots straight into a working platform, no SSH step needed.

Either path installs k3s (Traefik bundled) + ArgoCD with KSOPS, then ArgoCD takes over reconciling everything else from this repo. Re-running `bootstrap.sh` is safe (idempotent). Full prerequisites, one-time repo prep (age key, SOPS recipient, Postgres secret), and post-sync steps: see [docs/DEPLOY.md](docs/DEPLOY.md).

## Layout

```
bootstrap/                  # everything before ArgoCD manages itself
  bootstrap.sh              # idempotent host bootstrap: k3s + ArgoCD + KSOPS
  cloud-init.yaml           # same bootstrap, embedded as VPS user-data
  root-app.yaml             # ArgoCD app-of-apps entrypoint
clusters/
  ops/                      # the shared agent-ops cluster
    platform/               # one ArgoCD Application per component:
                            #   temporal, postgres, litellm, lgtm (alloy/
                            #   prometheus/loki/tempo/grafana), argocd,
                            #   step-ca, technitium, mailpit, glitchtip
    engine/                 # engine chart values + pinned image tags (tags bumped
                            #   automatically by agentops-engine CI on merge)
    products/               # product registry: one Application per product →
                            #   points at the product repo's /deploy path;
                            #   namespace, quotas, DNS subzone
  prod-<product>/           # production destination clusters (prod stays
                            #   out of the ops cluster — ARCHITECTURE.md §5.7)
secrets/                    # SOPS-encrypted only
  model-tokens/             # CLAUDE_CODE_OAUTH_TOKEN, CURSOR_API_KEY, z.ai, codex
  forge/  litellm/  smtp/
.sops.yaml                  # age recipients + enforced path rules
```

## Status

Milestone **M2** (see `agentops-engine/docs/MILESTONES.md`): bootstrap (`bootstrap.sh`/`cloud-init.yaml`) and all platform components (cert-manager, step-ca, Technitium, Postgres, Temporal) are implemented and merged to `main`. Engine deployment (`clusters/ops/engine/`) is wired but not yet exercised on a real host — see [docs/DEPLOY.md](docs/DEPLOY.md) Phase 6 for current blockers. The M2 gate: a wiped host rebuilds to a working platform from these two repos, following docs/BOOTSTRAP.md with no improvisation — not yet run for real.
