# agentops-platform

The GitOps home of **Agentic Ops** — a self-hosted platform where AI coding agents live and work: they pick up GitHub issues, design, implement, review, open PRs, babysit CI, hunt bugs, and patch the platform itself.

> The human provides the idea. Implementation, maintenance, QA, monitoring,
> delivery, bug fixing, and support can be automated.

This repo is the **state** of that platform: everything ArgoCD deploys and reconciles — platform components, the engine deployment (pinned image tags), and SOPS-encrypted secrets. The **code** (Temporal workflows, agent runner, gateway, console) lives in the sibling repo [`agentops-engine`](https://github.com/est1908-agentic-ops/agentops-engine); that repo builds images, this repo pins and deploys them.

## The idea

Working with coding agents quickly turns into juggling — several projects, several agents, prompts like *"wait for review comments, fix them all, make sure CI is green, don't touch me, I went to sleep"*. You end up being the orchestrator.

Agentic Ops flips that: a friendly office environment for digital workers, running on a single cheap VPS.

- **Autonomous** — write down your ideas in the evening, label the issues, go to sleep. Review PRs in the morning.
- **Durable** — every workflow runs on [Temporal](https://temporal.io): resumable, retryable, inspectable mid-flight.
- **Observable** — OTel traces, logs, and metrics for every agent run: Grafana over Loki / Tempo / Prometheus.
- **Self-hosted, multi-everything** — multi-model, multi-provider, multi-repo. Your infrastructure, your tokens.
- **Everything as code** — this repo *is* the cluster. Changes land by PR; rollback is `git revert`. Agents change the infrastructure the same way people do.

Built-in workflows include the dev cycle (design → plan → implement → review → PR babysit), PR fixing, bug hunting, and platform self-healing. A managed project can define its own custom workflows — nightly QA, scheduled security reviews, whatever fits in a Temporal workflow.

## How it works

1. `bootstrap/bootstrap.sh` (or `bootstrap/cloud-init.yaml` as VPS user-data) installs k3s and ArgoCD with KSOPS on a fresh host, then applies `bootstrap/root-app.yaml`.
2. `root-app.yaml` is an ArgoCD app-of-apps pointing at this repo's `clusters/ops` path on `main`.
3. ArgoCD reconciles everything under `clusters/ops/` from there on.

Merging a PR to `main` is what changes the cluster; there is no other path.

## What runs on the cluster

| Component | Role |
|-----------|------|
| Temporal + PostgreSQL | Durable execution engine for all agent workflows |
| Engine (worker, gateway, console) | The Agentic Ops application itself — agents run as k8s Jobs |
| Alloy → Loki / Tempo / Prometheus, Grafana | Logs, traces, metrics, dashboards |
| cert-manager + step-ca + Let's Encrypt | Internal CA for `*.lab` hosts, real certs for public ones |
| Technitium | DNS for the internal zone |
| MailPit | Catch-all SMTP for non-prod email |

## Layout

```
bootstrap/                  # everything before ArgoCD manages itself
  bootstrap.sh              # idempotent host bootstrap: k3s + ArgoCD + KSOPS
  cloud-init.yaml           # same bootstrap, embedded as VPS user-data
  root-app.yaml             # ArgoCD app-of-apps entrypoint
clusters/ops/
  platform/                 # one ArgoCD Application per component (table above)
  engine/                   # engine chart values + image tags, auto-bumped
                            #   by agentops-engine CI on every merge
  engine-secrets/           # SOPS-decrypted secrets for the engine
  project-workers/          # ApplicationSet: one worker per managed project,
                            #   spec read from each project's agents.json
  products/                 # registry of product deployments (empty for now)
secrets/                    # SOPS/age-encrypted only — never plaintext
.sops.yaml                  # age recipients + enforced path rules
```

## Deploy your own

A fresh Ubuntu 22.04/24.04 or Debian 12+ host with ≥4 GB RAM and ≥40 GB disk is enough. Fork this repo, generate your own age key, replace the SOPS recipient and secrets with yours, and follow the runbook in **[docs/DEPLOY.md](docs/DEPLOY.md)** — it goes from empty host to working platform, phase by phase.

Design decisions behind the bootstrap (why a shell script and not Ansible, why ArgoCD/SOPS/step-ca/Technitium) are in [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md).

## Ground rules

- **Config is the state.** If it's not in this repo, it doesn't exist in the cluster. Manual `kubectl apply` is a bug — fix by PR.
- **Rollback = `git revert`.** This repo's history is the deployment history; keep commits single-purpose.
- **Secrets are SOPS/age-encrypted, always.** `.sops.yaml` defines which paths must be encrypted; the age private key exists only in the ArgoCD namespace and offline backups.
- **Agents change infra by PR** like everyone else; ArgoCD is the only thing that touches the cluster.

## Status

This is a personal lab that runs for real — one node, one operator, evolving quickly. Docs describe the intended happy path and occasionally lag behind the manifests; when in doubt, the manifests win. Design docs and implementation plans written along the way are kept in [docs/superpowers/](docs/superpowers/) as a historical record.
