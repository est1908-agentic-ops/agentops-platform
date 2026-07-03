# Bootstrap (M2) — from wiped host to working platform

Target procedure for milestone M2. This document is a **specification to be filled in during M2 implementation** — every step must end up copy-pasteable. The M2 gate is: follow this doc once on a fresh host with no improvisation.

## Provisioning approach (decided)

**No Ansible for now.** The pre-GitOps surface is five steps on one host; everything after is ArgoCD's job. Deliverables in `bootstrap/`:

- `bootstrap.sh` — idempotent, re-runnable script: OS packages → k3s install (official installer, Traefik bundled) → place age key (from stdin/file, never committed) → ArgoCD install with KSOPS repo-server patch → apply `root-app.yaml`. Each step checks before acting.
- `cloud-init.yaml` — user-data template embedding the same script, so a fresh VPS (Ubuntu LTS/Debian) boots directly into a ready platform.

The host is cattle: age key backup + these two repos + nightly pg_dump = full rebuild (~30 min) — that *is* the M2 gate. Revisit Ansible only when per-product prod hosts multiply or host-level config management (hardening, users) grows beyond the script; the same steps then move into a playbook unchanged. Terraform/OpenTofu for VPS *creation* is optional and deferred likewise.

## Order of operations

1. **Host prep** (`bootstrap/bootstrap.sh` / `cloud-init.yaml`, to be written): Linux host (local or VPS), open ports, install k3s (Traefik bundled). Single node.
2. **Age key**: generate the platform age keypair; private key goes to the host (and an offline admin backup), *never* into git. Public key → `.sops.yaml` recipients.
3. **ArgoCD**: install via Helm with the KSOPS/helm-secrets repo-server patch so ArgoCD can decrypt SOPS secrets; create the age key secret in the `argocd` namespace.
4. **Root app**: `kubectl apply -f bootstrap/root-app.yaml` — the app-of-apps pointing at `clusters/ops/`. From here on, ArgoCD reconciles everything; no further manual applies.
5. **Platform components** come up in dependency order (ArgoCD sync waves): Postgres → Temporal → Technitium + step-ca + cert-manager → LGTM (Alloy, Prometheus, Loki, Tempo, Grafana) → LiteLLM → MailPit → GlitchTip.
6. **DNS cutover**: point the workstation/router at Technitium for the internal zone (`*.lab` or chosen zone); trust the step-ca root cert on admin machines.
7. **Engine**: `clusters/ops/engine` values reference images published by `agentops-engine` CI; worker Deployment + agent-runner Job templates + NetworkPolicies.
8. **Secrets**: SOPS-encrypt model tokens (`claude setup-token` output, `CURSOR_API_KEY`, z.ai, codex auth) and forge credentials into `secrets/`; verify runner Jobs can consume them and that egress NetworkPolicies restrict each runner to its provider + forge + LiteLLM.
9. **Smoke test** (M2 gate): run the M1 scenario fully in-cluster — real issue → merge-ready PR — then wipe a scratch host and repeat this doc top to bottom.

## Decisions already made (do not relitigate during implementation)

- ArgoCD (not Flux), SOPS+age (not Vault), step-ca (not mkcert/self-signed), Technitium (not CoreDNS-hacks or hosts files), MailPit for non-prod SMTP. Rationale: ARCHITECTURE.md §5.1.
- Production clusters of products are ArgoCD *destinations* defined under `clusters/prod-<product>/` — never workloads in the ops cluster (§5.7).

## Open items to resolve during M2

- Internal zone name (`.lab` vs something else) — pick once, it leaks into certs and configs.
- Helm chart sources and pinned versions per component (record them in `clusters/ops/platform/*/`).
- ArgoCD Image Updater vs CI-driven tag-bump PRs for engine images (start with tag-bump PRs — simpler, auditable).
- Backup story: Postgres (Temporal history + projections) and the age key — minimum: nightly pg_dump to off-host storage, documented restore.
