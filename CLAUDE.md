# Agent rules — agentops-platform (GitOps / ArgoCD)

This repo is an ArgoCD app-of-apps. The `root` Application (`bootstrap/root-app.yaml`)
renders every child Application under `clusters/ops/`. ArgoCD syncs from
`origin/main`, so a broken manifest merged to `main` breaks the live cluster even if
the branch you tested from looked fine.

## Git repo references MUST use the HTTPS URL

Every ArgoCD `Application` (and the `root` app) must reference this repo as:

```yaml
repoURL: https://github.com/est1908-agentic-ops/agentops-platform.git
```

- The repo is **private**. ArgoCD authenticates over HTTPS with a token-based
  repository credential (`repo-est1908-agentops` secret — `username`/`password`,
  password is a PAT). There is **no SSH deploy key credential** registered for this
  repo in ArgoCD.
- Using `git@github.com:est1908-agentic-ops/agentops-platform.git` makes ArgoCD fail
  with `authentication required: Repository not found` — the app shows `Sync: Unknown`
  and silently stops reconciling (health may still read "Healthy" vacuously).
- When adding or copying an `application.yaml`, always match the HTTPS `repoURL` used
  by the existing apps. Do not paste the SSH (`git@github.com:...`) form.

Quick check before committing any new/edited Application:

```bash
grep -rn "repoURL" --include="*.yaml" clusters/ bootstrap/ | grep -v 'https://github.com'
# ^ must return nothing (the engine chart's oci:// repoURL is a separate,
#   registry-based source and is expected not to match)
```

## Working conventions

- ArgoCD watches `main`. After merging, verify with `kubectl get applications -n argocd`
  that new/changed apps are `Synced / Healthy` — don't assume merge == deployed.
- Cut fix branches from `origin/main` (not from stale local branches — they may lack
  recently merged apps).
- Cluster access from the bootstrap host: `k3s.yaml` is root-only; copy it to
  `~/.kube/config` (`sudo cat ... > ~/.kube/config && chmod 600`) and export
  `KUBECONFIG` per shell. No `gh` CLI / GitHub token here — open & merge PRs in the UI.
