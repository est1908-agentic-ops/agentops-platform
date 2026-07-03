# Platform Bootstrap — Design

Status: draft · 2026-07-03 · Owner: Artem
Milestone: M2, sub-project 1 of 5 (see [decomposition](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-m2-decomposition.md) in `agentops-engine`)

## Context

`docs/BOOTSTRAP.md` already has a decided provisioning approach (staged, uncommitted as of this writing): no Ansible/Terraform for M2, a re-runnable `bootstrap.sh` + a `cloud-init.yaml` wrapper, five steps ending in ArgoCD reconciling everything else. That decision is treated as settled ground truth here — this doc doesn't re-litigate `bootstrap.sh` vs. Ansible, it fills in the concrete content of steps 2–4, which today are placeholders (`.sops.yaml`'s `age1PLACEHOLDER...`, `bootstrap/root-app.yaml`'s `<agentops-platform repo URL — set during M2>`).

This is the one M2 sub-project with zero dependency on any other — it's what everything else gets deployed onto.

## Goal

`bootstrap.sh` run once on a fresh Linux host (or `cloud-init.yaml` on first boot of a fresh VPS) results in a k3s cluster with ArgoCD installed, watching this repo, able to decrypt SOPS secrets — ending exactly where `docs/BOOTSTRAP.md`'s step 4 already says: "From here on, ArgoCD reconciles everything; no further manual applies."

## Non-goals

