# Design — Task self-heal-2026-07-14t05-00-00z-platform-fix-1

Fix the cluster **base image**'s CA-bundle build step so that a placeholder step-ca
root cert (invalid PEM text referencing "M2 sub-project 2") can no longer poison the
system trust store and break all outbound HTTPS for pods running on that image.

## Goal

The base image's build appends a placeholder step-ca root certificate directly into
`/etc/ssl/certs/ca-certificates.crt`. The placeholder is not valid PEM — it is literal
text standing in for the real step-ca root that isn't available yet. OpenSSL 3.0 parses
a CA bundle as a single unit and **aborts the whole file** when any block is malformed,
so `curl`, `git`, and every other OpenSSL/TLS client on the image lose *all* CA trust —
not just trust in step-ca. This contradicts the build comment's assumption that
`update-ca-certificates` "silently skips invalid entries": that tool only *selects whole
files* to include (by config / `/etc/ca-certificates.conf`), it never validates the PEM
*content within* a file.

Until the real step-ca root cert exists, the build must stop feeding invalid PEM into the
trust bundle so the system trust store stays usable in the interim.

## Where this change lives (important scoping fact)

This repository (`agentops-platform`) is the **GitOps/ArgoCD source of truth** — it pins
and deploys images but contains **no application code and no Dockerfiles**. The context
stage confirmed (and `README.md` / `clusters/ops/engine/values.yaml` state) that all
container images, including the cluster **base image** whose CA-bundle build step this task
targets, are built in the sibling repo **`agentops-engine`** (design authority:
`agentops-engine/docs/ARCHITECTURE.md` §5.1 cluster base image, §5.8 repo layout). This
repo consumes those images by tag under `clusters/ops/engine/values.yaml`
(`image.repository: gitactions.est1908.top/agentic-ops`, `workerTag`/`agentRunnerTag`/
`gatewayTag`/`controlTag`), bumped automatically by `agentops-engine` CI.

Consequently the **code fix lands in `agentops-engine`** (the base image Dockerfile / its
CA-setup build step), not in this repo. Per the task's persistence instructions, the
*design artifact* is still written and committed here. See Assumptions for how this
cross-repo reality was resolved.

## Approaches considered

### A. Omit the placeholder from the trust sources entirely
Delete (or comment out) the build step that pulls the placeholder cert into the trust
path. The image ships with only the distro CA bundle, which is already valid.

- **Trade-off:** Minimal and lowest-risk — restores a working trust bundle by removing the
  offending input. But it leaves the *flawed mechanism* (raw concatenation into
  `ca-certificates.crt`, no validation) in place, so the next person who re-adds a cert can
  reproduce the identical outage. It also requires a second, easy-to-forget manual edit when
  the real step-ca root becomes available.
- **Cost:** Trivial (remove a few Dockerfile lines).

### B. Validate-before-include, via the supported `update-ca-certificates` flow (recommended)
Rework the CA build step so each candidate root is (1) placed as its own file under
`/usr/local/share/ca-certificates/<name>.crt` and enrolled with `update-ca-certificates`
(the supported mechanism) instead of being `cat`-appended into `ca-certificates.crt`, and
(2) gated by an explicit PEM-parse check — `openssl x509 -in <file> -noout` — so a file is
only enrolled if it actually parses as a certificate. Files that fail the check are skipped
with a build-time warning and the build still succeeds.

- **Trade-off:** Slightly more build logic than A, and it must reference `openssl`
  (already present in the base image). In return it fixes the *root cause*: the trust
  bundle can never again be poisoned by an unparseable block, and when the real step-ca
  root drops in it is picked up automatically with no code change — the placeholder simply
  fails the parse check and is excluded today. This directly implements the goal's stated
  "validate it parses as PEM before including it" remedy.
- **Cost:** Small (a guarded loop / conditional around the existing step).

### C. Move the step-ca root out of the image entirely — inject at runtime
Stop baking any step-ca root into the image. Instead mount the cluster's real step-ca root
(a ConfigMap/Secret produced by the `step-ca` deployment) into worker/agent/gateway pods
and run `update-ca-certificates` in an init step at container start.

