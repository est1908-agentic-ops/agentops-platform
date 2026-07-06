# Observability Stack (Alloy + LGTM + MailPit) — Design

Status: draft · 2026-07-07 · Owner: Artem
Milestone: M4, sub-project 1 of 5 (see [decomposition](../../../../agentops-engine/docs/superpowers/specs/2026-07-06-m4-decomposition.md) in `agentops-engine`)

## Context

M4's gate needs trace/log/workflow-history walkability without `kubectl`, cost-per-PR as a Grafana panel, and Mission Control's live log tail — all of it downstream of this sub-project standing up the actual observability infrastructure. Nothing in `clusters/ops/platform/` today ships logs, metrics, or traces anywhere; Temporal's chart even has its bundled `prometheus`/`grafana` subcharts explicitly disabled with a comment pointing at this milestone. This doc stands up real ones.

## Goal

`kubectl get applications -n argocd` shows `alloy`, `prometheus`, `loki`, `tempo`, `grafana`, `mailpit` all `Synced`/`Healthy`; `https://grafana.lab` renders with Prometheus/Loki/Tempo already wired as datasources; `agentops-engine`'s OTel instrumentation (sub-project 2) has a concrete OTLP endpoint to target.

## Non-goals

- Grafana dashboards themselves (active tasks, cost/PR, tok/s) — sub-project 4, needs this sub-project's data sources live first.
- Wiring MailPit into any actual product/agent flow — unused until M7's QASquad/ProductProbe, per the decomposition doc's explicit non-goal.
- Alertmanager rules, Prometheus recording/alerting rules — no alerts are designed yet anywhere in this stack; standing up alerting infra with nothing to alert on is scope creep.
- Refining the `dev-agents` `NetworkPolicy`'s egress to name this stack's Service specifically — that policy's CIDR/FQDN rules are already an acknowledged todo-during-implementation from the M2 platform-components design, and k3s's flannel CNI doesn't enforce `NetworkPolicy` today anyway (named risk there, not re-litigated here). Flagged again under Open questions.

## Design

Same pattern as every existing platform component: one ArgoCD `Application` + Kustomize `helmCharts:` inflator + `values.yaml` under `clusters/ops/platform/<component>/`, registered in `clusters/ops/kustomization.yaml`. All six land in the existing shared `platform` namespace (same as Temporal/Postgres) rather than one namespace each (unlike cert-manager/step-ca/technitium) — these are core platform services with no PKI/DNS-style isolation need, and six more namespaces would be sprawl for no isolation benefit at this scale.

```
clusters/ops/platform/
  prometheus/   application.yaml  kustomization.yaml  values.yaml
  loki/         application.yaml  kustomization.yaml  values.yaml
  tempo/        application.yaml  kustomization.yaml  values.yaml
  alloy/        application.yaml  kustomization.yaml  values.yaml
  grafana/      application.yaml  kustomization.yaml  values.yaml
  mailpit/      application.yaml  kustomization.yaml  deployment.yaml  service.yaml  ingress.yaml
```

### Chart choices and pins

