# Platform Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After [platform bootstrap](2026-07-03-platform-bootstrap.md) leaves ArgoCD watching `clusters/ops`, `kubectl get applications -n argocd` shows cert-manager, step-ca, Technitium, Postgres, Temporal, and the `dev-agents` namespace all `Synced`/`Healthy`.

**Architecture:** One ArgoCD `Application` per component under `clusters/ops/platform/<component>/`. Every Helm-chart-backed component (cert-manager, step-ca, Postgres, Temporal) is a **Kustomize source with `helmCharts:`** (not ArgoCD's native Helm source type) — this is what lets the same directory also carry a KSOPS-encrypted secret (Postgres needs one) through the same `kustomize build` pass that already runs the KSOPS plugin installed during bootstrap. Technitium (no maintained chart) and the `dev-agents` namespace/`NetworkPolicy` (no chart at all) are plain-manifest directory sources.

**Tech Stack:** Helm charts (versions pinned below) inflated via Kustomize's `helmCharts` field, `kustomize-sops`/KSOPS for the one encrypted secret this sub-project adds, YAML throughout. No new dependency versus the bootstrap plan — this reuses the `--enable-helm --enable-alpha-plugins --enable-exec` kustomize build options already set in `bootstrap/argocd-values.yaml`.

**Prerequisite:** [Platform Bootstrap](2026-07-03-platform-bootstrap.md) — specifically its `bootstrap/argocd-values.yaml`, which this plan updates (adds `--enable-helm`, already done as part of that plan) and whose dry-run VM this plan's own manual verification (Task 9) reuses.

**Design doc:** `docs/superpowers/specs/2026-07-03-platform-components-design.md`

**Chart versions pinned for this plan** (current stable as of 2026-07-03, verified against each chart's actual repo — same reproducibility rationale as the bootstrap plan's ArgoCD chart pin):
- cert-manager (jetstack): `v1.20.3`
- step-certificates (smallstep): `1.30.0`
- postgresql (bitnami): `17.1.0`
- temporal (temporalio/helm-charts): `1.22.4`

**Design decision not fully specified by the spec doc, made explicit here:** the spec doc doesn't say which namespace each component's pods run in (only `dev-agents` is named). This plan uses: `cert-manager` → `cert-manager` ns (upstream's own convention, effectively mandatory for its webhook wiring), `step-ca` → `step-ca` ns, `technitium` → `technitium` ns, and **Postgres + Temporal share one `platform` namespace** — deliberately, because Temporal's chart reads the Postgres password from a k8s `Secret`, and `Secret` references in a PodSpec cannot cross namespaces without extra machinery (a replication controller) this sub-project has no reason to add.

**Note on "tests":** matching the design doc's own Testing Strategy ("`helm template`/`kustomize build`... asserted not to error... lighter here, just 'renders'"), each task's test is a rendering/syntax check, not a unit test. `helm`/`kustomize` aren't installed in this dev sandbox (confirmed while writing this plan) — install once with `brew install helm kustomize` (macOS) before running the render checks below; CI does not need them (this plan's CI-facing check, per the design doc, is limited to what the bootstrap plan's `lint.yaml` already covers plus the PyYAML syntax checks added here — no new CI job, matching the design doc's own scope: it names `helm template`/`kustomize build` as *local* verification, not a CI addition).

---

### Task 1: `clusters/ops/platform/cert-manager/` — cert-manager

**Files:**
- Create: `clusters/ops/platform/cert-manager/application.yaml`
- Create: `clusters/ops/platform/cert-manager/kustomization.yaml`
- Create: `clusters/ops/platform/cert-manager/values.yaml`
- Test: `helm template` render check (real, runnable) + PyYAML syntax check

cert-manager goes first — step-ca's `ClusterIssuer` (Task 2) needs cert-manager's CRDs to exist before it can be applied.

- [ ] **Step 1: Write `values.yaml`**

```yaml
# cert-manager Helm values. crds.enabled installs the CRDs this chart
# needs (ClusterIssuer, Certificate, etc.) as part of the release,
# so no separate manual `kubectl apply` of CRDs is needed.
crds:
  enabled: true
```

- [ ] **Step 2: Write `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: cert-manager
    repo: https://charts.jetstack.io
    version: v1.20.3
    releaseName: cert-manager
    namespace: cert-manager
    valuesFile: values.yaml
```

- [ ] **Step 3: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
    targetRevision: main
    path: clusters/ops/platform/cert-manager
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Verify it renders**

```bash
kustomize build --enable-helm clusters/ops/platform/cert-manager | head -20
```
Expected: prints rendered Kubernetes YAML (Deployments, CRDs, etc.), no error. (If `kustomize` isn't installed: `brew install kustomize`.)

```bash
python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1])); print('OK')" clusters/ops/platform/cert-manager/application.yaml
```
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add clusters/ops/platform/cert-manager
git commit -m "feat(platform): cert-manager component"
```

---

### Task 2: `clusters/ops/platform/step-ca/` — step-ca + ClusterIssuer

**Files:**
- Create: `clusters/ops/platform/step-ca/application.yaml`
- Create: `clusters/ops/platform/step-ca/kustomization.yaml`
- Create: `clusters/ops/platform/step-ca/values.yaml`
- Create: `clusters/ops/platform/step-ca/cluster-issuer.yaml`
- Test: `kustomize build --enable-helm` render check + PyYAML syntax check

- [ ] **Step 1: Write `values.yaml`**

```yaml
# step-ca (smallstep/step-certificates) Helm values. Standalone CA
# with an ACME provisioner enabled, so cert-manager can request
# certs from it exactly like it would from a public ACME CA.
inject:
  config:
    files:
      ca.json:
        acme:
          provisioners:
            - type: ACME
              name: acme
```

- [ ] **Step 2: Write `cluster-issuer.yaml`**

Points cert-manager's ACME issuer at step-ca's in-cluster ACME endpoint (service DNS name follows the chart's `<release-name>` fullname — `step-certificates` here, matching the Helm release name set below).

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-ca
spec:
  acme:
    server: https://step-certificates.step-ca.svc.cluster.local:9000/acme/acme/directory
    skipTLSVerify: true # step-ca's own cert isn't yet trusted by cert-manager's ACME client; revisit once cert-manager trusts step-ca's root
    privateKeySecretRef:
      name: step-ca-acme-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
```

- [ ] **Step 3: Write `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: step-certificates
    repo: https://smallstep.github.io/helm-charts/
    version: 1.30.0
    releaseName: step-certificates
    namespace: step-ca
    valuesFile: values.yaml

resources:
  - cluster-issuer.yaml
```

- [ ] **Step 4: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: step-ca
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
    targetRevision: main
    path: clusters/ops/platform/step-ca
  destination:
    server: https://kubernetes.default.svc
    namespace: step-ca
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 5: Verify it renders**

```bash
kustomize build --enable-helm clusters/ops/platform/step-ca | head -20
python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1])); print('OK')" clusters/ops/platform/step-ca/application.yaml
```
Expected: rendered YAML including the `ClusterIssuer`, no error; `OK`.

- [ ] **Step 6: Commit**

```bash
git add clusters/ops/platform/step-ca
git commit -m "feat(platform): step-ca + ACME ClusterIssuer"
```

---

### Task 3: `clusters/ops/platform/technitium/` — Technitium DNS

**Files:**
- Create: `clusters/ops/platform/technitium/deployment.yaml`
- Create: `clusters/ops/platform/technitium/pvc.yaml`
- Create: `clusters/ops/platform/technitium/service.yaml`
- Create: `clusters/ops/platform/technitium/application.yaml`
- Test: PyYAML syntax check (no chart to render — hand-written manifests, per the design doc: "No well-maintained official Helm chart exists for Technitium")

- [ ] **Step 1: Write `pvc.yaml`** (Technitium's own SQLite-backed zone storage)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: technitium-data
  namespace: technitium
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 2: Write `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: technitium
  namespace: technitium
spec:
  replicas: 1
  selector:
    matchLabels:
      app: technitium
  template:
    metadata:
      labels:
        app: technitium
    spec:
      containers:
        - name: technitium
          image: technitium/dns-server:13.4.0
          ports:
            - name: dns-udp
              containerPort: 53
              protocol: UDP
            - name: dns-tcp
              containerPort: 53
              protocol: TCP
            - name: web
              containerPort: 5380
              protocol: TCP
          volumeMounts:
            - name: data
              mountPath: /etc/dns
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: technitium-data
```

- [ ] **Step 3: Write `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: technitium
  namespace: technitium
spec:
  selector:
    app: technitium
  ports:
    - name: dns-udp
      port: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      protocol: TCP
    - name: web
      port: 5380
      protocol: TCP
```

- [ ] **Step 4: Write `application.yaml`** (plain directory source — no Helm chart, no `kustomization.yaml` needed)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: technitium
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
    targetRevision: main
    path: clusters/ops/platform/technitium
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: technitium
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 5: Verify syntax**

```bash
python3 -c "
import yaml, sys
for f in sys.argv[1:]:
    yaml.safe_load(open(f))
print('OK')
" clusters/ops/platform/technitium/deployment.yaml clusters/ops/platform/technitium/pvc.yaml clusters/ops/platform/technitium/service.yaml clusters/ops/platform/technitium/application.yaml
```
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add clusters/ops/platform/technitium
git commit -m "feat(platform): Technitium DNS (hand-written manifests, no maintained chart)"
```

> **Runbook note (not automated):** Technitium's `*.lab` zone still needs its one-time configuration through its own web UI/API after this Application syncs — per the design doc, this is intentionally a manual step for M2, not part of this plan.

---

### Task 4: `clusters/ops/platform/postgres/` — shared Postgres + credentials secret

**Files:**
- Create: `secrets/postgres/.gitkeep`
- Create: `clusters/ops/platform/postgres/application.yaml`
- Create: `clusters/ops/platform/postgres/kustomization.yaml`
- Create: `clusters/ops/platform/postgres/values.yaml`
- Create: `clusters/ops/platform/postgres/secret-generator.yaml`
- Test: PyYAML syntax check (rendering needs a real age-encrypted secret file that doesn't exist yet — see Step 5)

- [ ] **Step 1: Create the `secrets/postgres/` category** (matches the existing `secrets/{forge,litellm,model-tokens,smtp}/.gitkeep` convention — this is a new secret category added by this plan, per the design doc)

```bash
mkdir -p secrets/postgres
touch secrets/postgres/.gitkeep
```

- [ ] **Step 2: Write `values.yaml`**

```yaml
# bitnami/postgresql values. auth.existingSecret defers the actual
# password to the KSOPS-decrypted secret this component's
# kustomization also generates (secret-generator.yaml) — never a
# plaintext password in this file.
auth:
  username: temporal
  database: temporal
  existingSecret: postgres-credentials
  secretKeys:
    userPasswordKey: password
architecture: standalone
primary:
  persistence:
    size: 8Gi
```

- [ ] **Step 3: Write `secret-generator.yaml`** (the KSOPS generator config — this is what makes ArgoCD's KSOPS-patched repo-server decrypt `secrets/postgres/postgres-credentials.enc.yaml` at render time, per `bootstrap/argocd-values.yaml`'s KSOPS install from the bootstrap plan)

```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: postgres-credentials-secret-generator
files:
  - ../../../../secrets/postgres/postgres-credentials.enc.yaml
```

- [ ] **Step 4: Write `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: postgresql
    repo: https://charts.bitnami.com/bitnami
    version: 17.1.0
    releaseName: postgres
    namespace: platform
    valuesFile: values.yaml

generators:
  - secret-generator.yaml
```

- [ ] **Step 5: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
    targetRevision: main
    path: clusters/ops/platform/postgres
  destination:
    server: https://kubernetes.default.svc
    namespace: platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 6: Verify syntax of the files that don't need a real secret to parse**

```bash
python3 -c "
import yaml, sys
for f in sys.argv[1:]:
    yaml.safe_load(open(f))
print('OK')
" clusters/ops/platform/postgres/application.yaml clusters/ops/platform/postgres/kustomization.yaml clusters/ops/platform/postgres/secret-generator.yaml clusters/ops/platform/postgres/values.yaml
```
Expected: `OK`
(`kustomize build --enable-helm` on this directory will fail until `secrets/postgres/postgres-credentials.enc.yaml` exists for real — see the note below. That's expected, not a bug to fix here.)

- [ ] **Step 7: Commit**

```bash
git add secrets/postgres clusters/ops/platform/postgres
git commit -m "feat(platform): shared Postgres (bitnami chart) + KSOPS secret wiring"
```

> **Production runbook note (not automated, needs a real age recipient key — same constraint as the bootstrap plan's `.sops.yaml`/age-key steps):**
> ```bash
> PASSWORD="$(openssl rand -base64 32)"
> cat > secrets/postgres/postgres-credentials.enc.yaml <<EOF
> apiVersion: v1
> kind: Secret
> metadata:
>   name: postgres-credentials
>   namespace: platform
> stringData:
>   password: "${PASSWORD}"
> EOF
> sops --encrypt --in-place secrets/postgres/postgres-credentials.enc.yaml
> git add secrets/postgres/postgres-credentials.enc.yaml
> git commit -m "chore: add encrypted postgres credentials"
> ```
> Only after this file exists (encrypted, committed) will ArgoCD's KSOPS-patched repo-server be able to render the `postgres` Application at all — until then it fails closed (a missing/unencrypted source file is a render error, not a silently-empty secret), which is the safe failure mode.

> **Named risk carried forward from the design doc, not solved here:** this one Postgres instance becomes a single point of failure for the whole platform (Temporal now, `agent_run_stats`/pgvector later) earlier than the components that need it exist. Accepted per ARCHITECTURE.md §5.2's explicit "shared instance" design; the design doc's stated mitigation (nightly `pg_dump` to off-host storage) is out of scope for this plan too — it belongs wherever the platform's backup automation gets built, not here.

---

### Task 5: `clusters/ops/platform/temporal/` — Temporal (external Postgres, no bundled ES)

**Files:**
- Create: `clusters/ops/platform/temporal/application.yaml`
- Create: `clusters/ops/platform/temporal/kustomization.yaml`
- Create: `clusters/ops/platform/temporal/values.yaml`
- Test: `kustomize build --enable-helm` render check + PyYAML syntax check

Reuses the `postgres-credentials` secret Task 4 creates in the `platform` namespace — this is why Postgres and Temporal share that namespace (see the plan header's namespace note).

- [ ] **Step 1: Write `values.yaml`**

Every field below was verified against `temporalio/helm-charts` v1.22.4's actual `values.yaml` and `_helpers.tpl` while writing this plan — in particular, the SQL driver plugin name is literally `"postgres"` (not `"postgres12"`, a name used elsewhere in Temporal's own docs for a different context).

```yaml
server:
  config:
    persistence:
      defaultStore: default
      default:
        driver: "sql"
        sql:
          driver: "postgres"
          host: "postgres-postgresql.platform.svc.cluster.local"
          port: 5432
          database: "temporal"
          user: "temporal"
          existingSecret: "postgres-credentials"
      visibility:
        driver: "sql"
        sql:
          driver: "postgres"
          host: "postgres-postgresql.platform.svc.cluster.local"
          port: 5432
          database: "temporal_visibility"
          user: "temporal"
          existingSecret: "postgres-credentials"

# No bundled datastores — we point at the Postgres component (Task 4) instead.
cassandra:
  enabled: false
mysql:
  enabled: false
elasticsearch:
  enabled: false

# LGTM/observability stack is M4+ (design doc non-goals) — don't let
# this chart's bundled monitoring subcharts jump ahead of that.
prometheus:
  enabled: false
grafana:
  enabled: false

web:
  ingress:
    enabled: true
    hosts:
      - "temporal.lab"
```

Note: `visibility.sql.database: "temporal_visibility"` requires that database to already exist in the shared Postgres instance before Temporal's schema-setup Job runs — bitnami's postgresql chart only creates the one database named in `auth.database` (`temporal`, per Task 4's `values.yaml`). Creating `temporal_visibility` is a one-time manual `psql` step during the real bootstrap dry-run (Task 9, Step 3 below); not something this plan's rendering checks can do without a live cluster.

- [ ] **Step 2: Write `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: temporal
    repo: https://go.temporal.io/helm-charts
    version: 1.22.4
    releaseName: temporal
    namespace: platform
    valuesFile: values.yaml
```

- [ ] **Step 3: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: temporal
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
    targetRevision: main
    path: clusters/ops/platform/temporal
  destination:
    server: https://kubernetes.default.svc
    namespace: platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Verify it renders**

```bash
kustomize build --enable-helm clusters/ops/platform/temporal | grep -c "^kind:"
python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1])); print('OK')" clusters/ops/platform/temporal/application.yaml
```
Expected: a nonzero count of rendered `kind:` resources; `OK`.

- [ ] **Step 5: Commit**

```bash
git add clusters/ops/platform/temporal
git commit -m "feat(platform): Temporal (external Postgres, ES/Prometheus/Grafana disabled)"
```

---

### Task 6: `clusters/ops/platform/namespaces/` — `dev-agents` + egress `NetworkPolicy`

**Files:**
- Create: `clusters/ops/platform/namespaces/dev-agents.yaml`
- Create: `clusters/ops/platform/namespaces/network-policy.yaml`
- Create: `clusters/ops/platform/namespaces/application.yaml`
- Test: PyYAML syntax check

- [ ] **Step 1: Write `dev-agents.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev-agents
```

- [ ] **Step 2: Write `network-policy.yaml`** (as specified in the design doc, verbatim)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: agent-egress
  namespace: dev-agents
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to: [{}] # DNS — refined to kube-dns/Technitium specifically during implementation
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
    - to: [] # github.com, api.anthropic.com — CIDR/FQDN egress rules filled in during implementation;
             # k3s's default CNI (flannel) doesn't enforce NetworkPolicy on its own, noted as a risk below
```

