# CI on Self-Hosted Runners Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `.github/workflows/lint.yaml`'s three CI jobs from GitHub-hosted `ubuntu-latest` onto the now-online self-hosted runner (label `self-hosted`), and reconcile the two docs that still describe that runner as pending work.

**Architecture:** Pure config change — no application logic. One workflow YAML edit (`runs-on:` + a `shellcheck`-presence guard) and two doc edits (`docs/DEPLOY.md`, `docs/BOOTSTRAP.md`) to stop describing the runner as future work. Spec: `docs/superpowers/specs/2026-07-08-ci-self-hosted-runners-design.md`.

**Tech Stack:** GitHub Actions YAML, bash, Markdown.

---

### Task 1: Point `lint.yaml` at the self-hosted runner

**Files:**
- Modify: `.github/workflows/lint.yaml`

- [ ] **Step 1: Confirm the current state**

```bash
grep -n "runs-on" .github/workflows/lint.yaml
```

Expected output (3 matches, all `ubuntu-latest`):

```
10:    runs-on: ubuntu-latest
20:    runs-on: ubuntu-latest
33:    runs-on: ubuntu-latest
```

- [ ] **Step 2: Switch all three jobs to the self-hosted runner**

Replace each of the three `runs-on: ubuntu-latest` lines with `runs-on: self-hosted`. The full updated file:

```yaml
name: Lint

on:
  pull_request:
  push:
    branches: [main]

jobs:
  shellcheck:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v5
      - name: Ensure shellcheck is installed
        run: command -v shellcheck || (sudo apt-get update && sudo apt-get install -y shellcheck)
      - name: shellcheck
        run: shellcheck bootstrap/bootstrap.sh scripts/validate-manifests.sh

  manifests:
    # Static manifest checks that need no secrets: SSH-only repoURLs and that every
    # KSOPS-referenced encrypted secret file exists. Catches the mistakes that have
    # broken the live cluster on merge (see scripts/validate-manifests.sh).
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v5
      - name: validate manifests (static)
        run: ./scripts/validate-manifests.sh

  render:
    # Full `kustomize build --enable-helm` render of every app -- the strongest check
    # (catches bad Helm values, missing chart keys, template errors). It needs the SOPS
    # age identity to decrypt KSOPS secrets, so it only runs when the SOPS_AGE_KEY repo
    # secret is configured; otherwise it skips with a notice. To enable: add the age
    # private key (the same one bootstrap wires into the ArgoCD repo-server) as the repo
    # secret SOPS_AGE_KEY.
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v5

      - name: Detect age key
        id: agekey
        env:
          SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
        run: |
          if [ -n "${SOPS_AGE_KEY:-}" ]; then
            echo "present=true" >> "$GITHUB_OUTPUT"
          else
            echo "present=false" >> "$GITHUB_OUTPUT"
            echo "::notice::Full render skipped -- set the SOPS_AGE_KEY repo secret to enable kustomize build --enable-helm across all apps."
          fi

      - name: Install kustomize, helm, sops, ksops
        if: steps.agekey.outputs.present == 'true'
        run: |
          set -euo pipefail
          # helm
          curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
          # kustomize
          curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
          sudo mv kustomize /usr/local/bin/
          # sops
          SOPS_VER=v3.9.4
          sudo curl -fsSL -o /usr/local/bin/sops \
            "https://github.com/getsops/sops/releases/download/${SOPS_VER}/sops-${SOPS_VER}.linux.amd64"
          sudo chmod +x /usr/local/bin/sops
          # ksops kustomize exec plugin
          curl -fsSL "https://raw.githubusercontent.com/viaduct-ai/kustomize-sops/master/scripts/install-ksops-archive.sh" | bash

      - name: Render all apps
        if: steps.agekey.outputs.present == 'true'
        env:
          SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
        run: |
          set -euo pipefail
          rc=0
          while IFS= read -r kfile; do
            dir=$(dirname "$kfile")
            echo "== rendering $dir =="
            if ! kustomize build --enable-helm "$dir" >/dev/null; then
              echo "::error::kustomize build failed for $dir"
              rc=1
            fi
          done < <(find clusters -name kustomization.yaml | sort)
          exit "$rc"
```

- [ ] **Step 3: Validate YAML syntax locally**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/lint.yaml'))" && echo "YAML OK"
```

Expected output: `YAML OK` (no traceback).

- [ ] **Step 4: Confirm the runner switch and new guard step landed**

```bash
grep -n "runs-on" .github/workflows/lint.yaml
grep -n "Ensure shellcheck is installed" .github/workflows/lint.yaml
```

Expected: 3x `runs-on: self-hosted`, and one hit for the new step name.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/lint.yaml
git commit -m "ci: move lint workflow to the self-hosted runner"
```

---

### Task 2: Reconcile docs that still describe the runner as pending

**Files:**
- Modify: `docs/DEPLOY.md`
- Modify: `docs/BOOTSTRAP.md`

- [ ] **Step 1: Confirm current text in both files**

```bash
grep -n "self-hosted runner" docs/DEPLOY.md docs/BOOTSTRAP.md
```

Expected output includes:

```
docs/DEPLOY.md:769:- GitHub Actions self-hosted runner on the host (operator-managed)
docs/BOOTSTRAP.md:32:- **GitHub Actions self-hosted runner runs directly on the host, not as a k3s workload.** ...
```