| Component | Chart | Version | Mode |
|---|---|---|---|
| Prometheus | `prometheus-community/prometheus` | 29.14.0 | Plain server (no Operator/CRDs — nothing else here needs `ServiceMonitor`) |
| Loki | `grafana/loki` | 6.55.0 | `SingleBinary`, filesystem storage — this cluster's log volume doesn't need object storage or the read/write split |
| Tempo | `grafana/tempo` | 1.24.4 | Chart is single-binary-only by design; `storage.trace.backend: local` (default) |
| Alloy | `grafana/alloy` | 1.10.0 | Default DaemonSet controller |
| Grafana | `grafana-community/grafana` | 12.7.2 | — (the `grafana/helm-charts` repo's own chart is `deprecated: true`; migrated here, see below) |
| MailPit | none (no official chart, same reasoning as Technitium) | image `axllent/mailpit:v1.30.3` | plain Deployment/Service, no persistence — trap data doesn't need to survive restarts |

Bitnami is deliberately avoided (same reasoning as Postgres's `kustomization.yaml` comment: 2025's repackaging pulled pinned versioned images from free access) — none of these five needed it anyway; all are maintained directly by Grafana Labs or prometheus-community.

### Prometheus

Chart defaults already ship `kubernetes-pods`/`kubernetes-service-endpoints` scrape jobs keyed off `prometheus.io/scrape` pod/service annotations — this is how "scrapes k3s/Temporal/LiteLLM exporters" (ARCHITECTURE.md §5.6) happens without hand-written scrape configs, *if* those pods carry the annotation. Confirmed via `kustomize build --enable-helm` against the live `temporal/` component: the `temporal-frontend`, `temporal-history`, and `temporal-worker` Deployments all carry `prometheus.io/scrape: "true"` + `prometheus.io/port: "9090"`, so those three are scraped with zero further work. The `temporal-matching` Deployment carries neither — a real, narrow gap, named below rather than the broader Temporal-wide uncertainty this doc originally carried. `alertmanager.enabled: false` and `prometheus-pushgateway.enabled: false` (nothing pushes to it, no alert rules exist yet); `kube-state-metrics` and `prometheus-node-exporter` stay on (chart defaults) since they're exactly what answers ARCHITECTURE.md's "is the platform healthy" question at negligible extra footprint. Server persistence via the chart's default PVC (no explicit `storageClassName`, matching Postgres/Tempo's reliance on the cluster's default StorageClass).

### Loki

`deploymentMode: SingleBinary`, `auth_enabled: false` (no multi-tenancy need), `loki.storage.type: filesystem`, a `schemaConfig` pinned to `tsdb`/`v13`/filesystem (the chart's own `testSchemaConfig` shows this exact shape; a real install needs it spelled out rather than using the test-schema escape hatch). `gateway`, `minio`, `test`, `lokiCanary` all disabled — SingleBinary mode has one backend to talk to directly, so the nginx read/write-split gateway is pure overhead, and canary/test pods are noise on a single-tenant lab install with nothing else scraping them for validation.

### Tempo

Chart defaults (single-binary, local trace storage, OTLP grpc+http receivers pre-configured on 4317/4318) are used almost as-is. `persistence.enabled: true` added — traces are exactly the kind of "what did the agent think/spend" forensic data (ARCHITECTURE.md §5.6) that should survive a pod restart, matching why Postgres/Technitium/Grafana below all get persistent storage instead of `emptyDir`.

### Alloy

Two jobs, per ARCHITECTURE.md §5.4/§5.6: receive OTLP (traces, from sub-project 2's future instrumentation) and route to Tempo; tail every pod's container logs cluster-wide and route to Loki (this is how "stdout/stderr → Alloy" happens with zero code changes in the worker/agent-runner — sub-project 2 only has to add span instrumentation, not log-shipping code). Config, in Alloy's River language via `alloy.configMap.content`:

- `otelcol.receiver.otlp` (grpc :4317, http :4318) → `otelcol.exporter.otlp` pointed at `tempo.platform.svc.cluster.local:4317` (insecure — in-cluster only, no TLS between Alloy and Tempo, matching every other in-cluster service-to-service call in this stack today).
- `discovery.kubernetes` (role: pod) → `discovery.relabel` (namespace/pod/container labels) → `loki.source.kubernetes` (API-based log tailing, not hostPath/DaemonSet log-file scraping — simpler chart RBAC, and at this cluster's single-node/lab scale the API-tailing approach's throughput ceiling isn't a real constraint) → `loki.write` to `loki.platform.svc.cluster.local:3100`.

`alloy.extraPorts` adds the 4317/4318 container+Service ports (the chart doesn't infer ports from the River config). Default chart RBAC already covers both `discovery.kubernetes` and `loki.source.kubernetes`'s required verbs — no RBAC changes needed.

**OTLP endpoint contract for sub-project 2:** `alloy.platform.svc.cluster.local:4317` (grpc). This is the concrete value that unblocks OTel instrumentation in `agentops-engine`.

### Grafana

`datasources` values block declares Prometheus/Loki/Tempo statically (all three addresses are known at deploy time — no sidecar-watch complexity needed, matching the "simplicity over machinery" call the Postgres component made). `sidecar.dashboards.enabled: true` so sub-project 4 can drop `grafana_dashboard`-labeled ConfigMaps later with no further Grafana redeploy. `admin.existingSecret: grafana-credentials` (KSOPS-decrypted, same mechanism as `postgres-credentials`) instead of the chart's own auto-generated-password default — keeps every credential in this repo behind the same SOPS discipline rather than "check `kubectl get secret` for the one Grafana auto-generated." `persistence.enabled: true` (dashboards/settings survive restarts). `ingress.enabled: true`, host `grafana.lab`, no TLS/annotation block — same bare pattern Temporal's `temporal.lab` Ingress uses today (confirmed via `kustomize build --enable-helm` against the live `temporal/` component); whatever makes `https://temporal.lab` present a step-ca cert apparently isn't a per-Ingress annotation, so this doesn't invent a new pattern, just follows the existing one.

### MailPit

Deployment (image `axllent/mailpit:v1.30.3`, SMTP on 1025, web UI/API on 8025) + Service + Ingress at `mail.lab`, same shape as Technitium's raw-manifest component (no chart exists). No PVC — MailPit's own `--db-file` persistence isn't needed until M7 wires real QASquad/ProductProbe email-verification flows against it; until then it's a disposable trap.

## Testing strategy

`kustomize build --enable-helm` for every new component directory, asserted not to error — same convention as the platform-components design doc, verified locally (helm/kustomize confirmed installed this pass). No cluster access from this sandbox, so `Synced`/`Healthy` status, the actual `grafana.lab` render, and the Prometheus-scrapes-Temporal assumption above are **not** verified end-to-end here — that's an operator step against the real cluster, called out explicitly rather than implied by a passing render check.

## Named risks

- **`temporal-matching` has no `prometheus.io/scrape` annotation** (confirmed by rendering — see above), unlike `frontend`/`history`/`worker`, so it alone stays unscraped. Fix is a small follow-up (an explicit static scrape job in `prometheus/values.yaml` targeting the `temporal-matching` Service, or a `podAnnotations` override in `temporal/values.yaml`), not a blocker to shipping this stack. LiteLLM doesn't exist until M5, so its scrape-annotation status is genuinely unknown rather than checkable today.
- **`loki.source.kubernetes`'s API-based log tailing puts continuous watch load on the kube-apiserver proportional to pod count.** Fine at this cluster's current single-digit-namespace scale; if pod count grows enough for this to matter, the standard fallback is switching to hostPath-based `loki.source.file` tailing on the Alloy DaemonSet — noted here so it isn't rediscovered from scratch later.
- **Same `dev-agents` NetworkPolicy gap platform-components already named**: nothing here scopes egress from `dev-agents` (worker/agent-runner Jobs) to `platform`'s new Alloy Service specifically, and flannel doesn't enforce `NetworkPolicy` regardless. Aspirational until the CNI swap that doc already flagged happens.

## Package/file summary

- **New:** `clusters/ops/platform/{prometheus,loki,tempo,alloy,grafana,mailpit}/*`.
- **New:** `secrets/grafana/.gitkeep` (real SOPS-encrypted `grafana-credentials.enc.yaml` is an operator step, same as Postgres's Phase 0.3 — this doc's implementation cannot generate it without the platform age key).
- **Changed:** `clusters/ops/kustomization.yaml` (six new resources), `docs/DEPLOY.md` (new phase covering the Grafana secret runbook step and the OTLP endpoint contract).

## Open questions carried forward

- Add a scrape job or `podAnnotations` override for `temporal-matching` so all four Temporal Deployments are covered, not just three.
- `grafana/grafana`'s chart is `deprecated: true` as of the version this doc originally pinned (10.5.15) — its README states migration to `grafana-community/helm-charts` after 2026-01-30. Repinned to `grafana-community/grafana` 12.7.2 before merge; flagged here so the reasoning survives in-doc rather than only in the PR history.
- `dev-agents` NetworkPolicy egress refinement for the new Alloy Service — carried forward from the platform-components design doc, not resolved here.
- Whether Alloy should also collect Temporal/LiteLLM's own logs via the same `loki.source.kubernetes` path (it already will, being cluster-wide) or needs anything backend-specific (e.g., structured-log parsing stages) — deferred until real log volume shows whether raw text is good enough for Mission Control's run-detail tail (sub-project 5).
