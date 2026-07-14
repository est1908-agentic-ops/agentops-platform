# Remove LiteLLM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove LiteLLM through an engine PR followed by a platform PR, then audit both repositories for low-risk simplification opportunities.

**Architecture:** Remove all engine paths that can invoke the proxy before deleting its GitOps definition. Pin the deployed engine to the merged non-LiteLLM artifact, cascade-delete the Argo CD application, and perform the otherwise unused database cleanup as a guarded PostSync Job.

**Tech Stack:** TypeScript, Zod, Vitest, pnpm, Helm, Kustomize, Argo CD, Kubernetes, SOPS/KSOPS.

---

## Task 1: Create and verify the engine removal

**Files:**
- Delete: `packages/backends/src/litellm/`, `e2e/litellm-routing-and-budget.e2e.test.ts`
- Modify: `packages/backends/src/index.ts`, `packages/contracts/src/model.ts`, `packages/contracts/src/stage.ts`
- Modify: `packages/activities/src/create-activities.{ts,test.ts}`, `packages/worker/src/main.{ts,test.ts}`
- Modify: `packages/workflows/src/dev-cycle.ts`, `packages/control/src/tiers-routes.ts`, `packages/ui/src/pages/TiersPage.tsx`
- Modify: `charts/engine/values.yaml`, `charts/engine/templates/deployment.yaml`, `charts/engine/templates/platform-agent-networkpolicy.yaml`, `charts/engine/tests/render.golden.yaml`

- [ ] Create a linked worktree from `origin/main` on branch `chore/remove-litellm-engine`.
- [ ] Add failing tests proving the model schema rejects backend `litellm`, startup validation succeeds without `LITELLM_API_KEY`, and the tiers route rejects that backend with HTTP 400.
- [ ] Run `pnpm vitest run packages/contracts/src/model.test.ts packages/worker/src/main.test.ts packages/control/src/tiers-routes.test.ts`; confirm the new assertions fail.
- [ ] Delete the backend implementation/export/tests and every associated model enum, budget error, worker setup, environment requirement, workflow branch, control/UI allow-list, Helm setting, secret injection, fixture, and E2E test. Do not replace it with another transport.
- [ ] Run the focused tests again and confirm they pass.
- [ ] Render Helm with `helm template engine charts/engine -f charts/engine/values.yaml > /tmp/engine.yaml`, then confirm `! rg -i 'litellm' /tmp/engine.yaml`.
- [ ] Run `pnpm lint && pnpm typecheck && pnpm test && pnpm e2e`; commit as `refactor: remove litellm engine support`.

## Task 2: Remove engine current documentation and ship its PR

**Files:**
- Delete: `docs/superpowers/specs/2026-07-07-litellm-backend-design.md`
- Modify: root operational docs/diagram that describe a live proxy

- [ ] Remove the dedicated design document and revise current docs/diagram to cover only supported direct providers. Dated historical change records may remain.
- [ ] Verify no runtime/deployment reference remains with `! rg -i 'litellm' -g '!docs/superpowers/**' -g '!node_modules/**' -g '!**/.git/**' .`.
- [ ] Commit documentation cleanup, push the engine branch, create its PR, complete review, CI, Bugbot thread resolution, and merge it. Record the immutable merge SHA/image/chart tag.

## Task 3: Deploy the engine removal before deleting the proxy

**Files:**
- Modify: `clusters/ops/engine/application.yaml`, `clusters/ops/engine/values.yaml`

- [ ] Set the chart revision and every engine image tag to the recorded engine merge SHA.
- [ ] Wait for Argo CD to report `engine` Synced/Healthy. Inspect the live Deployment and worker logs; ensure no `LITELLM_*` environment variable or proxy hostname remains. Stop and investigate if this verification fails.

## Task 4: Remove the platform component and its secrets

**Files:**
- Delete: `clusters/ops/platform/litellm/`, `secrets/litellm/`
- Modify: `clusters/ops/kustomization.yaml`, `clusters/ops/engine-secrets/secret-generator.yaml`, `scripts/validate-manifests.sh`

- [ ] Extend `scripts/validate-manifests.sh` with a case-insensitive deployment check that rejects LiteLLM references under `clusters/`, with an explicit exception only for the database cleanup Job in Task 5.
- [ ] Run the validator and confirm the new check fails before removal.
- [ ] Execute `argocd app delete litellm --cascade` against the live cluster and confirm all proxy resources are gone. Then remove the root child Application, component files, encrypted secrets, and engine-secret generator entry.
- [ ] Run `./scripts/validate-manifests.sh` and `! rg -i 'litellm' clusters/ops secrets`; commit as `chore: remove litellm deployment`.

## Task 5: Drop obsolete database state and update platform documentation

**Files:**
- Create: `clusters/ops/platform/postgres/litellm-cleanup-job.yaml`
- Modify: `clusters/ops/platform/postgres/kustomization.yaml`, `README.md`, `docs/DEPLOY.md`

- [ ] Add a `postgres:16` PostSync Job using `postgres-credentials`, hook policy `HookSucceeded`, and SQL that terminates connections then executes `DROP DATABASE IF EXISTS litellm;` and `DROP ROLE IF EXISTS litellm;`.
- [ ] Add it to the Postgres Kustomization and extend the validator to require its PostSync/HookSucceeded annotations and both guarded SQL drops.
- [ ] Remove LiteLLM’s inventory entry, deployment phase, secret procedure, health checks, and endpoint details from current docs.
- [ ] Run `./scripts/validate-manifests.sh && kustomize build clusters/ops/platform/postgres`; confirm no LiteLLM references remain outside the bounded cleanup Job and historical records. Commit as `chore: clean up litellm state`.

## Task 6: Audit simplification opportunities

**Files:**
- Create: `docs/simplification-audit-2026-07-15.md`

- [ ] Inspect each Argo CD application/component, engine package/image/chart, manifest consumer, and current documentation in both repositories.
- [ ] For every candidate, record its owner, direct consumers, deployment/runtime cost, evidence of active use, and one of: **remove now**, **remove after migration**, or **retain**.
- [ ] Only recommend **remove now** where there are no inbound references and a verified deletion path. Keep uncertain items as **retain** with the evidence still needed.

## Task 7: Open the platform PR, pass CI, and resolve Bugbot

**Files:** none (integration/review).

- [ ] Merge the latest `origin/main`, run `./scripts/validate-manifests.sh`, push the platform branch, and create the PR titled `chore: remove litellm platform deployment`.
- [ ] Use `requesting-code-review`; fix every Critical/Important finding before CI.
- [ ] Run `gh pr checks --watch`. For failures, inspect `gh run view --log-failed`, reproduce/fix/commit/push, and re-watch.
- [ ] Poll `gh pr view --json reviews,comments`; request `bugbot run` only if it has not reviewed. Use `receiving-code-review` for each finding, resolve every addressed review thread through GitHub GraphQL, and repeat CI/re-review until clean.
- [ ] Final evidence: `gh pr checks`, `gh pr view --json reviews,comments`, and `./scripts/validate-manifests.sh` all show the required clean state.
