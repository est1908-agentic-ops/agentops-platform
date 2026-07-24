# Homelab Engine Auto-Update (ArgoCD Image Updater, commit-free) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Target repo:** `agentops-platform-homelab` (the live cluster). Manifest edits (Tasks 1, 4) run **locally** against a clone of that repo and land via PR. Cluster verification (Tasks 2–3) runs **on the bootstrap host** (`kubectl`/ArgoCD as root, `KUBECONFIG` set). Task 4 edits the **agentops-engine** repo.

**Goal:** The homelab cluster auto-follows the latest engine build with **no commits to any platform repo**, ending the manual bump-merging.

**Architecture:** Deploy ArgoCD Image Updater as a platform component on homelab. It watches the four engine images in the existing private registry with the `newest-build` strategy and applies the newest sha via **`argocd` (commit-free) write-back** — patching the live `engine` Application's Helm parameters in-cluster. Because the `engine` Application is a child of the `root` app-of-apps (which `selfHeal`s), root must be told to ignore that parameter field or it reverts the update. Once proven, the agentops-engine cross-repo bump is retired.

**Tech Stack:** ArgoCD + Image Updater (argo-helm chart), kustomize `--enable-helm`, k3s, `kubectl`, `gh`/`git`.

## Global Constraints

- **Commit-free:** `write-back-method: argocd`. Image Updater must make **no git commits** to any platform repo.
- **Strategy `newest-build`** on all **four** images (`worker`, `agent-runner`, `control`, `gateway` under `gitactions.est1908.top/agentic-ops`) — the only viable strategy for random git-sha tags; it sorts by each image's registry `created` timestamp.
- Every ArgoCD Application `repoURL` in the homelab repo is the **HTTPS homelab URL** (`https://github.com/est1908-agentic-ops/agentops-platform-homelab.git`), never SSH. (`scripts/validate-manifests.sh` check 1.)
- **Feasibility gate (Task 2):** if Image Updater cannot read `created` timestamps from `gitactions.est1908.top`, STOP and fall back to the gated-`stable` path (engine-side work) — keep the cross-repo bump + manual merge meanwhile. Do not proceed to Task 4.
- **Retire the cross-repo bump (Task 4) only after Task 3 is green**, so the manual-merge fallback survives the transition.
- Engine rollback is **imperative** (pin sha / patch parameter), not `git revert` — the running version lives in the live Application, not git.

## File structure (in the homelab clone)

- Create `clusters/ops/platform/argocd-image-updater/application.yaml` — ArgoCD Application for the component.
- Create `clusters/ops/platform/argocd-image-updater/kustomization.yaml` — renders the argo-helm chart + the cross-namespace RBAC below.
- Create `clusters/ops/platform/argocd-image-updater/values.yaml` — Image Updater config (registries, log level).
- Create `clusters/ops/platform/argocd-image-updater/registry-rbac.yaml` — lets the updater's SA read the pull secret in `dev-agents`.
- Modify `clusters/ops/kustomization.yaml` — add the component.
- Modify `clusters/ops/engine/application.yaml` — Image Updater annotations on the engine app.
- Possibly modify `bootstrap/root-app.yaml` (Task 3, only if the update is reverted by selfHeal).

---

### Task 1: Add Image Updater component + engine annotations to homelab

**Environment:** Local — clone of `agentops-platform-homelab`.

**Interfaces:**
- Produces: an `argocd-image-updater` Application (namespace `argocd`) and Image Updater annotations on the `engine` Application.

- [ ] **Step 1: Clone homelab and branch**

```bash
SCRATCH="$(mktemp -d)"; gh repo clone est1908-agentic-ops/agentops-platform-homelab "$SCRATCH/hl"
cd "$SCRATCH/hl" && git checkout -b feat-image-updater
```

- [ ] **Step 2: Pick the current chart version to pin**

```bash
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm search repo argo/argocd-image-updater --versions | head -3
```
Note the top `CHART VERSION` (e.g. `0.12.4`) — use it as `<CHART_VERSION>` below.

