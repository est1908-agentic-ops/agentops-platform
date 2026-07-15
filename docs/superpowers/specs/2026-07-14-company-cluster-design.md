# Company AgentOps Cluster (Hetzner AX41) — Design

Status: draft · 2026-07-14, rev. 2026-07-15 · Owner: Artem

## Context

The personal AgentOps platform (this repo) runs on a home VPS and has proven the model: ArgoCD app-of-apps, Temporal-backed agent workflows, full observability (Alloy → Loki/Tempo/Prometheus, Grafana), reproducible bootstrap (`bootstrap.sh` / `docs/DEPLOY.md`). Company devs want the same platform for product development, on a company-owned Hetzner AX41 dedicated server (6c/12t Ryzen, 64 GB RAM, 2×512 GB NVMe).

Two concrete use cases drive it:

1. **Rollbar monitor-and-fix** — when Rollbar reports a new/spiking production error, an agent triages it and files a GitHub issue that feeds the existing label-driven dev cycle.
2. **Production telemetry for agents** — the company product (running on AWS) gets OpenTelemetry instrumentation; telemetry lands in AWS-native observability (CloudWatch / X-Ray), and agents investigate it through read-only AWS APIs during triage.

Production traffic volume is unknown; the design must not assume a ceiling.

This spec is the umbrella architecture for three sub-projects (see Rollout). Most implementation lands in the **company platform repo**, not this one; the spec lives here as the design record, per this repo's convention.

## Goal

A company-owned instance of this platform on the AX41 that (a) runs the standard agent workflows for the product repo(s), (b) triages Rollbar errors into GitHub issues automatically, and (c) enriches that triage with production telemetry queried from AWS — without production observability ever depending on this box.

## Non-goals

- **HA / multi-node.** Single-node k3s, same as upstream. Production observability lives in AWS and Rollbar — both independent of this box — so an outage costs agent capacity, never prod visibility. Accepted.
- **Self-hosted production telemetry ingest.** Considered in rev. 1 of this spec (public OTLP endpoint → Alloy → LGTM on the box, with sampling/retention guardrails) and dropped: prod runs on AWS, and telemetry belongs next to the workload it describes. Kept as the named **escape hatch** if CloudWatch costs grow past self-hosting: the product's OTel exporters flip to a self-hosted OTLP endpoint; nothing product-side changes but a URL.
- **Auto-fix PRs from Rollbar.** The workflow stops at a triaged GitHub issue; a human labels it into the existing dev cycle. Full-auto-to-PR is a later autonomy upgrade, not designed here.
- **Shared platform base between personal and company repos.** Deferred (YAGNI at N=2 instances). A **thin-repo variant** (from-scratch private repo whose Applications reference public third-party charts, the engine OCI chart, and pinned upstream bases directly — no fork, one ArgoCD) was also considered and rejected: it trades the `git merge upstream` channel for manual porting of upstream improvements. The named future direction remains the **published-artifact model** — platform components as versioned OCI Helm charts, instance repos holding only Applications + values + secrets, as the engine chart already works. Trigger to revisit: a third instance, or upstream merges conflicting monthly.
- **Dedicated product-workflows repo.** Considered (keeps platform config out of the product repo, scales the Rollbar pattern across products) and rejected for now: workflows stay colocated in each product repo's `agents.json`, which the engine supports today and keeps ownership with the product team. Revisit if a second product wants the same workflows or the engine gains cross-repo targeting.
- **Hosting the company product itself on this box.** `products/` stays available for that later; out of scope now.
- **Engine CI auto-bumps for the company repo.** It pins published engine images and bumps manually (or via its own CI later). Known cost, accepted.

## Decisions (settled during brainstorm)

