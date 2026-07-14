# Bootstrap — design decisions

Why the pre-GitOps surface looks the way it does. The step-by-step commands live in [DEPLOY.md](DEPLOY.md); this doc records the reasoning so it doesn't get relitigated.

## One script, no Ansible

The pre-GitOps surface is five steps on one host; everything after is ArgoCD's job. So `bootstrap/` contains exactly two deliverables:

- `bootstrap.sh` — idempotent, re-runnable: OS packages → k3s (official installer, Traefik bundled) → place the age key (from stdin or `--age-key-file`, never committed) → ArgoCD via Helm with the KSOPS repo-server patch (`bootstrap/argocd-values.yaml`) → apply `root-app.yaml`. Each step checks before acting, so re-running after a partial failure is safe.
- `cloud-init.yaml` — user-data template embedding the same script, so a fresh VPS boots directly into a ready platform.

The host is cattle: age key backup + this repo + a Postgres dump = full rebuild in ~30 minutes, and that rebuild is the acceptance test for the whole bootstrap. Ansible becomes worth it only when per-product prod hosts multiply or host-level config management (hardening, users) outgrows the script — the same steps would move into a playbook unchanged. Terraform/OpenTofu for VPS *creation* is deferred for the same reason.

## Order of operations

1. **Host prep** — run `bootstrap.sh` (or boot with `cloud-init.yaml`). Installs k3s, single node.
2. **Age key** — `age-keygen` once; the public key goes into `.sops.yaml`, the private key is backed up offline *before* it touches the host, and `bootstrap.sh` places it at `/var/lib/agentops/age.key`. This key is the single point of failure for every secret in the repo.
3. **ArgoCD** — installed with the KSOPS repo-server patch (pinned `viaductoss/ksops`) so it can decrypt SOPS secrets; the `sops-age` secret is created from the placed key.
4. **Root app** — `kubectl apply -f bootstrap/root-app.yaml`, the app-of-apps pointing at `clusters/ops/`. From here on ArgoCD reconciles everything; no further manual applies.
5. **Platform components** — `cert-manager` → `step-ca`/`letsencrypt` (need cert-manager's CRDs) → Technitium / Postgres / Temporal / namespaces in parallel.
6. **DNS cutover** — point workstation/router at Technitium for the internal zone (`*.lab`); trust the step-ca root on admin machines.
7. **Engine** — `clusters/ops/engine/` values reference images and the Helm chart published by `agentops-engine` CI.
8. **Secrets** — SOPS-encrypt model tokens and forge credentials into `secrets/`; runner Jobs consume them as k8s Secrets.

## Decisions

- **ArgoCD**, not Flux. **SOPS + age**, not Vault. **step-ca**, not mkcert/self-signed. **Technitium**, not CoreDNS hacks or hosts files. **MailPit** for non-prod SMTP.
- **Internal zone is `.lab`** — picked once; it leaks into certs and configs.
- **Production clusters of products are ArgoCD *destinations*** (`clusters/prod-<product>/`) — never workloads in the ops cluster.
- **Engine image updates are CI-driven tag-bump commits**, not ArgoCD Image Updater — simpler and auditable; every deploy is a git commit.
- **The GitHub Actions self-hosted runner runs directly on the host, not as a k3s workload.** Product CI needs a Docker daemon the host already has; running the runner in-cluster would need a privileged DinD sidecar or a host-docker-socket mount, both of which undo the isolation the cluster provides. Runner install/config is operator-managed, outside `bootstrap.sh`'s scope. This repo's own CI (`.github/workflows/lint.yaml`) runs on it.

## Still open

- **Backup automation** — the rebuild story assumes a Postgres dump (Temporal history + projections) exists. Minimum target: nightly `pg_dump` to off-host storage with a documented restore. Not automated yet.
