# Per-Project Forge Secrets — Design

Status: draft · 2026-07-06 · Owner: Artem
Companion to `agentops-engine`'s [project-registry-design.md](../../../../agentops-engine/docs/superpowers/specs/2026-07-06-project-registry-design.md), which replaces the engine's single global `GITHUB_TOKEN` with a per-project registry (`PROJECT_REGISTRY_JSON` + one `GITHUB_TOKEN__<PRODUCT>` secret-backed env var per project). That doc's onboarding runbook step 3 ("create the K8s Secret") and its "Open questions carried forward" both explicitly deferred *how* that secret gets encrypted and wired in this repo — this doc is that missing piece.

## Context

`secrets/forge/` exists today only as an empty `.gitkeep` placeholder. `docs/BOOTSTRAP.md` step 8 and `docs/DEPLOY.md`'s "what comes next" both already name "forge credentials under `secrets/`" as an explicit, unfilled gap — this predates the per-project registry work, but that work is what makes filling it un-deferrable: one shared `github-token` secret could plausibly be created once by hand and forgotten; N per-project secrets cannot.

One structural fact shapes the whole design: `clusters/ops/engine/application.yaml` is a **pure two-source Helm Application** (chart from `agentops-engine`, values from this repo) — it has no Kustomize step. Contrast with `clusters/ops/platform/postgres/`, which already solves "one SOPS-encrypted secret, decrypted by ArgoCD" via a Kustomize `kustomization.yaml` + KSOPS `secret-generator.yaml` pair *inside that same Application's Kustomize source*. That pattern doesn't drop into the engine's Application because there's no Kustomize source to add a generator to — this doc adapts it via a small sibling Application instead (§2).

## Goal

Every per-project `GITHUB_TOKEN__<PRODUCT>` is SOPS-encrypted in this repo's git history and materializes as a plain K8s `Secret` in `dev-agents` via ArgoCD/KSOPS at sync time — no plaintext ever committed, no manual `kubectl create secret` step, and the rebuild story in `docs/DEPLOY.md`'s "Rebuild from scratch" section actually holds for these secrets, not only for Postgres's.

## Non-goals