| Question | Decision |
|----------|----------|
| Repo strategy | Private detached copy in the company GitHub org (`clone` + push + `upstream` remote — a GitHub fork of a public repo can't be private); upstream merges, no shared base yet |
| Telemetry destination | AWS-native (CloudWatch Logs/metrics, X-Ray traces) — prod already runs on AWS; agents get read-only query access. Rev. 1's self-hosted ingest demoted to escape hatch |
| Product instrumentation | OpenTelemetry SDK regardless of destination — keeps the exporter target swappable |
| Rollbar autonomy | Triage → labeled GitHub issue; human gates the fix |
| Hardware | Hetzner AX41, RAID1 across both NVMe drives (~512 GB usable) |

## Design

**Platform delta: zero new cluster components.** With telemetry staying in AWS, the cluster runs the stock platform as deployed by bootstrap. Everything company-specific is configuration: SOPS secrets (Rollbar token, AWS read-only credentials), the workflow declared in the product repo's `agents.json`, and optionally two Grafana data sources. The only candidate code change is the gateway's Rollbar webhook route — which lives in the engine repo, not this platform, and is avoided entirely by the polling fallback (§3).

### 1. Deployment shape

- Create the company platform repo as a **private detached copy**: `git clone` this repo, push to a new private repo in the company org, `git remote add upstream` pointing here. Merges from upstream work exactly like a fork; GitHub just doesn't link them.
- New age keypair; all `secrets/` re-encrypted with company credentials (ArgoCD repo PAT, model provider keys, Rollbar tokens, AWS read-only credentials). `.sops.yaml` recipients replaced.
- Fork discipline: company-specific changes stay in paths upstream never touches (`secrets/`, `clusters/ops/products/`, hostname/values overrides) so upstream merges stay cheap.
- Host provisioning: Hetzner `installimage`, Ubuntu 24.04, **RAID1** over the two NVMe drives, then `bootstrap.sh` following `docs/DEPLOY.md` phase by phase. (`cloud-init.yaml` is the VPS path; dedicated servers go through installimage.)
- Internal zone on a company domain (Technitium + step-ca, as upstream). Public surface: **only** the gateway webhook hostname. No telemetry ingest endpoint exists on this box.
- Engine images: pin the same published images upstream uses; manual bumps (see Non-goals).
- Upstream repos are public: reading upstream (merges, future remote-base/OCI experiments) and pulling engine images needs no credentials. The only repo credential the company cluster carries is the ArgoCD PAT for its own private repo.

### 2. Production telemetry — AWS-native

**Product side (product repo, parallel workstream):**

- Instrument with the OTel SDK (traces, logs, metrics). Vendor-neutral by design; only exporter config names AWS.
- Export via ADOT (AWS Distro for OpenTelemetry) collector or CloudWatch OTLP endpoints → CloudWatch Logs, CloudWatch metrics, X-Ray / Application Signals traces.
- Sampling biased toward errors and latency outliers (ADOT sampling rules) so the traces agents need for triage are reliably captured. Exact rules are product-repo implementation detail.
- AWS owns retention, durability, scaling. Retention policies per log group are a product-side cost knob, not platform work.

**Platform side (this design's scope):**

- A scoped **read-only IAM principal** for agent investigation: CloudWatch Logs read + Logs Insights query, X-Ray read. No write, no other services. Credentials SOPS-encrypted in the company repo, surfaced to agent Jobs the same way other project secrets are.
- **Grafana bridge (optional, cheap):** the box's existing Grafana adds CloudWatch and X-Ray data sources using the same read-only role — one human pane of glass, data never leaves AWS.
- Cost guard: Logs Insights bills per GB scanned, and agents query repeatedly. Workflow queries are constrained to narrow time windows around known occurrences (see §3) — never open-ended scans.

### 3. Rollbar → triage → GitHub issue workflow

**Trigger:** Rollbar webhook (`new_item`, `reactivated_item`, occurrence-rate spike) → existing public gateway grows a Rollbar route with shared-secret validation → starts a Temporal workflow. The workflow is a **custom project workflow** declared in the product repo's `agents.json` — the platform's designed extension point.

**Workflow:**

1. Fetch item + occurrence details from the Rollbar API (read token via SOPS).
2. **Dedupe** — search product-repo GitHub issues for the Rollbar item ID (stamped into every filed issue body); skip known items. Temporal workflow-ID convention (`rollbar-<item-id>`) covers in-flight races.
3. **Storm guard** — cap triage runs (e.g. 5/hour, exact value in plan); overflow from a bad deploy collapses into a single digest issue instead of dozens of agent runs.
4. **Telemetry enrichment** — using the read-only IAM credentials, the triage agent queries CloudWatch Logs Insights and X-Ray for narrow windows around the Rollbar occurrences: correlated request logs, upstream/downstream spans, deploy markers. Query windows are bounded (minutes around occurrence timestamps) to cap Logs Insights scan costs.
5. Triage agent run (k8s Job via the existing agent backend): stack trace + occurrences + telemetry context + product repo access → root-cause hypothesis, affected files, severity, suggested fix outline.
6. File a GitHub issue in the product repo, labeled `rollbar` + `triage`, body containing the analysis, Rollbar link, and dedupe key. A human labels it onward into the existing dev cycle → fix PR through the normal pipeline.

**Fallback (decide in plan):** if webhook plumbing through the gateway proves awkward, a Temporal cron polling the Rollbar API every few minutes delivers the same result with no new public surface, at minutes of latency.

## Failure modes

- **Box down** → production observability unaffected (CloudWatch/X-Ray and Rollbar are external); ArgoCD reconverges on reboot; only agent capacity is lost.
- **Rollbar error storm** → rate cap + digest collapse; Temporal makes retries and dedupe durable across restarts.
- **Missed webhooks** → Rollbar retries failed deliveries; optional nightly reconciliation poll catches stragglers.
- **AWS credentials invalid/expired** → enrichment step fails soft: the workflow proceeds with Rollbar data alone and flags the issue body "telemetry unavailable"; a triage without traces still beats no triage.
- **Runaway query costs** → bounded query windows by construction; CloudWatch billing alarm on the account as a backstop (product-side task).
- **X-Ray sampling missed the failing request** → enrichment degrades to logs-only for that window; sampling rules biased to errors make this rare.

## Verification

- **Cluster:** fresh bootstrap per `DEPLOY.md`; all Applications `Synced/Healthy` in ArgoCD.
- **Telemetry path:** product staging emits OTel → visible in CloudWatch/X-Ray; a test query through the read-only IAM principal returns logs and traces; a write attempt with those credentials is denied; Grafana data sources (if added) render prod dashboards.
- **Rollbar:** Rollbar test-webhook → issue appears with triage analysis including telemetry context; replayed webhook → no duplicate issue; scripted storm → digest behavior engages; revoked AWS creds → issue still files, flagged logs-unavailable.

## Rollout

Three sub-projects, each getting its own implementation plan from this spec, in order:

1. **Company cluster up** — private copy, secrets, AX41 bootstrap, apps healthy. Everything else depends on this.
2. **Rollbar workflow** — the visible win that sells the platform to the devs; exercises gateway, Temporal, agent backend, project-workers end to end. Ships first with Rollbar-data-only triage (enrichment lands with 3).
3. **Product OTel → AWS + agent access** — product-side instrumentation (parallel workstream in the product repo), IAM read-only principal, workflow enrichment step, optional Grafana bridge.
