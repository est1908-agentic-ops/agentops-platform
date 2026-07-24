# Personal-Lab Fork-Out to `agentops-platform-homelab` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan spans two environments.** Tasks 1–2 run **locally** (git + `gh`, this Mac). Tasks 3–4 run **on the bootstrap host** (`kubectl`/ArgoCD as root; `k3s.yaml` copied to `~/.kube/config`, `KUBECONFIG` exported — see CLAUDE.md). A single agent on the Mac **cannot** do Tasks 3–4; hand those to the operator on the bootstrap host (or an agent running there).

**Goal:** Move the live personal-lab cluster off this repo and onto a dedicated `agentops-platform-homelab` repo, so this repo is free to become the generic template (sub-project 2) without breaking the running cluster.

**Architecture:** Same cluster, same age key, same encrypted secrets, same domain — only the *repo home* changes. Seed `agentops-platform-homelab` with this repo's full history, rewrite every ArgoCD `repoURL` to the homelab repo, register the homelab repository credential in ArgoCD, then re-point the live `root` Application at homelab and verify the whole fleet stays `Synced/Healthy`. Because the manifests are byte-identical except for `repoURL`, re-pointing causes **no workload redeploy**.

**Tech Stack:** ArgoCD (app-of-apps), k3s, KSOPS/age (SOPS), kustomize, `gh`/`git`, `kubectl`.

## Global Constraints

- Every ArgoCD Application `repoURL` MUST be the **HTTPS** GitHub URL, never SSH (`git@github.com:…`). An SSH repoURL fails with `authentication required: Repository not found` and the app silently stops reconciling. (CLAUDE.md; enforced by `scripts/validate-manifests.sh` check 1.)
- This is a **repo-home migration, not a re-key**: the homelab repo carries the **same** `secrets/**` blobs, decrypted by the **same** in-cluster age key (in the `argocd` namespace). Do **not** regenerate the age key or re-encrypt secrets.
- Homelab manifests must stay **byte-identical to current `main` except the `repoURL` host/name**, so ArgoCD sees no resource diff on re-point.
- The OCI `repoURL`s (`oci://gitactions.est1908.top/agentic-ops/{engine,project-worker}`) are a **separate registry source** and MUST be left untouched. Only the `github.com/est1908-agentic-ops/agentops-platform.git` git URLs get rewritten (~19 occurrences: `root-app.yaml`, `cloud-init.yaml`, and the Application manifests). Values files that carry the *domain* (`…est1908.top`) are NOT git URLs and stay as-is — homelab keeps the same domain.
- Both repos are **private**; ArgoCD needs a working credential for the homelab repo before re-pointing.
- **Rollback** at any point: re-point `root`'s `repoURL` back to the original repo (retained, untouched — it becomes the template). Running workloads are unaffected even by a bad re-point: ArgoCD that can't read a repo pauses reconciliation, it does not tear resources down.
- The old repo is `https://github.com/est1908-agentic-ops/agentops-platform.git`; the new repo is `https://github.com/est1908-agentic-ops/agentops-platform-homelab.git` (already created, private, empty).

---

### Task 1: Seed `agentops-platform-homelab` with current history

**Environment:** Local (Mac) — `gh` authenticated as `est1908` (repo scope).

**Files:** none in this repo; creates content in the homelab repo.