- [ ] **Step 3: Create `clusters/ops/platform/argocd-image-updater/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-image-updater
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/est1908-agentic-ops/agentops-platform-homelab.git
    targetRevision: main
    path: clusters/ops/platform/argocd-image-updater
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Create `clusters/ops/platform/argocd-image-updater/values.yaml`**

`registry-credentials` is the engine's dockerconfigjson pull secret in the `dev-agents` namespace; Image Updater reads it cross-namespace via `pullsecret:` (RBAC granted in Step 6).

```yaml
config:
  logLevel: info
  # newest-build reads each image's `created` timestamp from this registry.
  registries:
    - name: gitactions
      prefix: gitactions.est1908.top
      api_url: https://gitactions.est1908.top
      credentials: pullsecret:dev-agents/registry-credentials
      default: true
```

- [ ] **Step 5: Create `clusters/ops/platform/argocd-image-updater/registry-rbac.yaml`**

The updater's ServiceAccount (`argocd-image-updater`, created by the chart in `argocd`) needs `get` on the pull secret in `dev-agents`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: image-updater-read-registry-creds
  namespace: dev-agents
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["registry-credentials"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: image-updater-read-registry-creds
  namespace: dev-agents
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: image-updater-read-registry-creds
subjects:
  - kind: ServiceAccount
    name: argocd-image-updater
    namespace: argocd
```

- [ ] **Step 6: Create `clusters/ops/platform/argocd-image-updater/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: argocd-image-updater
    repo: https://argoproj.github.io/argo-helm
    version: <CHART_VERSION>   # from Step 2
    releaseName: argocd-image-updater
    namespace: argocd
    valuesFile: values.yaml

resources:
  - registry-rbac.yaml
```

- [ ] **Step 7: Register the component in `clusters/ops/kustomization.yaml`**

Add under `resources:` (next to the other `platform/*/application.yaml` lines):
```yaml
  - platform/argocd-image-updater/application.yaml
```

- [ ] **Step 8: Annotate the `engine` Application** — add to `clusters/ops/engine/application.yaml` under `metadata:` (it currently has only `name`/`namespace`):

```yaml
  annotations:
    argocd-image-updater.argoproj.io/image-list: >-
      worker=gitactions.est1908.top/agentic-ops/worker,
      agent-runner=gitactions.est1908.top/agentic-ops/agent-runner,
      control=gitactions.est1908.top/agentic-ops/control,
      gateway=gitactions.est1908.top/agentic-ops/gateway
    argocd-image-updater.argoproj.io/write-back-method: argocd
    argocd-image-updater.argoproj.io/worker.update-strategy: newest-build
    argocd-image-updater.argoproj.io/worker.helm.image-tag: image.workerTag
    argocd-image-updater.argoproj.io/agent-runner.update-strategy: newest-build
    argocd-image-updater.argoproj.io/agent-runner.helm.image-tag: image.agentRunnerTag
    argocd-image-updater.argoproj.io/control.update-strategy: newest-build
    argocd-image-updater.argoproj.io/control.helm.image-tag: image.controlTag
    argocd-image-updater.argoproj.io/gateway.update-strategy: newest-build
    argocd-image-updater.argoproj.io/gateway.helm.image-tag: image.gatewayTag
```
(No `helm.image-name` params: the chart hardcodes each repository as `{{ .Values.image.repository }}/worker` etc., so only the tag value is written.)

- [ ] **Step 9: Validate + render**

```bash
bash scripts/validate-manifests.sh          # expect: All manifest checks passed.
kustomize build --enable-helm clusters/ops/platform/argocd-image-updater | head -40
#   expect the Image Updater Deployment + the dev-agents Role/RoleBinding to render
```

- [ ] **Step 10: Commit, push, open + merge the PR to homelab**

```bash
git commit -am "feat(platform): ArgoCD Image Updater — commit-free engine auto-update (newest-build)"
git push -u origin feat-image-updater
gh pr create -R est1908-agentic-ops/agentops-platform-homelab --base main --fill
# review, then:
gh pr merge --squash -R est1908-agentic-ops/agentops-platform-homelab
```
Merging is what makes ArgoCD deploy it (homelab is the live source). Proceed to Task 2 on the bootstrap host.

