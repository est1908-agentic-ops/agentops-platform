# Platform Components — Design

Status: draft · 2026-07-03 · Owner: Artem
Milestone: M2, sub-project 2 of 5 (see [decomposition](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-m2-decomposition.md) in `agentops-engine`)

## Context

`clusters/ops/{platform,engine,products}/` exist only as empty directories (`.gitkeep`). Once [platform bootstrap](2026-07-03-platform-bootstrap-design.md) leaves ArgoCD watching `clusters/ops`, this sub-project is what ArgoCD actually finds there for M2: step-ca + cert-manager, Technitium, Temporal + Postgres, and the `dev-agents` namespace the [K8s Job runner](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-k8s-job-runner-design.md) launches Jobs into. Depends on bootstrap for a running ArgoCD to test against; the manifests themselves have no runtime dependency and can be authored in parallel.

## Goal

`kubectl get applications -n argocd` shows every component below `Synced`/`Healthy`, on a cluster built from nothing but the bootstrap sub-project's script.

## Non-goals

- LiteLLM, the LGTM/Alloy observability stack, MailPit, GlitchTip — all M4+, per the decomposition doc.
- Per-product namespaces, `ResourceQuota`/`LimitRange`, the products ApplicationSet generator (§5.7/§5.8) — M2 has exactly one namespace (`dev-agents`) for one disposable test repo; the multi-product registry has nothing to register yet.
- The engine's own Helm chart/Application — [engine image & chart](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-engine-image-and-chart-design.md) owns the chart, this doc only needs to leave `clusters/ops/engine/` ready to hold that Application once the chart exists (a stub is fine here).

## Design

Each component is one ArgoCD `Application` + a `values.yaml`, under `clusters/ops/platform/<component>/`:

```
clusters/ops/platform/
  cert-manager/    application.yaml   values.yaml
  step-ca/         application.yaml   values.yaml   cluster-issuer.yaml
  technitium/      application.yaml   values.yaml   (or plain manifests — see below)
  postgres/        application.yaml   values.yaml
  temporal/        application.yaml   values.yaml
  namespaces/      dev-agents.yaml    network-policy.yaml
```

### cert-manager + step-ca

`cert-manager` (Jetstack Helm chart, standard install) first — step-ca needs `cert-manager`'s CRDs to register a `ClusterIssuer` against it. `step-ca` via the `smallstep/step-certificates` Helm chart, `values.yaml` setting an ACME provisioner. `cluster-issuer.yaml` is a plain `ClusterIssuer` resource pointing `acme.server` at step-ca's in-cluster ACME endpoint — this is the piece that makes `cert-manager` actually usable by other components' Ingresses. Root CA cert exported (via `kubectl get secret` or step-ca's own CLI) for [engine image & chart](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-engine-image-and-chart-design.md)'s `agent-claude` image build step — documented as a manual export command in this doc, not automated (matches that doc's own accepted M2-scope manual coupling).

### Technitium DNS

No well-maintained official Helm chart exists for Technitium; ArgoCD Applications can point `path` at plain manifests (not just Helm), so this is a `Deployment` + `PersistentVolumeClaim` (Technitium's own SQLite-backed zone storage) + `Service`, hand-written and checked in directly under `clusters/ops/platform/technitium/`. Configured (via its own web UI/API, referenced but not automated in M2 — a manual one-time zone setup, documented as a runbook step) to serve `*.lab` pointed at the Traefik ingress ClusterIP/LoadBalancer.

### Postgres

`bitnami/postgresql` Helm chart, single instance, single PVC — "shared Postgres instance, separate DB" per ARCHITECTURE.md §5.2 means this one instance also hosts Temporal's schema; no separate Postgres per component. `values.yaml` sets the initial database name/credentials (password generated once, stored as a SOPS-encrypted secret under `secrets/model-tokens/../postgres.enc.yaml`-equivalent path — actually under a new `secrets/postgres/` directory, matching the existing `secrets/{forge,litellm,smtp,model-tokens}/` convention, added here since Postgres credentials didn't exist as a category before M2).

### Temporal