- **Trade-off:** Architecturally the most correct long-term shape — the step-ca root is
  cluster-specific *runtime* data, not a build-time constant, and this removes the
  chicken-and-egg of baking a CA that doesn't exist at build time. But it is a much larger
  change spanning both repos: the `agentops-engine` image entrypoint *and* this GitOps
  repo's engine chart values / pod specs (volume mounts, RBAC to read the step-ca root).
  Far beyond an interim heal.
- **Cost:** Large, multi-repo, needs coordinated cert-manager/step-ca wiring.

## Chosen approach

**Approach B — validate-before-include via the supported `update-ca-certificates`
file-based flow.**

- **Over A:** A and B produce the *identical* runtime result *today* (the placeholder never
  parses, so it is excluded either way), but B additionally removes the entire class of bug
  rather than this one instance, and is self-correcting when the real root arrives. A leaves
  a loaded gun — the same invalid-PEM-poisons-the-bundle outage — pointed at the next
  contributor. For an unattended fix meant to keep the system healthy without a human in the
  loop, eliminating the failure mode beats papering over one occurrence.
- **Over C:** C is the right destination but is a cross-repo architectural change touching
  pod specs and RBAC in this GitOps repo as well as the engine image. The goal explicitly
  frames this as an *interim* fix ("until the real step-ca root cert is available"); C is
  scoped work for when that root is wired end-to-end, not now.

## Assumptions

- **Cross-repo target.** The task names this repo (`agentops-platform`) but the base image
  and its CA-bundle build step demonstrably live in `agentops-engine` (no Dockerfile exists
  here; the context stage and repo docs confirm images are built there and only *pinned*
  here). **Assumption/decision:** the design describes the fix at the level of the
  `agentops-engine` base image build step (the CA-setup layer of the cluster base image per
  ARCHITECTURE.md §5.1); the implementing PR is opened against `agentops-engine`, while this
  design document is committed here as the task's persistence instructions require. No usable
  fix can be made in `agentops-platform` itself for this defect — there is nothing to change
  here, and inventing a Dockerfile in this GitOps repo would violate its "config is the
  state, code lives in agentops-engine" principle.
- **Exact Dockerfile path/lines unknown from this checkout.** Only `agentops-platform` is
  checked out, so the precise file and line numbers of the offending step are not visible.
  **Assumption:** the fix is a single, self-contained edit to the one CA-setup build step
  (identified by the `M2 sub-project 2` placeholder and the `ca-certificates.crt`
  concatenation) in the base image Dockerfile; the implementer locates it by grepping
  `agentops-engine` for `ca-certificates.crt` / `update-ca-certificates` / the placeholder
  marker. No other build stages are in scope.
- **`openssl` is available at base-image build time.** The base image is the trust anchor
  for OpenSSL-based clients and the build comment already reasons about OpenSSL 3.0
  behavior, so `openssl` is present. **Assumption:** the validate step can call
  `openssl x509 -in <file> -noout`; if for some reason only `certtool`/`step` is available,
  an equivalent single-cert parse check is substituted — the design requires *a* PEM-parse
  gate, not that specific binary.
- **Placeholder should not be silently deleted, only kept out of the trust path.** The
  placeholder marker documents intent ("real step-ca root goes here"). **Assumption:** it is
  fine to leave the placeholder file present in the build context for reference as long as
  it is excluded from the trusted-CA sources; the parse gate accomplishes exactly this
  without needing to remove the file.

## Design

Scope: **one coherent change** — the CA-setup build step of the `agentops-engine` cluster
base image. No other components in either repo change.

### Component affected
- `agentops-engine`: the base image Dockerfile (the layer that assembles the system trust
  store). Design authority: `agentops-engine/docs/ARCHITECTURE.md` §5.1.

### Behavior change
1. **Stop raw-concatenating into `/etc/ssl/certs/ca-certificates.crt`.** That file is a
   generated artifact of `update-ca-certificates`; appending to it by hand is what let
   invalid text reach the bundle and is fragile against regeneration. Candidate roots are
   instead written as discrete files under `/usr/local/share/ca-certificates/` (the
   directory `update-ca-certificates` reads), one cert per `.crt` file.