---

### Task 2: Feasibility gate — updater runs and reads registry timestamps

**Environment:** Bootstrap host (`KUBECONFIG` set).

- [ ] **Step 1: Confirm the component synced and the pod is up**

```bash
kubectl -n argocd get application argocd-image-updater      # Synced/Healthy
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-image-updater
```
Expected: application `Synced/Healthy`; pod `Running`.

- [ ] **Step 2: Confirm it authenticated to the registry and can see the four images with timestamps**

```bash
kubectl -n argocd logs deploy/argocd-image-updater --tail=200 \
  | grep -iE 'gitactions|worker|agent-runner|control|gateway|error|credential|tags'
```
Expected: lines showing it queried `gitactions.est1908.top`, found tags for each image, and chose a candidate — **no** auth errors and **no** "could not determine created time" / "no build information" errors.

- [ ] **Step 3: GATE**

- If Step 2 shows it read timestamps, picked candidates, and set params on `sources[0]` → proceed to Task 3.
- If it shows auth errors → the `pullsecret`/RBAC (Task 1 Steps 5–6) is wrong; fix and re-check.
- If it **cannot read `created` timestamps** → **STOP.** `newest-build` is not viable on this registry. Keep the cross-repo bump + manual merge; open a follow-up to pivot the engine to a gated `stable` tag (digest strategy). Do not proceed.
- If it reads timestamps but **errors locating the Helm source / can't set params on the multi-source `engine` app** → the pinned Image Updater version's `argocd` write-back doesn't handle this multi-source shape. Try a newer chart version first; if still broken, this challenges commit-free for this app (last-resort options: restructure `engine` to a single Helm source, or accept `git` write-back for `engine` only) — raise it before proceeding.

---

### Task 3: Verify an update applies, sticks, and can roll back

**Environment:** Bootstrap host (with a local homelab clone available for Step 3b if needed).

**Multi-source note:** the `engine` app uses `spec.sources[]` (OCI chart at index 0 + git values ref). All parameter reads/writes below target `sources[0]` (the chart source), and Image Updater must write its overrides there — confirmed in Task 2 Step 2.

- [ ] **Step 1: Snapshot current engine state**

```bash
kubectl -n dev-agents get pods -o wide | grep -E 'worker|gateway|control'
kubectl -n argocd get application engine -o jsonpath='{.spec.sources[0].helm.parameters}'; echo
```
Note current image sha(s) and whether any `helm.parameters` already exist on `sources[0]`.

- [ ] **Step 2: Trigger a run and watch it write the parameter**

```bash
# Image Updater polls every ~2m; force one now:
kubectl -n argocd rollout restart deploy/argocd-image-updater
sleep 30
kubectl -n argocd logs deploy/argocd-image-updater --tail=100 | grep -iE 'setting|updated|would|already|source'
kubectl -n argocd get application engine -o jsonpath='{.spec.sources[0].helm.parameters}'; echo
```
Expected: `sources[0]` now carries `image.workerTag` (etc.) overrides at the newest sha (or "already up to date"). If Image Updater errors that it can't locate the Helm source on a multi-source app, that's the multi-source gate (see Task 2 Step 3).

- [ ] **Step 3: Confirm the parameter STICKS (root selfHeal does not revert it)**

```bash
sleep 90     # give root a reconcile cycle
kubectl -n argocd get application engine -o jsonpath='{.spec.sources[0].helm.parameters}'; echo
kubectl -n argocd get application root -o jsonpath='{.status.sync.status}'; echo
```
- If the parameters are **still present** → good; skip Step 3b.
- If they were **wiped** (root reverted the child) → do Step 3b, then re-run Step 2–3.

- [ ] **Step 3b (only if reverted): make root ignore the engine app's Helm parameters**

