# CI on Self-Hosted Runners — Design

Status: draft · 2026-07-08 · Owner: Artem

## Context

`.github/workflows/lint.yaml` runs `shellcheck`, `manifests`, and `render` on GitHub-hosted `ubuntu-latest`. `docs/BOOTSTRAP.md` already decided (M2) that a GitHub Actions self-hosted runner runs directly on the bootstrap host, and `docs/DEPLOY.md` listed getting one online as out-of-scope/pending work. A runner is now registered and online (label: `self-hosted`), so this repo's CI can move onto it.

## Goal

All three `lint.yaml` jobs run on the self-hosted runner. `docs/DEPLOY.md`/`docs/BOOTSTRAP.md` no longer describe the runner as pending.

## Non-goals

- Runner installation/registration itself — already done by the operator, outside this repo's scope (per BOOTSTRAP.md's existing decision).
- Changing the `SOPS_AGE_KEY` secret flow in the `render` job — stays a GitHub repo secret, not read from the host's `/var/lib/agentops/age.key`. Self-hosted is a change of execution environment only, not a trust-boundary change.
- Handling multi-runner/concurrency scaling — only one runner exists; the three jobs (no `needs:` between them) will queue and run sequentially instead of in parallel. Acceptable slowdown, not addressed here.

## Design

In `.github/workflows/lint.yaml`, change `runs-on: ubuntu-latest` to `runs-on: self-hosted` on all three jobs (`shellcheck`, `manifests`, `render`). No other step logic changes.

Add one guard to the `shellcheck` job: GitHub's `ubuntu-latest` image bundles `shellcheck` preinstalled, but a self-hosted runner isn't guaranteed to have it, so install it if missing before running:

```yaml
- name: Ensure shellcheck is installed
  run: command -v shellcheck || sudo apt-get update && sudo apt-get install -y shellcheck
```

The `manifests` job only uses `grep`/`find`/bash (see `scripts/validate-manifests.sh`), and the `render` job already installs its own toolchain (kustomize/helm/sops/ksops) as a step — neither needs a new guard.

Update docs to match reality: `docs/DEPLOY.md`'s "What comes next (out of scope for this doc)" list drops the "GitHub Actions self-hosted runner on the host (operator-managed)" bullet (done, not pending). `docs/BOOTSTRAP.md`'s "Decisions already made" bullet about the runner gets a trailing note that it's live and CI now runs on it as of 2026-07-08.