- The rest of the "add a product" flow (registry entry, `agentops.json`, `clusters/ops/engine/values.yaml`'s `projects` map) — that's `agentops-engine`'s project-registry-design.md; this doc is the secrets slice only.
- Model-token secrets (`secrets/model-tokens/`), LiteLLM, SMTP — the same mechanism applies once those categories are populated, but the worked example and testing here are forge-only.
- GitHub App installation tokens — named as future work in the engine-side design; this doc assumes long-lived PATs, one per project, same trust model as today's single shared token.
- Scripting secret creation — `docs/DEPLOY.md` Phase 0.3's heredoc-then-`sops --encrypt` pattern is manual and stays manual here; a wrapper script is a reasonable follow-up, not required for this pass.

## Design

### 1. One `.enc.yaml` file per project, under `secrets/forge/`

Naming: `secrets/forge/github-token-<product>.enc.yaml`, mirroring `secrets/postgres/postgres-credentials.enc.yaml`'s exact shape — a plain K8s `Secret` manifest, SOPS-encrypted field-by-field. `.sops.yaml`'s existing path rule (`^secrets/.*\.(yaml|yml|json|env)$`) already covers this path — no `.sops.yaml` change needed.

Authored with the same pattern `docs/DEPLOY.md` Phase 0.3 already documents for Postgres:

```bash
export SOPS_AGE_KEY_FILE=/path/to/age.key

cat > secrets/forge/github-token-product-a.enc.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-token-product-a
  namespace: dev-agents
stringData:
  GITHUB_TOKEN: "ghp_..."
EOF

sops --encrypt --in-place secrets/forge/github-token-product-a.enc.yaml
git add secrets/forge/github-token-product-a.enc.yaml
git commit -m "chore: add encrypted GitHub token secret for product-a"
```

`namespace: dev-agents` is set inside the manifest itself (matching Postgres's secret, which sets `namespace: platform`) rather than relying on the Application's `destination.namespace` — explicit beats implicit when the manifest is the thing under encryption.

### 2. A new `clusters/ops/engine-secrets/` Kustomize Application

Reuses Postgres's Kustomize+KSOPS pattern in a sibling directory, decoupled from the engine's Helm-only Application:

```
clusters/ops/engine-secrets/
  application.yaml       # ArgoCD Application, Kustomize source
  kustomization.yaml      # generators: [secret-generator.yaml]
  secret-generator.yaml   # one `files:` entry per registered project
```

```yaml
# clusters/ops/engine-secrets/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml
```

```yaml
# clusters/ops/engine-secrets/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: engine-forge-secrets-generator
files:
  - ../../../secrets/forge/github-token-product-a.enc.yaml
  # one line per registered project, added in the same PR that adds the
  # project to clusters/ops/engine/values.yaml's `projects` map (see §3)
```

```yaml
# clusters/ops/engine-secrets/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: engine-secrets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: https://github.com/flair-hr/agentops-platform.git
    targetRevision: main
    path: clusters/ops/engine-secrets
  destination:
    server: https://kubernetes.default.svc
    namespace: dev-agents
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Registered in `clusters/ops/kustomization.yaml` alongside the existing Applications:

```yaml
resources:
  - platform/cert-manager/application.yaml
  - platform/step-ca/application.yaml
  - platform/technitium/application.yaml
  - platform/postgres/application.yaml
  - platform/temporal/application.yaml
  - platform/namespaces/application.yaml
  - engine-secrets/application.yaml
  - engine/application.yaml
```

The `sync-wave: "-1"` annotation makes `engine-secrets` reconcile before `engine` on a fresh sync (ArgoCD applies lower wave numbers first) — without it, a first-time bootstrap could apply the worker Deployment before its Secret exists, crash-looping on `CreateContainerConfigError` until `selfHeal` eventually retries in the right order. This Application's only job is materializing plain `Secret` objects into `dev-agents`; the engine's Helm-based Application is unchanged and stays unaware of how those Secrets got there — it only ever does a name-based `secretKeyRef` lookup.

### 3. Onboarding step 3 becomes concrete

The engine-side design's onboarding runbook step 3 ("create the K8s Secret") is now three sub-steps, all landing in **one `agentops-platform` PR** alongside the `projects.<product>` entry:

1. Author + `sops --encrypt` the `.enc.yaml` file (§1).
2. Add one line to `secret-generator.yaml`'s `files:` list (§2).
3. Add the `projects.<product>` entry to `clusters/ops/engine/values.yaml` (already specified in the engine-side doc).

One PR registers a product's repo *and* its credential together — reviewable as a single unit, same "config is the state" principle this repo's README already states.

## Testing strategy

- `kustomize build --enable-helm clusters/ops/engine-secrets` locally (the same command `docs/DEPLOY.md`'s troubleshooting section already uses for Postgres) — requires the KSOPS kustomize plugin and `SOPS_AGE_KEY_FILE` set locally; confirms the generator renders a `Secret` without error before ever pushing.
- Manual, on the same dry-run VM the platform-components spec already uses: confirm `engine-secrets` reaches `Synced`/`Healthy` before `engine`, then `kubectl get secret github-token-product-a -n dev-agents -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d | head -c4` sanity-checks the right value landed (without printing the whole token to a terminal/log).
- Rebuild-from-scratch check (`docs/DEPLOY.md`'s existing "Rebuild from scratch" section, already required by BOOTSTRAP's M2 gate): wipe the host, restore only the backed-up age key + this repo, confirm the Secret reappears with zero manual `kubectl create secret` steps. This is the concrete test that closes the gap named in `agentops-engine/docs/MILESTONES.md`'s M2 hardening note.

## Named risks

- **`secret-generator.yaml`'s `files:` list and `clusters/ops/engine/values.yaml`'s `projects` map are two independent lists that must stay in sync by hand.** A project in one but not the other fails differently: missing generator entry → Secret never created → engine Pod `CreateContainerConfigError`; missing values entry → Secret exists but the engine's `PROJECT_REGISTRY_JSON` never references it, so it's inert. No automated cross-check yet — a small CI step running both `kustomize build` and `helm template` and diffing declared project names would close this; not built here, named so it isn't silently assumed solved.
- **Sync-wave ordering is easy to get wrong on a fresh bootstrap.** Mitigated by the explicit `sync-wave: "-1"` annotation in §2 rather than relying on Applications happening to reconcile in a favorable order — call this out in `docs/DEPLOY.md` Phase 2's "typical sync order" list once implemented.
- **KSOPS decrypts at the ArgoCD repo-server, invisible to `git diff`.** Reviewing a PR that adds a `.enc.yaml` file means reviewing ciphertext — the actual token value is only checkable by an operator with `SOPS_AGE_KEY_FILE` locally. Identical trust model to Postgres's existing credential, not a new risk this doc introduces, but worth restating since forge tokens (unlike the Postgres password) grant write access to a real GitHub repo.

## Package/file summary

- **New:** `secrets/forge/github-token-<product>.enc.yaml` per registered project — one worked example expected during implementation, for whichever repo is the M1/M2 test repo.
- **New:** `clusters/ops/engine-secrets/{application.yaml,kustomization.yaml,secret-generator.yaml}`.
- **Changed:** `clusters/ops/kustomization.yaml` — register the new Application.
- **Changed:** `docs/DEPLOY.md` — extend the Phase 0.3-style instructions to cover forge secrets (today only Postgres is documented there); add `engine-secrets` to Phase 2's "typical sync order" list.
- **Changed:** `docs/BOOTSTRAP.md` step 8 — replace the current one-line placeholder with a pointer to this doc.

## Open questions carried forward

- Automated drift check between `secret-generator.yaml`'s file list and `clusters/ops/engine/values.yaml`'s `projects` map — named as a risk above, not built.
- Whether `engine-secrets` should eventually fold in model-token secrets too (one Application for everything the engine consumes) once `secrets/model-tokens/` is populated — defer until it actually has contents.