- The Applications ArgoCD reconciles once bootstrapped (Temporal, step-ca, Technitium, Postgres) — [platform components](2026-07-03-platform-components-design.md)'s job entirely; this doc stops at a working, empty-ish ArgoCD.
- Multi-node, HA control plane — single node per ARCHITECTURE.md §5.1, unchanged.
- Terraform/OpenTofu VPS provisioning — `docs/BOOTSTRAP.md` already defers this ("optional and deferred"); this doc assumes a host already exists (cloud console click, or a local box) and starts from there.
- GitHub Actions self-hosted runner install/config — operator-managed, out of scope for `bootstrap.sh`. Decided to run on the host directly rather than as a k3s workload (see `docs/BOOTSTRAP.md`'s "Decisions already made"); this doc's k3s/ArgoCD scope is unaffected either way.

## Design

### `bootstrap/bootstrap.sh`

Idempotent, checks-before-acting at every step (re-running after a partial failure must be safe):

1. **OS packages.** `curl`, `age`, `sops` — installed via the distro package manager if missing (target: Ubuntu/Debian LTS, per `docs/BOOTSTRAP.md`'s existing note).
2. **k3s install.** Official installer (`curl -sfL https://get.k3s.io | sh -`), Traefik bundled (default, no `--disable traefik`). Skip if `k3s -v` already reports installed. `KUBECONFIG` written to the standard `/etc/rancher/k3s/k3s.yaml`, script exports it for its own subsequent `kubectl`/`helm` calls.
3. **Age key placement.** Script reads the private key from stdin or a `--age-key-file` argument (**never** a value baked into the script or committed anywhere) and writes it to `/var/lib/agentops/age.key` (root-only permissions, `0600`). If a key already exists at that path, the script leaves it alone (idempotent — re-running `bootstrap.sh` must never silently rotate the key it's about to `kubectl create secret` from).
4. **ArgoCD install with KSOPS patch.** `helm install argocd argo/argo-cd -n argocd --create-namespace` using upstream chart values that mount a KSOPS-patched `argocd-repo-server` image (the well-known community pattern: `viaductoss/ksops` init-container/volume approach, values pinned in a `bootstrap/argocd-values.yaml` checked into this repo — not inline in the script, so it's reviewable/diffable like everything else here). Immediately after: `kubectl create secret generic sops-age --from-file=key.txt=/var/lib/agentops/age.key -n argocd` (skip-if-exists check first).
5. **Root app.** `kubectl apply -f bootstrap/root-app.yaml` — completed (see below), pointing at `clusters/ops` in this repo.

### `bootstrap/cloud-init.yaml`

`write_files` embedding `bootstrap.sh` verbatim plus a `runcmd` invoking it with the age private key supplied via a cloud-init-injected file (the operator pastes the key into their cloud provider's user-data/secrets mechanism at VM-creation time — this is the one manual, human-judgment step in the entire flow, deliberately not automated further per `docs/BOOTSTRAP.md`'s "never into git" rule). Target: any cloud-init-compatible provider (documented generically, not tied to one vendor).

### `bootstrap/root-app.yaml` (completed)

Fill in `spec.source.repoURL` with the real repo URL (this repo's actual clone URL — not a placeholder) and `spec.source.targetRevision: main`. Structure otherwise unchanged from what's already checked in.

### `.sops.yaml` (completed)

Replace `age1PLACEHOLDER_REPLACE_DURING_M2` with the real platform age public key, generated once via `age-keygen` as part of running this doc's steps for the first time (the corresponding private key is what step 3 above places on the host and never elsewhere). The recipient list stays a single key for M2 — multiple admin recipients (per `docs/BOOTSTRAP.md`'s "offline admin backup" framing) is a real operational need but not a design decision this doc needs to make; `age.yaml`'s `creation_rules` already supports a list, add entries when a second admin key exists.

### Age key backup

Documented (not automated): after generating the keypair, the private key gets copied to at least one offline location (a password manager entry, an encrypted USB, whatever the operator already trusts) before it's placed on the host. `docs/BOOTSTRAP.md`'s existing framing — "age key backup + these two repos + nightly pg_dump = full rebuild" — already states this is load-bearing for disaster recovery; this doc just makes the step concrete and ordered (generate → back up → place on host → never commit).

## Testing strategy

No unit tests — this is shell script + YAML manifests, not application code. Verification is running it:

- `shellcheck bootstrap.sh` in CI (new, cheap, catches real classes of bugs in idempotency checks).
- Manual dry run on a throwaway VM (any cloud provider or local VM), confirming: re-running `bootstrap.sh` a second time makes no changes (idempotency), and a `kubectl get applications -n argocd` after step 5 shows the root app reconciling (even if child Applications aren't defined yet — [platform components](2026-07-03-platform-components-design.md) adds those).
- This is also the first half of [M2 wiring](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-m2-wiring-design.md)'s end-to-end runbook — that doc's manual verification exercises this script for real, this doc's own testing is the standalone dry run before other sub-projects depend on it.

## Named risks

- **The age private key is the single point of failure for every secret in this repo.** Backup discipline is a documented human step, not enforced by tooling — acceptable for one operator at M2's scale; revisit (e.g., Shamir-split key, multiple admin recipients as standard practice rather than optional) if the team or the number of secrets grows.
- **KSOPS patching ArgoCD's repo-server is a well-known but somewhat fragile community pattern** (not an official ArgoCD feature) — pinning exact chart/image versions in `bootstrap/argocd-values.yaml` (checked in, reviewable) is the mitigation; an ArgoCD upgrade that breaks the patch is a real but bounded risk, caught by the dry-run test above before it ever hits a real host.

## Package/file summary

- **New:** `bootstrap/bootstrap.sh`, `bootstrap/cloud-init.yaml`, `bootstrap/argocd-values.yaml`.
- **Changed:** `bootstrap/root-app.yaml` (real repo URL), `.sops.yaml` (real age recipient).
- **Changed:** `docs/BOOTSTRAP.md` (steps 2–4 filled in with the concrete commands/files above, superseding today's placeholders).
- **New (CI):** a `.github/workflows/lint.yaml`-style job running `shellcheck` — this repo has no CI yet at all; worth noting that adding any CI here is new, not an extension of something existing.

## Open questions carried forward

- Multiple admin age recipients — deferred until a second admin actually exists.
- Whether `cloud-init.yaml` should attempt to be provider-agnostic or pick one reference provider to document precisely — lean provider-agnostic (per the repo's existing "any host" principle), decide the exact wording during implementation.
