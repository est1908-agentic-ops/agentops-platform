# `agent_run_stats` Database + Size Monitoring — Design

Status: draft · 2026-07-07 · Owner: Artem
Milestone: M4, sub-project 3 of 5 (see [decomposition](https://github.com/est1908-agentic-ops/agentops-engine/blob/main/docs/superpowers/specs/2026-07-06-m4-decomposition.md) and [engine-side design](https://github.com/est1908-agentic-ops/agentops-engine/blob/main/docs/superpowers/specs/2026-07-07-agent-run-stats-design.md) in `agentops-engine`)

## Context

`agentops-engine`'s worker now persists `agent_run_stats` to Postgres instead of an in-memory `Map` (that repo's own design doc covers the table schema and `PostgresStatsStore`). This repo's half: create the empty database the worker connects to, and — a follow-up ask made mid-implementation — monitor that data's size growth via the observability stack sub-project 1 already stood up.

## Goal

`agent_run_stats` exists as an empty database on the shared Postgres instance before the worker's first startup after this change ships. Its size (and the whole instance's) is queryable in Prometheus/Grafana.

## Non-goals

- The table schema itself — owned by `agentops-engine`'s worker (idempotent `CREATE TABLE IF NOT EXISTS` at startup), not this repo. Same split Temporal already uses: this repo creates empty databases, the owning application creates its own tables.
- A Grafana dashboard panel for the size metrics — sub-project 4. This doc's job is making the metric exist and be queryable via Explore, not building a saved panel.
- A retention/archival policy for `agent_run_stats`'s row growth — named as a real, deliberately-deferred gap in the engine-side design doc, not solved here either.
- A scoped, read-only Postgres role for `postgres-exporter` — it reuses the full-privilege `temporal` credential, same as every other consumer of `postgres-credentials` today. Reasonable for a lab-scale single-tenant cluster (no new secret, matches the existing pattern); a real hardening item if this cluster ever needs least-privilege database access.

## Design

### Database creation: one line in the existing initdb script

`clusters/ops/platform/postgres/initdb-configmap.yaml` gets a `20-agent-run-stats.sql` entry, identical in shape to the existing `10-temporal-visibility.sql` (`CREATE DATABASE ... WHERE NOT EXISTS ...\gexec`). Runs automatically on a fresh bootstrap; **on an already-running cluster it's a manual one-time step** (initdb scripts only execute against an empty data directory) — documented in DEPLOY.md Phase 8 with the exact `CREATE DATABASE` command, same caveat class as `temporal_visibility`'s own manual-step history.

### Size monitoring: `prometheus-community/prometheus-postgres-exporter`

New component, `clusters/ops/platform/postgres-exporter/`, chart `8.1.0` (pinned, same version-discipline sub-project 1 established). Connects directly to `agent_run_stats` (not `temporal`/`postgres`) using the existing `postgres-credentials` secret (`config.datasource.passwordSecret`) — no new secret needed. This single connection choice gets two things at once with no custom queries file:

- `pg_database_size_bytes{datname=...}` for **every** database on the instance — Postgres's `pg_database` catalog is instance-wide regardless of which database the exporter's own connection is scoped to.
- `pg_stat_user_tables_*` (row counts, dead tuples, sequential scans) scoped to whichever database the exporter is connected to — i.e., specifically the `agent_run_stats` table, which is exactly what was asked to be monitored.

Scraped via the same `prometheus.io/scrape`/`prometheus.io/port` Service-annotation convention every other component in this stack uses (plain `prometheus-community/prometheus`, no Operator/`ServiceMonitor` CRD) — `prometheus.io/port: "9187"` matches the exporter's real container port, not its Service's remapped port 80.

### `clusters/ops/engine/values.yaml`

Sets `agentStatsDb.host` (this sub-project) and, while in this file, also `otelExporterOtlpEndpoint` (sub-project 2's cross-repo follow-up, never actually landed here until now — closing a loop rather than leaving a second stale TODO). Both are inert until `agentops-engine`'s CI auto-bumps this repo's pinned chart/image tags to a version that recognizes those chart values — harmless to set ahead of that, same as any other values-ahead-of-chart-version case this repo already accepts.

## Testing strategy

`kustomize build --enable-helm` for the new `postgres-exporter` component and the full root kustomization (confirms no Application name collisions among all 17 now-registered components, post-rebase onto M5's merged `litellm` component). The database creation itself, and whether the exporter's metrics actually populate, can't be verified without a real cluster — same limitation `temporal_visibility` and every prior sub-project's platform-side change already carries.

## Package/file summary

- **New:** `clusters/ops/platform/postgres-exporter/{application,kustomization,values}.yaml`.
- **Changed:** `clusters/ops/platform/postgres/initdb-configmap.yaml` (new DB creation), `clusters/ops/kustomization.yaml` (new Application registered), `clusters/ops/engine/values.yaml` (`agentStatsDb.host` + `otelExporterOtlpEndpoint`), `docs/DEPLOY.md` (Phase 8 + manual-step caveat for already-running clusters).

## Open questions carried forward

- Retention/archival policy for `agent_run_stats` — deferred in both repos' design docs, revisit once the size metrics this doc adds show real growth data.
- A saved Grafana dashboard panel for these size metrics — sub-project 4.
