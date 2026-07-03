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

## Layout

```
bootstrap/                  # everything before ArgoCD manages itself
  k3s-install.md            # host prep (written during M2)
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

Pre-M2 skeleton. This repo becomes active at milestone **M2** (see `agentops-engine/docs/MILESTONES.md`); until then only docs and structure live here. The M2 gate: a wiped host rebuilds to a working platform from these two repos, following docs/BOOTSTRAP.md with no improvisation.