2. **Gate every candidate on a PEM-parse check before enrolling it.** For each candidate
   file, run `openssl x509 -in <file> -noout`. On success, keep the file in
   `/usr/local/share/ca-certificates/` and (after all candidates are processed) run
   `update-ca-certificates` once to regenerate the bundle. On failure, skip the file and
   emit a build-time warning naming the file (so the placeholder's exclusion is visible in
   build logs, not silent). The build **does not fail** on a skipped cert — that is the
   whole point of the interim behavior.
3. **Correct the misleading build comment.** Replace the comment asserting
   `update-ca-certificates` "silently skips invalid entries" with an accurate note:
   `update-ca-certificates` selects whole files by config and does **not** validate PEM
   content; validation is done here explicitly by the `openssl x509 … -noout` gate, and
   OpenSSL 3.0 rejects an entire bundle if any block is malformed.

### Data flow (build time)
```
candidate roots (incl. "M2 sub-project 2" placeholder)
      │
      ▼  for each file:
  openssl x509 -in FILE -noout  ──fail──▶ warn "skipping invalid CA: FILE" ; continue
      │ pass
      ▼
  keep FILE in /usr/local/share/ca-certificates/
      │
      ▼  (once, after loop)
  update-ca-certificates  ──▶ regenerates /etc/ssl/certs/ca-certificates.crt
                               from only valid, whole files
```
Current result: the placeholder fails the gate and is excluded; the emitted bundle contains
only the valid distro roots and remains parseable by OpenSSL 3.0. When the real step-ca
root replaces the placeholder later, it passes the gate and is enrolled automatically with
no further code change.

### Error handling
- Invalid/unparseable candidate → skipped, warned, build continues (interim requirement).
- Zero valid extra roots (today's state) → distro bundle only; still valid. Acceptable — it
  is the pre-existing, working trust set; nothing that works today regresses.
- `update-ca-certificates` run once after the loop so a single malformed input can never
  leave a partially-written bundle.

### Verification
- Build the base image; confirm the build log shows the placeholder being skipped with a
  warning and the build succeeding.
- In a container from the new image: `openssl storeutl -noout -certs /etc/ssl/certs/ca-certificates.crt`
  parses without error, and `curl -sSI https://github.com` / `git ls-remote https://…`
  succeed (outbound HTTPS restored).
- Regression guard for the future real root: dropping a valid PEM into the candidate set and
  rebuilding shows it enrolled and trusted.

## Self-review
- No placeholders or TBDs in this design.
- No contradictions: the recommendation (B) is consistently carried through Goal → Approaches
  → Chosen → Design; A and C are explicitly rejected with reasons.
- Scope: one coherent change (the single CA-setup build step of the base image). The
  cross-repo reality (fix lands in `agentops-engine`, design recorded here) is stated openly
  rather than smoothed over. Approach C's broader runtime-injection work is deliberately
  excluded and flagged as future scope.

## Brainstorm Summary
**Approaches considered:** (A) drop the placeholder from the trust sources; (B) rework the step to enroll certs via `update-ca-certificates` and gate each on an `openssl x509 -noout` PEM-parse check; (C) stop baking any step-ca root into the image and inject the real root at runtime.
**Chosen approach:** (B) validate-before-include via the supported `update-ca-certificates` file flow.
**Why (decisive reasons):** Directly implements the goal's "validate it parses as PEM before including it" remedy; produces the same working result as (A) today (the invalid placeholder is excluded) but removes the whole invalid-PEM-poisons-the-bundle failure class and self-corrects when the real step-ca root arrives. (C) is the correct long-term shape but a multi-repo change beyond an interim heal.
**Key risks/assumptions:** The defect is in the **base image Dockerfile in the sibling `agentops-engine` repo** (this GitOps repo holds no Dockerfiles — it only pins images), so the code PR lands there while this design is committed here per instructions; `openssl` is assumed available at build time; skipped/invalid certs warn but don't fail the build.