Official `temporalio/helm-charts` chart, `values.yaml` disables the chart's bundled Postgres (`server.config.persistence.default.driver: sql`, host pointed at the Postgres `Service` above, credentials read from the same SOPS secret) and disables Elasticsearch (not needed at M2's scale — default visibility store on SQL is sufficient for one test repo's task volume; revisit only if Temporal's own docs later recommend otherwise for the actual load). Temporal Web UI exposed via an `Ingress` at `temporal.lab` (HTTP, straightforward through Traefik + the cert-manager/step-ca `ClusterIssuer` above) — the gRPC frontend port is **not** exposed via Ingress, per [M2 wiring](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-m2-wiring-design.md)'s `kubectl port-forward` decision.

### `dev-agents` namespace + NetworkPolicy

```yaml
# clusters/ops/platform/namespaces/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: agent-egress, namespace: dev-agents }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to: [{}] # DNS — refined to kube-dns/Technitium specifically during implementation
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
    - to: [] # github.com, api.anthropic.com — CIDR/FQDN egress rules filled in during implementation;
             # k3s's default CNI (flannel) doesn't enforce NetworkPolicy on its own, noted as a risk below
```

Per ARCHITECTURE.md §5.4's security requirement ("`NetworkPolicy` allowing only forge, LiteLLM, and provider endpoints"). LiteLLM isn't in M2's egress list yet (not deployed until M5) — just GitHub and the model provider (Anthropic) for now.

## Testing strategy

- `helm template`/`kustomize build` (whichever fits each component) for every `values.yaml`, asserted not to error, same convention as [engine image & chart](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-engine-image-and-chart-design.md)'s golden-file approach — lighter here (no engine-specific assertions needed, just "renders").
- Manual: on the dry-run VM from the bootstrap sub-project's testing strategy, confirm all Applications reach `Healthy` in order (cert-manager → step-ca → the rest can be parallel), confirm `temporal.lab` resolves via Technitium and serves the Web UI over a step-ca-issued cert with no browser warning (this is literally ARCHITECTURE.md §5.1's stated payoff — "internal URLs behave exactly like production ones").
- Full validation of `dev-agents`'s NetworkPolicy actually restricting traffic is folded into [M2 wiring](../../../../agentops-engine/docs/superpowers/specs/2026-07-03-m2-wiring-design.md)'s end-to-end runbook, once real agent-runner Jobs exist to test egress against.

## Named risks

- **k3s's default CNI (flannel) does not enforce `NetworkPolicy`.** The manifest above is necessary but not sufficient — M2 needs either a CNI swap (Cilium, Calico) during bootstrap, or an explicit acceptance that `NetworkPolicy` is aspirational until that swap happens. This is a real, not-yet-resolved gap between ARCHITECTURE.md §5.4's requirement and k3s's out-of-the-box behavior — flagged here rather than glossed over; recommend resolving it in the bootstrap sub-project (k3s supports `--flannel-backend=none` + installing Cilium instead, at install time) before treating the NetworkPolicy above as load-bearing security rather than documentation-of-intent.
- **One shared Postgres instance for both Temporal and (eventually) other consumers (pgvector in M6, `agent_run_stats` in M4) means Postgres itself becomes a single point of failure for the whole platform earlier than components that need it exist.** Accepted per ARCHITECTURE.md §5.2's explicit design ("shared Postgres instance, separate DB"); a nightly `pg_dump` (already named in `docs/BOOTSTRAP.md`'s rebuild story) is the mitigation, not solved by this doc.

## Package/file summary

- **New:** `clusters/ops/platform/{cert-manager,step-ca,technitium,postgres,temporal,namespaces}/*`.
- **New:** `secrets/postgres/.gitkeep` (+ real SOPS-encrypted credentials once generated).
- **Changed:** `docs/BOOTSTRAP.md` (a short "what ArgoCD deploys after step 5" pointer to this doc, so the bootstrap doc doesn't need to enumerate components itself).

## Open questions carried forward

- CNI swap for real `NetworkPolicy` enforcement (flannel → Cilium/Calico) — named as a risk above, not designed; recommend resolving before or during this sub-project's implementation, not deferring silently.
- Technitium's one-time zone configuration — documented as a manual runbook step for M2; automating it (via its REST API, scripted) is a reasonable follow-up, not required for the gate.
