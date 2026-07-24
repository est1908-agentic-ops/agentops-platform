# AgentOps Platform Template — Design

Status: draft · 2026-07-15 · Owner: Artem

## Context

`agentops-platform` today has a split personality. It is simultaneously:

1. **The personal lab instance** — the live single-node k3s/ArgoCD cluster syncs from *this repo's* `origin/main` (see `CLAUDE.md`: "ArgoCD syncs from `origin/main`, so a broken manifest merged to `main` breaks the live cluster").
2. **The thing others copy** — the README's "Deploy your own" tells people to fork it, swap the age key and secrets, and follow `docs/DEPLOY.md`.

The company-cluster spec (`2026-07-14-company-cluster-design.md`) leaned on #2 with a "private detached copy + `upstream` remote" model, and explicitly **deferred** a shared base as YAGNI at N=2, naming the *published-artifact model* as the future direction with the trigger being "a third instance."

This spec reverses that deferral deliberately. The new vision: **this repo becomes the canonical, generic AgentOps platform template** — a public GitHub *template repository*. Anyone (a product team, a company, a solo dev) clicks **Use this template**, fills a small documented set of blanks, runs bootstrap, and owns their platform repo + cluster outright. Each deployment gets its own platform repo; the personal lab becomes just another instance generated from the template, which dogfoods it.

The pivot also forces a second change that was already overdue: the engine's cross-repo image bump (agentops-engine CI writing commits into this repo) cannot exist in a world where every adopter owns their own repo — est1908's CI cannot push into strangers' repos. That push is replaced with a pull-based, per-instance update mechanism.

## Goal

Turn `agentops-platform` into a distributable GitHub template that a stranger can adopt with a small, greppable customization surface and an agent-assisted onboarding path — while keeping the repo's ground rules intact (config-is-state, rollback = `git revert`, secrets always SOPS-encrypted). Migrate the live personal lab off this repo onto its own instance repo first, so converting this repo to the generic template never breaks the running cluster.

## Non-goals

- **Scaffold generator CLI / bespoke `init.sh`.** Rejected in favor of the placeholder convention + runbook. The agent-driven path is a `.claude` skill (below), not a maintained CLI.
- **Published-artifact (OCI) platform charts.** The platform layer stays plain manifests in the template; each adopter owns the copy. The OCI-chart model remains the *later* direction if divergence across adopters becomes painful — not built here.
- **An automatic base→instance upgrade channel.** Upgrades to the base are opt-in per adopter (documented `upstream` remote + merge, or a changelog). The template does not push updates to instances.
- **Prescribing 1-product-per-cluster.** An adopter owns **one platform repo per deployment**; that repo can drive one *or many* project repos through the existing `project-workers` ApplicationSet. "Every product gets its own platform repo" becomes cheap and default, not a rigid rule.
- **Engine public-registry migration.** A prerequisite (below) implemented in **agentops-engine**, tracked here as a dependency, not built in this repo.
- **Full personal-lab migration in this spec's implementation.** The `agentops-platform-homelab` repo is created; the actual push + ArgoCD re-point is sub-project 1's own plan (sequenced first).

## Decisions (settled during brainstorm)

| Question | Decision |
|----------|----------|
| End state | Distributable template — strangers adopt it; optimize for a clean scaffold with minimal ongoing coupling |
| Distribution | GitHub **template repository** ("Use this template"); adopter owns the copy outright; upgrades opt-in |
| Repo identity | **This repo → the generic template.** The live personal lab forks out to its own repo (`agentops-platform-homelab`, private, already created) |
| Customization | **Placeholder convention + runbook**, greppable `__TOKEN__`s; no bespoke CLI |
| Onboarding automation | A `.claude/skills/customize-instance` skill fills the blanks, scaffolds secrets, deletes the `.template` sentinel |
| Deploy-with-placeholders guard | A `.template` sentinel file + `scripts/check-customized.sh`, enforced by CI once the sentinel is gone |
| Internal zone | `.lab` stays a working default (self-contained via Technitium + step-ca); optional override. Only the **public domain** is a mandatory token |
| Engine source | Batteries-included from a **public registry** (agentops-engine-side prerequisite: publish to e.g. `ghcr.io/est1908-agentic-ops` instead of `gitactions.est1908.top`) |
| Engine updates | **ArgoCD Image Updater, `newest-build`, `argocd` (commit-free) write-back** per instance — no commits to platform repos; every instance auto-follows the latest engine. Built on homelab first, then baked into the template. Gated `stable` + public registry are adopter-facing refinements / fallback |