**Interfaces:**
- Consumes: current `main` of `agentops-platform` (HEAD after PR #25, `6d36c48`).
- Produces: `agentops-platform-homelab` `main` = full history of `agentops-platform` `main`.

- [ ] **Step 1: Clone the current repo into a scratch dir (authenticated)**

```bash
rm -rf /tmp/homelab-migrate
gh repo clone est1908-agentic-ops/agentops-platform /tmp/homelab-migrate
cd /tmp/homelab-migrate
git checkout main && git pull --ff-only
git log --oneline -1     # expect: 6d36c48 (or newer engine bump) on main
```

- [ ] **Step 2: Add the homelab remote and push full history to its `main`**

```bash
git remote add homelab https://github.com/est1908-agentic-ops/agentops-platform-homelab.git
git push homelab main
```
Expected: `main -> main` (new branch on homelab).

- [ ] **Step 3: Verify homelab has the content and matching HEAD**

```bash
gh repo view est1908-agentic-ops/agentops-platform-homelab --json isEmpty,defaultBranchRef \
  --jq '{isEmpty, head: .defaultBranchRef.name}'
gh api repos/est1908-agentic-ops/agentops-platform-homelab/commits/main --jq '.sha' | cut -c1-7
```
Expected: `isEmpty=false`, `head=main`, and the sha matches Step 1's HEAD.

- [ ] **Step 4: Checkpoint (no commit in this repo)**

Nothing to commit here — the deliverable is the seeded homelab repo. Proceed to Task 2 in the same `/tmp/homelab-migrate` clone.

---

### Task 2: Re-point every `repoURL` in homelab to the homelab repo

**Environment:** Local (Mac), in `/tmp/homelab-migrate`.

**Files (in the homelab clone):** whatever contains the old git URL — the `grep | xargs sed` below is the source of truth. Concretely: `bootstrap/root-app.yaml`, `bootstrap/cloud-init.yaml`, the 14 `clusters/ops/platform/*/application.yaml`, `clusters/ops/engine/application.yaml`, `clusters/ops/engine-secrets/application.yaml`, and `clusters/ops/project-workers-secret/application.yaml`. NOT modified: `clusters/ops/project-workers/applicationset.yaml` (its only `repoURL` is the OCI project-worker chart) and the `values.yaml` files (domain, not a git URL).

**Interfaces:**
- Consumes: homelab `main` from Task 1.
- Produces: homelab `main` where every `github.com/est1908-agentic-ops/agentops-platform.git` is now `…/agentops-platform-homelab.git`; OCI URLs unchanged.

- [ ] **Step 1: Rewrite the git repoURLs (macOS sed) — functional URLs only**

```bash
cd /tmp/homelab-migrate
git checkout -b repoint-homelab
grep -rIl 'est1908-agentic-ops/agentops-platform\.git' . --exclude-dir=.git \
  | xargs sed -i '' 's#est1908-agentic-ops/agentops-platform\.git#est1908-agentic-ops/agentops-platform-homelab.git#g'
```
Note: the pattern `agentops-platform\.git` matches only the `.git` repoURLs, and does **not** match the rewritten `agentops-platform-homelab.git` (no double-apply). OCI `gitactions.est1908.top` URLs are untouched.

- [ ] **Step 2: Verify — no stale git URLs, OCI intact**

```bash
# MUST be empty (no old git URL anywhere):
grep -rIn 'est1908-agentic-ops/agentops-platform\.git' . --exclude-dir=.git
# Should list ~20 rewritten URLs (root-app, cloud-init, every Application, secrets apps, applicationset):
grep -rIn 'est1908-agentic-ops/agentops-platform-homelab\.git' . --exclude-dir=.git | wc -l
# OCI sources unchanged (expect the 2 oci:// lines):
grep -rIn 'oci://gitactions.est1908.top' clusters/ | wc -l
```
Expected: first command prints nothing; second ≥ 18; third = 2.

- [ ] **Step 3: Run the repo's own manifest validator (no SSH URLs, secret files present)**

```bash
bash scripts/validate-manifests.sh
```
Expected: `All manifest checks passed.` (check 1 confirms no SSH repoURLs; the homelab URLs are HTTPS.)

- [ ] **Step 4: Commit and push to homelab `main`**

```bash
git commit -am "chore: re-point ArgoCD repoURLs at agentops-platform-homelab"
git push homelab repoint-homelab:main
```
Expected: fast-forward on homelab `main` (linear — homelab had no other writers).

- [ ] **Step 5: Confirm homelab `main` renders the app-of-apps entrypoint correctly**

```bash
gh api repos/est1908-agentic-ops/agentops-platform-homelab/contents/bootstrap/root-app.yaml \
  --jq '.content' | base64 -d | grep repoURL
```
Expected: `repoURL: "https://github.com/est1908-agentic-ops/agentops-platform-homelab.git"`.

---

### Task 3: Register + validate the homelab repository credential in ArgoCD

**Environment:** **Bootstrap host** (root; `KUBECONFIG` set to the copied `k3s.yaml`).

**Files:** none (creates an in-cluster Secret; not GitOps-managed, same as the existing repo credential).

**Interfaces:**
- Consumes: the existing repository credential secret (for the PAT + username).
- Produces: a `repository`-typed Secret ArgoCD uses to read the homelab repo. Task 4 depends on this being valid.

- [ ] **Step 1: Find the existing repository credential secret name**

```bash
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository \
  -o custom-columns=NAME:.metadata.name,URL:.data.url --no-headers
```
Expected: a secret (per CLAUDE.md, `repo-est1908-agentops`) whose `url` decodes to the old repo. Note its name as `$SRC` below.

- [ ] **Step 2: Copy the PAT + username from it and create the homelab credential**

```bash
SRC=repo-est1908-agentops     # replace with the name from Step 1 if different
PAT=$(kubectl -n argocd get secret "$SRC"      -o jsonpath='{.data.password}' | base64 -d)
USER=$(kubectl -n argocd get secret "$SRC"     -o jsonpath='{.data.username}' | base64 -d)

kubectl -n argocd create secret generic repo-est1908-agentops-homelab \
  --from-literal=type=git \
  --from-literal=url=https://github.com/est1908-agentic-ops/agentops-platform-homelab.git \
  --from-literal=username="$USER" \
  --from-literal=password="$PAT"
kubectl -n argocd label secret repo-est1908-agentops-homelab \
  argocd.argoproj.io/secret-type=repository
```
(The PAT is org-scoped and already works for the old repo in the same org, so it authenticates the homelab repo too.)

- [ ] **Step 3: Validate ArgoCD can actually connect to homelab BEFORE re-pointing anything**

If the `argocd` CLI is available and logged in (preferred — it tests connectivity):
```bash
argocd repo get https://github.com/est1908-agentic-ops/agentops-platform-homelab.git
```
Expected: `CONNECTION STATUS: Successful`.

If no `argocd` CLI, force the repo-server to test the credential via a throwaway app dry-run:
```bash
kubectl -n argocd get secret repo-est1908-agentops-homelab \
  -o jsonpath='{.data.url}' | base64 -d ; echo   # sanity: correct URL
```
and confirm connectivity in the ArgoCD UI (Settings → Repositories → the homelab repo shows **Successful**). **Do not proceed to Task 4 until connectivity reads Successful** — a bad credential is what silently stops reconciliation.

---

### Task 4: Re-point the live `root` Application and verify the fleet

**Environment:** **Bootstrap host** (root; `KUBECONFIG` set).

**Files:** none in git — the live `root` object is patched imperatively. (Its GitOps source `bootstrap/root-app.yaml` in homelab already points at homelab from Task 2, so a future re-bootstrap is consistent.)

**Interfaces:**
- Consumes: validated homelab credential (Task 3), homelab `main` with rewritten URLs (Task 2).
- Produces: the live cluster reconciling entirely from `agentops-platform-homelab`.

- [ ] **Step 1: Record the current state for comparison + rollback**

```bash
kubectl -n argocd get application root -o jsonpath='{.spec.source.repoURL}'; echo   # old repo — note it
kubectl -n argocd get applications -o wide     # snapshot: all should be Synced/Healthy now
kubectl -n dev-agents get pods                 # snapshot: engine worker/gateway/control Running
```
Expected: `root` points at the **old** repo; all applications `Synced/Healthy`; engine pods `Running`.

- [ ] **Step 2: Patch `root` to read from homelab**

```bash
kubectl -n argocd patch application root --type merge -p \
  '{"spec":{"source":{"repoURL":"https://github.com/est1908-agentic-ops/agentops-platform-homelab.git"}}}'
kubectl -n argocd get application root -o jsonpath='{.spec.source.repoURL}'; echo
```
Expected: prints the **homelab** URL.

- [ ] **Step 3: Force a refresh and let root re-render its children**

```bash
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 20
kubectl -n argocd get application root -o wide
```
Expected: `root` returns to `Synced/Healthy` reading from homelab (no resource diff — the child Applications differ only by `repoURL`, which ArgoCD updates in place).

- [ ] **Step 4: Verify every child Application now sources from homelab and is healthy**

```bash
# Every app's repoURL should be the homelab repo (except engine's OCI source line):
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL,REPO2:.spec.sources[*].repoURL
```
Expected: all `Synced` + `Healthy`; `REPO`/`REPO2` show the **homelab** git URL everywhere (the `engine` app additionally lists its unchanged `oci://gitactions.est1908.top/...` source).

- [ ] **Step 5: Confirm no workloads restarted (identical manifests ⇒ no redeploy)**

```bash
kubectl -n dev-agents get pods            # same pods, ages unchanged from Step 1 snapshot
kubectl -n platform get pods              # temporal/postgres/grafana/etc. undisturbed
```
Expected: pod set and ages match the Step 1 snapshot — the migration touched only ArgoCD's source pointer, not running resources.

- [ ] **Step 6 (rollback, only if Steps 3–5 go wrong):**

```bash
kubectl -n argocd patch application root --type merge -p \
  '{"spec":{"source":{"repoURL":"https://github.com/est1908-agentic-ops/agentops-platform.git"}}}'
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```
The old repo is intact, so this restores the prior state immediately. Then diagnose (usual cause: homelab credential not `Successful` in Task 3).

---

## Done when

- [ ] `agentops-platform-homelab` `main` holds the full history with every git `repoURL` pointing at itself (Tasks 1–2).
- [ ] ArgoCD `root` reads from `agentops-platform-homelab` and every application is `Synced/Healthy` against it (Task 4).
- [ ] Engine + platform pods are undisturbed (no redeploy) — verified against the Step 1 snapshot.
- [ ] The original `agentops-platform` repo is untouched and free to become the template in sub-project 2.

## Follow-ups (out of scope here, tracked for later)

- **Sub-project 2 (template-ization)** can now safely scrub this repo: placeholders, `*.example.yaml` secrets, `.template` sentinel + `check-customized.sh`, ArgoCD Image Updater, `customize-instance` skill, docs, flip the repo **public** + enable the GitHub *template* setting.
- Optionally add an `upstream` remote on `agentops-platform-homelab` pointing at the template repo, to pull future base improvements (opt-in upgrade channel per the spec).