- [ ] **Step 2: Remove the stale "pending" bullet from `docs/DEPLOY.md`**

In the `## What comes next (out of scope for this doc)` section, delete this line entirely (it's done, not pending):

```markdown
- GitHub Actions self-hosted runner on the host (operator-managed)
```

- [ ] **Step 3: Add a "now live" note to `docs/BOOTSTRAP.md`**

Find this existing bullet under "Decisions already made (do not relitigate during implementation)":

```markdown
- **GitHub Actions self-hosted runner runs directly on the host, not as a k3s workload.** Product CI (e.g. `docker compose`-based e2e steps) needs a Docker daemon the host already has; running the runner in-cluster would need a privileged DinD sidecar or a host-docker-socket mount, both of which undo the isolation the cluster is otherwise used for. Runner install/config is operator-managed, outside `bootstrap.sh`'s scope.
```

Append one sentence to the end of that same bullet (still inside the bold-lead-in paragraph, same line):

```markdown
- **GitHub Actions self-hosted runner runs directly on the host, not as a k3s workload.** Product CI (e.g. `docker compose`-based e2e steps) needs a Docker daemon the host already has; running the runner in-cluster would need a privileged DinD sidecar or a host-docker-socket mount, both of which undo the isolation the cluster is otherwise used for. Runner install/config is operator-managed, outside `bootstrap.sh`'s scope. As of 2026-07-08 the runner is live and registered (label `self-hosted`); `agentops-platform`'s own CI (`.github/workflows/lint.yaml`) now runs on it too.
```

- [ ] **Step 4: Verify the edits**

```bash
grep -n "self-hosted runner" docs/DEPLOY.md docs/BOOTSTRAP.md
```

Expected: the `docs/DEPLOY.md` hit from Step 1 is now gone; `docs/BOOTSTRAP.md`'s bullet now also matches `now live and registered`.

```bash
grep -c "now live and registered" docs/BOOTSTRAP.md
```

Expected: `1`.

- [ ] **Step 5: Commit**

```bash
git add docs/DEPLOY.md docs/BOOTSTRAP.md
git commit -m "docs: reflect that the self-hosted CI runner is live"
```

---

### Task 3: Open the PR, pass CI, and resolve the Bugbot review

**Files:** none (integration / review).

> Sequential and partly asynchronous — CI and Bugbot run on the remote PR.
> **HARD GATE: Do not mark this task complete until ALL Bugbot comments are
> resolved (fixed or replied to) AND CI is green. Check with
> `gh pr view --json reviews,comments` before claiming done.**

- [ ] **Step 1: Sync the latest `main`**

```bash
git fetch origin
git merge origin/main
grep -rn "repoURL" --include="*.yaml" clusters/ bootstrap/ | grep -v 'https://github.com'   # must return nothing; resolve conflicts + commit first if any
```

- [ ] **Step 2: Push and open the PR**

```bash
git status --short && git rev-parse --abbrev-ref HEAD   # clean tree, on feature branch (not main)
git push -u origin HEAD
gh pr create --base main --fill --title "ci: move lint workflow to self-hosted runner"
```

- [ ] **Step 3: Subagent code review**

REQUIRED SUB-SKILL: `requesting-code-review`. Dispatch a code reviewer subagent (BASE_SHA = merge-base with `main`, HEAD_SHA = HEAD). Fix Critical and Important findings, commit, push, then proceed.

- [ ] **Step 4: Make every CI check pass**

```bash
gh pr checks --watch
```

On failure: `gh run view --log-failed`, reproduce locally, fix, commit, push, re-watch. Do not proceed while red. Note: this is the first PR to run on the self-hosted runner — if the job never picks up (stuck "Queued"), check the runner is online (`Settings > Actions > Runners` in the GitHub UI) before assuming the workflow itself is broken.

- [ ] **Step 5: Wait for the Bugbot review**

```bash
gh pr view --json reviews,comments
gh pr comment --body "bugbot run"   # only if it hasn't reviewed yet
```

- [ ] **Step 6: Address each Bugbot comment**

REQUIRED SUB-SKILL: `receiving-code-review`. Verify before acting — reply to false positives; TDD-fix real findings, commit each referencing the finding, push once.

**Then mark each addressed thread resolved** (completion is gated on the unresolved-thread count, not just on having replied/fixed):

```bash
# List unresolved threads, then resolve each addressed one by id:
gh api graphql -f query='query($o:String!,$r:String!,$p:Int!){repository(owner:$o,name:$r){pullRequest(number:$p){reviewThreads(first:100){nodes{id isResolved path comments(first:1){nodes{body}}}}}}}' -F o=est1908-agentic-ops -F r=agentops-platform -F p=<number>
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -F id=<thread-id>
```

**After pushing:** return to Step 4 (re-watch CI), then Step 5 (wait for re-review). Loop until Bugbot reports no unresolved comments.

- [ ] **Step 7: Final verification**

```bash
gh pr checks                          # all green
gh pr view --json reviews,comments    # no comment left unaddressed
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/lint.yaml'))" && echo "YAML OK"
```

Confirm no unresolved review threads remain, then mark this task complete.
