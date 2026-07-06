# Agent rules — agentops-platform (GitOps / ArgoCD)

This repo is an ArgoCD app-of-apps. The `root` Application (`bootstrap/root-app.yaml`)
renders every child Application under `clusters/ops/`. ArgoCD syncs from
`origin/main`, so a broken manifest merged to `main` breaks the live cluster even if
the branch you tested from looked fine.

## Git repo references MUST use the SSH URL

Every ArgoCD `Application` (and the `root` app) must reference this repo as:

```yaml
repoURL: git@github.com:flair-hr/agentops-platform.git
```

- The repo is **private**. ArgoCD only has an **SSH** repository credential
  registered (`repo-flair-hr-agentops` secret). There is **no HTTPS credential**.
- Using `https://github.com/flair-hr/agentops-platform.git` makes ArgoCD fail with
  `authentication required: Repository not found` — the app shows `Sync: Unknown`
  and silently stops reconciling (health may still read "Healthy" vacuously).
- When adding or copying an `application.yaml`, always match the SSH `repoURL` used
  by the existing apps. Do not paste the GitHub browser (HTTPS) URL.

Quick check before committing any new/edited Application:

```bash
grep -rn "repoURL" --include="*.yaml" clusters/ bootstrap/ | grep -v 'git@github.com'
# ^ must return nothing
```

## Working conventions

- ArgoCD watches `main`. After merging, verify with `kubectl get applications -n argocd`
  that new/changed apps are `Synced / Healthy` — don't assume merge == deployed.
- Cut fix branches from `origin/main` (not from stale local branches — they may lack
  recently merged apps).
- Cluster access from the bootstrap host: `k3s.yaml` is root-only; copy it to
  `~/.kube/config` (`sudo cat ... > ~/.kube/config && chmod 600`) and export
  `KUBECONFIG` per shell. No `gh` CLI / GitHub token here — open & merge PRs in the UI.