- [ ] **Step 3: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: namespaces
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<AGENTOPS_PLATFORM_GIT_URL>"
    targetRevision: main
    path: clusters/ops/platform/namespaces
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 4: Verify syntax**

```bash
python3 -c "
import yaml, sys
for f in sys.argv[1:]:
    yaml.safe_load(open(f))
print('OK')
" clusters/ops/platform/namespaces/dev-agents.yaml clusters/ops/platform/namespaces/network-policy.yaml clusters/ops/platform/namespaces/application.yaml
```
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add clusters/ops/platform/namespaces
git commit -m "feat(platform): dev-agents namespace + egress NetworkPolicy"
```

> **Named risk carried forward from the design doc, not solved here:** k3s's default CNI (flannel) doesn't enforce `NetworkPolicy` at all — this manifest is necessary but not sufficient until a CNI swap (Cilium/Calico) happens during bootstrap. The design doc explicitly scopes that decision out of this sub-project too ("recommend resolving in the bootstrap sub-project... not designed [here]"); this plan doesn't invent that design either. Until it's resolved, treat this `NetworkPolicy` as documentation of intent, not a real security boundary.

---

### Task 7: `docs/BOOTSTRAP.md` — pointer to platform components

**Files:**
- Modify: `docs/BOOTSTRAP.md`
- Test: none (documentation)

- [ ] **Step 1: Replace the step 5 placeholder with a concrete pointer**

Find:
```markdown
5. **Platform components** come up in dependency order (ArgoCD sync waves): Postgres → Temporal → Technitium + step-ca + cert-manager → LGTM (Alloy, Prometheus, Loki, Tempo, Grafana) → LiteLLM → MailPit → GlitchTip.
```
Replace with:
```markdown
5. **Platform components**: `cert-manager` → `step-ca` (needs cert-manager's CRDs) → `Technitium`/`Postgres`/`Temporal` (no ordering dependency between these three) → `dev-agents` namespace. See `clusters/ops/platform/*/application.yaml` for the actual ArgoCD Applications — LGTM/LiteLLM/MailPit/GlitchTip are M4+, not part of this set yet.
```

- [ ] **Step 2: Commit**

```bash
git add docs/BOOTSTRAP.md
git commit -m "docs: point BOOTSTRAP.md step 5 at the real platform components"
```

---

### Task 8: Full local verification gate

**Files:** none (verification only; fix forward into whichever file if something fails).

- [ ] **Step 1: Render every Helm-backed component**

```bash
for d in cert-manager step-ca temporal; do
  echo "=== $d ==="
  kustomize build --enable-helm "clusters/ops/platform/$d" >/dev/null && echo OK
done
```
Expected: `OK` for all three. (`postgres` is excluded here — per Task 4, it only renders once the real encrypted secret exists, which this plan deliberately doesn't fabricate.)

- [ ] **Step 2: YAML-syntax-check everything else**

```bash
python3 -c "
import glob, yaml
for f in sorted(glob.glob('clusters/ops/platform/**/*.yaml', recursive=True)):
    yaml.safe_load(open(f))
print('OK')
"
```
Expected: `OK`

- [ ] **Step 3: If anything failed, fix it in the relevant file and commit the fix**

```bash
git add -A
git commit -m "fix(platform): address verification gate failures"
```
(Skip entirely if Step 1/2 were clean — don't create an empty commit.)

---

### Task 9: Manual dry-run verification (operator-performed, extends the bootstrap plan's dry-run VM)

**Files:** none — runbook, matching the design doc's own testing strategy ("full validation... folded into M2 wiring's end-to-end runbook").

- [ ] **Step 1: On the same throwaway VM from the bootstrap plan's Task 11** (after a real, non-throwaway age key and the real `secrets/postgres/postgres-credentials.enc.yaml` exist — this task needs the real production secret, not the bootstrap dry-run's disposable key), confirm all Applications reach `Healthy`:

```bash
sudo kubectl get applications -n argocd -w
```
Expected: `cert-manager`, `step-ca`, `technitium`, `postgres`, `temporal`, `namespaces` all reach `Synced`/`Healthy` (cert-manager first, `step-ca` only after cert-manager's CRDs exist).

- [ ] **Step 2: Create the `temporal_visibility` database** (bitnami's chart only creates the `temporal` database named in Task 4's `auth.database`; Temporal's visibility store needs a second one — see Task 5's note)

```bash
sudo kubectl exec -n platform -it postgres-postgresql-0 -- psql -U temporal -d temporal -c "CREATE DATABASE temporal_visibility;"
```

- [ ] **Step 3: Confirm Temporal's schema-setup Jobs completed**

```bash
sudo kubectl get jobs -n platform
```
Expected: `temporal-schema-setup` and `temporal-schema-update`-style Jobs (exact names come from the chart at render time) show `Completions: 1/1`.

- [ ] **Step 4: Confirm `temporal.lab` resolves via Technitium and serves a step-ca-issued cert with no browser warning** — this is literally ARCHITECTURE.md §5.1's stated payoff ("internal URLs behave exactly like production ones"). Requires Technitium's one-time zone setup (Task 3's runbook note) and admin machines trusting step-ca's root cert (exported per the platform-components design doc, a manual step owned by the engine-image-and-chart design, not this plan).

- [ ] **Step 5: Tear down the throwaway VM.**

---

### Task 10: Open the PR, pass CI, and resolve the Bugbot review

**Files:** none (integration / review).

> Sequential and partly asynchronous — CI and Bugbot run on the remote PR.
> **HARD GATE: Do not mark this task complete until ALL Bugbot comments are
> resolved (fixed or replied to) AND CI is green. Check with
> `gh pr view --json reviews,comments` before claiming done.**

- [ ] **Step 1: Sync the latest `main`**

```bash
git fetch origin
git merge origin/main
python3 -c "
import glob, yaml
for f in sorted(glob.glob('clusters/ops/platform/**/*.yaml', recursive=True)):
    yaml.safe_load(open(f))
print('OK')
"   # resolve conflicts + commit first if any; fix fallout
```

- [ ] **Step 2: Push and open the PR**

```bash
git status --short && git rev-parse --abbrev-ref HEAD   # clean tree, on feature branch (not main)
git push -u origin HEAD
gh pr create --base main --fill --title "Platform components: cert-manager, step-ca, Technitium, Postgres, Temporal"
```

- [ ] **Step 3: Subagent code review**

REQUIRED SUB-SKILL: `requesting-code-review`. Dispatch a code reviewer subagent (BASE_SHA = merge-base with `main`, HEAD_SHA = HEAD). Fix Critical and Important findings, commit, push, then proceed.

- [ ] **Step 4: Make every CI check pass**

```bash
gh pr checks --watch
```
On failure: `gh run view --log-failed`, reproduce locally, fix, commit, push, re-watch. Do not proceed while red.

- [ ] **Step 5: Wait for the Bugbot review**

```bash
gh pr view --json reviews,comments
gh pr comment --body "bugbot run"   # only if it hasn't reviewed yet
```

- [ ] **Step 6: Address each Bugbot comment**

REQUIRED SUB-SKILL: `receiving-code-review`. Verify before acting — reply to false positives; TDD-fix real findings, commit each referencing the finding, push once.

**Then mark each addressed thread resolved** (completion is gated on the unresolved-thread count, not just on having replied/fixed):

```bash
gh api graphql -f query='query($o:String!,$r:String!,$p:Int!){repository(owner:$o,name:$r){pullRequest(number:$p){reviewThreads(first:100){nodes{id isResolved path comments(first:1){nodes{body}}}}}}}' -F o=<owner> -F r=<repo> -F p=<number>
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -F id=<thread-id>
```

**After pushing:** return to Step 4 (re-watch CI), then Step 5 (wait for re-review). Loop until Bugbot reports no unresolved comments.

- [ ] **Step 7: Final verification**

```bash
gh pr checks                          # all green
gh pr view --json reviews,comments    # no comment left unaddressed
for d in cert-manager step-ca temporal; do kustomize build --enable-helm "clusters/ops/platform/$d" >/dev/null && echo "$d OK"; done
```
Confirm no unresolved review threads remain, then mark this task complete.