## Design

### 1. Repo model

Flip on GitHub's **Template repository** setting for this repo. "Use this template" stamps out a full, deployable copy the adopter owns. The base repo stays a complete reference deployment (it is what the personal lab and any adopter start from). There is no runtime coupling from an instance back to the template beyond an optional, adopter-added `upstream` remote for pulling later improvements.

### 2. Base vs. customization surface

**Base (adopter never edits):** the app-of-apps wiring, `clusters/ops/platform/*` component structure, the bootstrap flow (`bootstrap/`), the engine/project-worker deployment shape, and the lint/validation scripts.

**The blanks** — greppable `__TOKEN__` placeholders, all present in the current repo:

| Blank | Where (current value) | Token |
|-------|----------------------|-------|
| Platform repo URL | `bootstrap/root-app.yaml`, `bootstrap/cloud-init.yaml`, every `clusters/**/application.yaml` (~18), `engine-secrets`, `project-workers-secret`, `project-workers/applicationset.yaml` (`https://github.com/est1908-agentic-ops/agentops-platform.git`) | `__PLATFORM_REPO_URL__` |
| age recipient | `.sops.yaml` (`age1x5del8…` — already labeled a placeholder) | *(documented blank)* |
| Public base domain | `letsencrypt/cluster-issuer.yaml`; `engine/values.yaml` (`gateway.ingress.host`, `control.ingress.host`, `temporalUiBaseUrl`); `grafana` ingress host (`agentic-ops.est1908.top` + `console.`/`grafana.`/`temporal.` subdomains) | `__BASE_DOMAIN__` |
| ACME email | `letsencrypt/cluster-issuer.yaml` (`artem.kireev@flair.hr`) | `__ACME_EMAIL__` |
| Secrets | `secrets/**` (est1908's real SOPS blobs) | ship `*.example.yaml` shapes; adopter creates + encrypts real ones |
| Engine artifact | `engine/application.yaml` (OCI `repoURL`), `engine/values.yaml` (`image.repository`), `project-workers/applicationset.yaml` (OCI `repoURL`) — all `gitactions.est1908.top/agentic-ops/...` | default → public registry (see §5) |

The table lists **mandatory** blanks only. The internal zone (`.lab`) is *not* a blank: it ships as a working default (self-contained via Technitium + step-ca) and is documented in `docs/CUSTOMIZE.md` as an optional override.

**Secret scaffolding:** the template must **not** carry est1908's encrypted `secrets/**` (they are the personal lab's real material, and adopters cannot decrypt them anyway). Replace each `*.enc.yaml` with a `*.example.yaml` showing the shape with dummy values, keeping the directory structure (`.gitkeep`). `docs/CUSTOMIZE.md` documents creating and encrypting the real ones.

### 3. Guardrail: the `.template` sentinel

A sentinel file `.template` lives in the canonical template. A new `scripts/check-customized.sh`:

- **Skips** all placeholder checks when `.template` is present (the template repo is *supposed* to contain `__TOKEN__`s).
- **Enforces** "no `__…__` placeholder tokens remain anywhere" once `.template` is gone.

Onboarding step 0 is "delete `.template`," which flips enforcement on automatically. This guards the single most likely adopter failure — deploying with `__PLATFORM_REPO_URL__` still unfilled, the exact class of error `CLAUDE.md` already warns about hardest. Wire `check-customized.sh` into `.github/workflows/lint.yaml` alongside the existing generic checks (no SSH repoURL, secrets encrypted). Also retarget that workflow from `runs-on: self-hosted` to `ubuntu-latest`, since adopters have no self-hosted runner.

### 4. Onboarding

**Docs, reframed around the adopter journey:**