In the homelab clone, add to `bootstrap/root-app.yaml` under `spec:`:
```yaml
  ignoreDifferences:
    - group: argoproj.io
      kind: Application
      jsonPointers:
        - /spec/sources/0/helm/parameters
```
Commit + push + merge to homelab, then apply to the live root object (root is bootstrap-applied, not in `clusters/ops`, so patch it directly):
```bash
kubectl -n argocd patch application root --type merge -p \
  '{"spec":{"ignoreDifferences":[{"group":"argoproj.io","kind":"Application","jsonPointers":["/spec/sources/0/helm/parameters"]}]}}'
```

- [ ] **Step 4: Confirm pods rolled to the new sha**

```bash
kubectl -n dev-agents get pods -o wide | grep -E 'worker|gateway|control'
kubectl -n dev-agents describe pod -l app=engine-worker | grep -i image:
```
Expected: pods restarted onto the newest sha; `Running`/`Ready`.

- [ ] **Step 5: Verify imperative rollback**

```bash
# Pin a known prior sha, confirming rollback works without git. argocd CLI targets
# the chart source cleanly on a multi-source app (--source-position is 1-based, so 1 = sources[0]):
argocd app set engine --helm-set image.workerTag=<PRIOR_SHA> --source-position 1
# (no argocd CLI? JSON-patch sources[0] directly — a merge patch would replace the whole array:)
#   kubectl -n argocd patch application engine --type json -p \
#     '[{"op":"add","path":"/spec/sources/0/helm/parameters","value":[{"name":"image.workerTag","value":"<PRIOR_SHA>"}]}]'
kubectl -n dev-agents rollout status deploy/engine-worker
```
Expected: worker rolls back to `<PRIOR_SHA>`. (Then let Image Updater re-advance, or leave pinned.)

---

### Task 4: Retire the cross-repo bump (after Task 3 is green)

**Environment:** Local — clone of `agentops-engine`.

**Interfaces:**
- Consumes: a proven-working Image Updater on homelab (Tasks 2–3).
- Produces: agentops-engine CI no longer commits engine bumps into `agentops-platform`.

- [ ] **Step 1: Find where the bump runs**

```bash
cd /Users/est1908/work/flair/agentops-engine
git grep -n 'bump-platform-engine-tags' -- .github/ scripts/
```
Expected: a CI workflow step (and the script `scripts/bump-platform-engine-tags.sh`).

- [ ] **Step 2: Remove the CI step (and the script) on a branch**

Delete the workflow step that invokes `scripts/bump-platform-engine-tags.sh` (and any now-unused checkout/push of the platform repo), and `git rm scripts/bump-platform-engine-tags.sh`. Leave the image + chart publishing steps untouched.

- [ ] **Step 3: Verify nothing else references the script**

```bash
git grep -n 'bump-platform-engine-tags\|agentops-platform' -- .github/ scripts/
```
Expected: no remaining references that push to the platform repo.

- [ ] **Step 4: Commit + PR to agentops-engine**

```bash
git checkout -b chore-retire-platform-bump
git commit -am "chore(ci): retire cross-repo platform engine-tag bump (Image Updater owns it now)"
git push -u origin chore-retire-platform-bump
gh pr create -R est1908-agentic-ops/agentops-engine --base main --fill
```

- [ ] **Step 5: Confirm the orphaned bumps stop**

After merge, confirm the next engine merge produces **no** `chore(engine): bump worker images` commit in `agentops-platform`, and homelab still advances via Image Updater.

---

## Done when

- [ ] Image Updater runs on homelab, reads the registry, and applies the newest engine sha commit-free (Tasks 1–2).
- [ ] The update sticks (root does not revert it — `ignoreDifferences` in place if needed) and pods roll; imperative rollback works (Task 3).
- [ ] agentops-engine no longer bumps `agentops-platform`; homelab auto-follows with zero manual merges (Task 4).

## Follow-ups

- **Sub-project 3 (template-ization)** bakes this component into the template as a parameterized copy (registry/image prefixes become tokens), commit-free write-back preserved.
- If Task 2 gated out (no timestamps), pivot the engine to a gated `stable` tag + digest strategy, which also becomes the responsible default for outside adopters.
