# Bootstrap (M2) — from wiped host to working platform

Target procedure for milestone M2. This document is a **specification to be filled in during M2 implementation** — every step must end up copy-pasteable. The M2 gate is: follow this doc once on a fresh host with no improvisation.

**Operator runbook:** for step-by-step commands to deploy to a real cluster, see [DEPLOY.md](DEPLOY.md) (`flair-hr/agentops-platform`).

## Provisioning approach (decided)

**No Ansible for now.** The pre-GitOps surface is five steps on one host; everything after is ArgoCD's job. Deliverables in `bootstrap/`:

- `bootstrap.sh` — idempotent, re-runnable script: OS packages → k3s install (official installer, Traefik bundled) → place age key (from stdin/file, never committed) → ArgoCD install with KSOPS repo-server patch → apply `root-app.yaml`. Each step checks before acting.
- `cloud-init.yaml` — user-data template embedding the same script, so a fresh VPS (Ubuntu LTS/Debian) boots directly into a ready platform.

The host is cattle: age key backup + these two repos + nightly pg_dump = full rebuild (~30 min) — that *is* the M2 gate. Revisit Ansible only when per-product prod hosts multiply or host-level config management (hardening, users) grows beyond the script; the same steps then move into a playbook unchanged. Terraform/OpenTofu for VPS *creation* is optional and deferred likewise.

## Order of operations

1. **Host prep** (`bootstrap/bootstrap.sh` / `bootstrap/cloud-init.yaml`, done): Linux host (local or VPS) — run `sudo bootstrap/bootstrap.sh` (reads the age private key from stdin, or pass `--age-key-file <path>`), or paste `bootstrap/cloud-init.yaml` into a fresh VPS's user-data (after replacing the age-key template with your real private key — never commit it). Installs k3s (Traefik bundled), single node. See [DEPLOY.md](DEPLOY.md).
2. **Age key**: `age-keygen -o age.key` generates the platform keypair. Back up `age.key`'s contents to at least one offline location (password manager entry, encrypted USB — whatever you already trust) *before* it touches the host — this is the one point of failure for every secret in this repo, per the rebuild story below. Never commit the private key. Its public key line (`# public key: age1...`) replaces `.sops.yaml`'s `age1PLACEHOLDER_REPLACE_DURING_M2`. The private key itself is what `bootstrap.sh --age-key-file age.key` (or stdin) places at `/var/lib/agentops/age.key` on the host.
3. **ArgoCD**: `bootstrap.sh` installs it via Helm with `bootstrap/argocd-values.yaml`'s KSOPS repo-server patch (pinned `viaductoss/ksops:v4.5.1`) so ArgoCD can decrypt SOPS secrets, then creates the `sops-age` secret in the `argocd` namespace from the placed age key. Idempotent — re-running `bootstrap.sh` skips both if already done.
4. **Root app**: `bootstrap.sh` runs `kubectl apply -f bootstrap/root-app.yaml` — the app-of-apps pointing at `clusters/ops/` on `git@github.com:flair-hr/agentops-platform.git` (this repo is private — a read-only deploy key credential for ArgoCD, see [DEPLOY.md](DEPLOY.md) Phase 4, must exist before `root` can reach `Synced`). From here on, ArgoCD reconciles everything; no further manual applies.
5. **Platform components**: `cert-manager` → `step-ca` (needs cert-manager's CRDs) → `Technitium`/`Postgres`/`Temporal` (no ordering dependency between these three) → `dev-agents` namespace. See `clusters/ops/platform/*/application.yaml` for the actual ArgoCD Applications — LGTM/LiteLLM/MailPit/GlitchTip are M4+, not part of this set yet.
6. **DNS cutover**: point the workstation/router at Technitium for the internal zone (`*.lab` or chosen zone); trust the step-ca root cert on admin machines.
7. **Engine**: `clusters/ops/engine` values reference images published by `agentops-engine` CI; worker Deployment + agent-runner Job templates + NetworkPolicies.
8. **Secrets**: SOPS-encrypt model tokens (`claude setup-token` output, `CURSOR_API_KEY`, z.ai, codex auth) and forge credentials into `secrets/`; verify runner Jobs can consume them and that egress NetworkPolicies restrict each runner to its provider + forge + LiteLLM.
9. **Smoke test** (M2 gate): run the M1 scenario fully in-cluster — real issue → merge-ready PR — then wipe a scratch host and repeat this doc top to bottom.

## Decisions already made (do not relitigate during implementation)

- ArgoCD (not Flux), SOPS+age (not Vault), step-ca (not mkcert/self-signed), Technitium (not CoreDNS-hacks or hosts files), MailPit for non-prod SMTP. Rationale: ARCHITECTURE.md §5.1.
- Production clusters of products are ArgoCD *destinations* defined under `clusters/prod-<product>/` — never workloads in the ops cluster (§5.7).
- **GitHub Actions self-hosted runner runs directly on the host, not as a k3s workload.** Product CI (e.g. `docker compose`-based e2e steps) needs a Docker daemon the host already has; running the runner in-cluster would need a privileged DinD sidecar or a host-docker-socket mount, both of which undo the isolation the cluster is otherwise used for. Runner install/config is operator-managed, outside `bootstrap.sh`'s scope.

## Open items to resolve during M2

- Internal zone name (`.lab` vs something else) — pick once, it leaks into certs and configs.
- Helm chart sources and pinned versions per component (record them in `clusters/ops/platform/*/`).
- ArgoCD Image Updater vs CI-driven tag-bump PRs for engine images (start with tag-bump PRs — simpler, auditable).
- Backup story: Postgres (Temporal history + projections) and the age key — minimum: nightly pg_dump to off-host storage, documented restore.