- `README.md` → "the AgentOps platform template": what it is, a Use-this-template CTA, link to getting-started. Keep "The idea."
- `docs/GETTING-STARTED.md` → the runbook: use template → generate age key + set `.sops.yaml` → fill tokens → create + encrypt secrets from `*.example.yaml` → bootstrap (cloud-init/VPS or `bootstrap.sh`/dedicated) → verify all Applications `Synced/Healthy`.
- `docs/CUSTOMIZE.md` → the §2 token table as the single source of every blank, including the optional `.lab` override.
- `CLAUDE.md` → genericize the repoURL rule to "*your* repo's HTTPS URL," keep the guardrail spirit. `docs/BOOTSTRAP.md` kept (rationale), lightly genericized. Historical `docs/superpowers/specs` and `plans` kept as-is (record).

**Agent-driven path — `.claude/skills/customize-instance`:** a skill that walks an agent (or the adopter via Claude Code) through onboarding: prompt for the handful of values (repo URL, base domain, ACME email, age recipient, optional internal zone), substitute the tokens across the tree, scaffold `secrets/**` from the `*.example.yaml` files, run `check-customized.sh`, and delete `.template`. This is the automation layer on top of the runbook — not a maintained CLI, just a markdown skill the agent executes. The manual `sed`/`grep` runbook remains the fallback.

### 5. Engine source + update mechanism

**Source (batteries-included, public registry):** the template ships pointing at the upstream engine build so it works out of the box. Prerequisite, implemented in **agentops-engine**: publish engine + project-worker OCI artifacts to a public, reliably pullable registry (e.g. `ghcr.io/est1908-agentic-ops/*`) instead of the personal `gitactions.est1908.top`, and point the template defaults there. Until this lands, the template only resolves against est1908's box.

**Updates (pull, commit-free):** retire the agentops-engine CI push (`scripts/bump-platform-engine-tags.sh`, which committed image tags + chart `targetRevision` into this repo on every merge) and replace it with **ArgoCD Image Updater**, deployed as a platform component under `clusters/ops/platform/argocd-image-updater/`. Built on **homelab first** (immediate relief from hand-merging engine bumps), then baked into the template as a parameterized component.

- **Track all four engine images** (`worker`, `agent-runner`, `control`, `gateway` under `gitactions.est1908.top/agentic-ops`) with the **`newest-build`** strategy — the only viable strategy for the engine's random git-sha tags (it sorts by each image's registry `created` timestamp). Needs **zero engine-side change**: it reads the existing private registry with the existing `registry-credentials`.
- **`argocd` (commit-free) write-back:** Image Updater patches the **live `engine` Application's Helm parameter overrides in-cluster** — **no commits to any platform repo**. Every instance polls the registry and updates *itself*, so all instances auto-follow the latest engine with no git touch and no est1908 involvement.
- **Trade-off (accepted):** the running engine version lives in the live Application, not git. The repo's "git is the deployment history / `git revert` to roll back" rule therefore **does not apply to the engine version** (everything else still follows git). Engine rollback is imperative: pin a known-good sha in Image Updater (allow-tags / disable + set) or patch the Application's parameter. A bad build auto-deploys until pinned — acceptable for a homelab (fix-forward, or pin for minutes).
- **Chart `targetRevision` stays git-pinned:** Image Updater updates image tags, not the OCI chart version. The chart (templates) is bumped manually on the rare chart-level change; images auto-follow. Caveat: if an engine image needs a matching chart change, the pinned chart can lag — the same team owns both, so coordinate that bump.
- **Adopter-facing refinements / fallback:** a gated **`stable`** channel tag (engine CI advances it only after its gates pass) + a **public registry** make auto-follow responsible for strangers. These are also the **fallback** if `newest-build` cannot read `created` timestamps from `gitactions.est1908.top` — verified early in the plan.
- **Retire the cross-repo bump only after Image Updater is proven on homelab**, so the current manual-merge fallback survives the transition. If `newest-build` fails, keep the bump (and the manual merge) while pivoting to the gated-`stable` path.

### 6. Personal-lab fork-out

The private repo `agentops-platform-homelab` (in `est1908-agentic-ops`) is created and empty. Sub-project 1:

1. Push the **current, pre-scrub** state of this repo (real repoURL, real secrets, real domain) to `agentops-platform-homelab`.
2. Re-point the live cluster's ArgoCD: the `root` Application's `repoURL` and the ArgoCD repository credential move to `agentops-platform-homelab`. Verify all Applications `Synced/Healthy` against the new repo.
3. Only after the live cluster is confirmed running off `agentops-platform-homelab` does this repo get scrubbed into the generic template.

Ordering is load-bearing: migrate first, scrub second, so the live cluster is never pointed at a repo mid-scrub.

## Failure modes

- **Adopter deploys with placeholders unfilled** → `check-customized.sh` (CI, once `.template` is deleted) fails the build before the manifests reach a cluster. The `.template` sentinel makes the template repo itself exempt.
- **Template repo's own CI** → green with placeholders present, because `.template` is present and the check skips. No false failures on the canonical template.
- **A bad engine build auto-deploys** → recovery is imperative (pin the sha in Image Updater / patch the Application's parameter), not `git revert`, since the engine version isn't in git. Fix-forward is usually faster on a homelab. A gated `stable` channel removes the exposure for adopters.
- **Public engine registry down / not yet migrated** → engine pulls fail; platform components (public Helm charts) still reconcile. This is the batteries-included coupling, mitigated by using a reliable public registry (the prerequisite).
- **Scrub breaks the personal lab** → prevented by sequencing: the lab is migrated to `agentops-platform-homelab` and verified healthy *before* the scrub touches this repo.
- **Image Updater can't reach the registry** → it can't discover newer images, so the last-applied engine version keeps running (no disruption). Surfaces in its logs; the gated-`stable` / public-registry path is the fallback.
- **`newest-build` can't read `created` timestamps from `gitactions.est1908.top`** → no auto-updates; caught by the plan's early verification. Fallback: keep the cross-repo bump + manual merge and pivot the engine to a gated `stable` tag (digest strategy).

## Verification

- **Template self-check:** with `.template` present, CI is green while placeholders remain; `scripts/check-customized.sh` reports "template not customized."
- **Round-trip:** clone the template → delete `.template` → run the `customize-instance` skill (and separately the manual runbook) with test values → create dummy secrets from `*.example.yaml` → `check-customized.sh` passes (no tokens left) → `scripts/validate-manifests.sh` passes → a throwaway bootstrap reaches all Applications `Synced/Healthy` (or at minimum ArgoCD renders every Application).
- **Personal-lab migration:** after re-point, `kubectl get applications -n argocd` shows all `Synced/Healthy` against `agentops-platform-homelab`; scrubbing this repo has no effect on the live cluster.
- **Engine updates (commit-free):** Image Updater detects the newest build in the registry and patches the live `engine` Application's Helm parameters (no git commit anywhere); pods roll to the new sha. Rollback verified by pinning a prior sha and confirming the rollout reverts. Early check: confirm Image Updater reads `created` timestamps from `gitactions.est1908.top`.

## Rollout

Sub-projects, each getting its own implementation plan, in order:

1. **Personal-lab fork-out** — ✅ **done** (2026-07-23). The live cluster now syncs from `agentops-platform-homelab`; this repo is free to become the template.
2. **Homelab engine auto-update** — deploy ArgoCD Image Updater on homelab (`newest-build`, all four images, **`argocd` commit-free write-back**), verify it detects and rolls a new build with imperative rollback, then **retire the cross-repo bump** in agentops-engine. Immediate priority — ends the manual bump-merging. Depends on `newest-build` reading `created` timestamps from `gitactions.est1908.top` (verified first; gated-`stable` is the fallback).
3. **Template-ization of this repo** — introduce the `__TOKEN__` placeholders, replace `secrets/**` with `*.example.yaml`, add the `.template` sentinel + `scripts/check-customized.sh`, fix the CI runner, bake in Image Updater as a parameterized platform component (commit-free), write the `customize-instance` skill, rewrite the docs, and flip the repo **public** + enable the GitHub template setting.
4. **Engine public-registry migration** (agentops-engine side) — publish engine + project-worker artifacts to a public registry and advance a gated `stable` channel tag. Makes the template batteries-included for outside adopters; parallelizable with 3.
