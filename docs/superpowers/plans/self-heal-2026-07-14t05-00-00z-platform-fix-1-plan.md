# Plan — Task self-heal-2026-07-14t05-00-00z-platform-fix-1

Implements the chosen design (Approach B — validate-before-include via the supported
`update-ca-certificates` file flow): gate the placeholder step-ca root on an
`openssl x509 -noout` PEM-parse check so an unparseable root can never poison the system
trust bundle and break all outbound HTTPS (curl/git) for pods on the image.

## Where the fix actually lands (verified, corrects a design assumption)

The design assumed only `agentops-platform` was checked out and that the offending step
`cat`-appended into `/etc/ssl/certs/ca-certificates.crt`. Both points are refined by what is
actually on disk:

- The sibling repo **is** checked out at
  `/workspace/cache/est1908-agentic-ops-agentops-engine` (branch `main`), so exact
  files/lines are known.
- The defect is **exclusively** in `images/agent-runner/Dockerfile` (lines 31–32) plus its
  companion cert file `images/agent-runner/step-ca-root.crt`. The `images/engine/Dockerfile`
  only `apt-get install`s `ca-certificates` with no custom root — it is **not** affected and
  is out of scope.
- The mechanism is not a manual `cat`-append. The Dockerfile already uses the *correct*
  file-based flow:
  ```dockerfile
  COPY step-ca-root.crt /usr/local/share/ca-certificates/step-ca-root.crt
  RUN update-ca-certificates
  ```
  The bug is that the copied `step-ca-root.crt` is invalid PEM (literal placeholder text
  referencing "M2 sub-project 2"), and `update-ca-certificates` concatenates every `.crt`
  in `/usr/local/share/ca-certificates/` into the bundle **without validating PEM content**.
  OpenSSL 3.0 then rejects the entire `ca-certificates.crt`. So Approach B's PEM-parse gate
  is exactly the missing piece; the file-based enrollment it prescribes is already present.

All three edited files live in `agentops-engine`; the implementing PR is opened there. This
plan document is committed in `agentops-platform` per the task's persistence instructions.
The CI build context is `images/agent-runner` (`.github/workflows/ci.yaml` job
`build-agent-runner-image`), so all `COPY` sources must stay inside that directory.

## Steps

### Step 1 — Reproduce the failure locally (de-risk before editing)
- **Files:** none (uses the existing
  `agentops-engine/images/agent-runner/step-ca-root.crt` and host OpenSSL 3.0.20).
- **What:** Confirm the placeholder is unparseable and that OpenSSL 3.0 fails on a bundle
  containing it — i.e. confirm the diagnosed root cause before changing anything.
- **Verify:**
  ```bash
  cd /workspace/cache/est1908-agentic-ops-agentops-engine/images/agent-runner
  openssl x509 -in step-ca-root.crt -noout            # expect: FAIL (non-zero) — invalid PEM
  cat /etc/ssl/certs/ca-certificates.crt step-ca-root.crt > /tmp/poisoned.crt
  openssl storeutl -noout -certs /tmp/poisoned.crt     # expect: error — whole bundle unparseable
  ```
  This proves the gate's premise (`openssl x509 -noout` rejects the placeholder) and the
  outage mechanism (one bad block breaks the whole bundle).

### Step 2 — Ensure the `openssl` CLI is present in the agent-runner image
- **File:** `agentops-engine/images/agent-runner/Dockerfile` (line 12).
- **What:** Add `openssl` to the existing install line so the gate binary is guaranteed
  available regardless of transitive deps:
  `apt-get install -y --no-install-recommends git ca-certificates curl openssl`.
- **Why a separate step:** the gate in Step 3 depends on `openssl` existing at build time.
  Making its availability explicit removes the design's "assume openssl is present" risk;
  if it was already pulled in transitively, this is a harmless no-op.
- **Verify:** `grep -n 'openssl' images/agent-runner/Dockerfile` shows it on the install
  line; the layer still resolves to a single `apt-get install` (no second network call).
  Full confirmation comes from the CI build in Step 5.

### Step 3 — Replace the unguarded copy+enroll with a validated, file-based enroll loop
- **File:** `agentops-engine/images/agent-runner/Dockerfile` (replaces lines 31–32).
- **What:** Copy candidate roots into a staging dir (inside the build context), and only
  promote each into `/usr/local/share/ca-certificates/` if it parses as a certificate;
  skip-with-warning otherwise; run `update-ca-certificates` **once** after the loop. Concretely:
  ```dockerfile
  # Extra root CAs are enrolled the supported way: each candidate is validated as
  # parseable PEM (`openssl x509 -noout`) BEFORE it is placed under
  # /usr/local/share/ca-certificates/ and picked up by update-ca-certificates.
  #
  # Why the gate: update-ca-certificates selects whole *files* by config; it does
  # NOT validate the PEM *content* inside a file. And OpenSSL 3.0 rejects the
  # ENTIRE ca-certificates.crt bundle if any single block is malformed — so one
  # unparseable root here would break ALL outbound TLS (curl/git) for every pod on
  # this image, not just step-ca trust. (This corrects the prior note that claimed
  # update-ca-certificates "skips invalid entries" — it does not.)
  #
  # The step-ca root is still a placeholder until platform issues the real one:
  # today it fails the gate and is skipped with a warning and the build still
  # succeeds; when the real PEM lands it passes the gate and is trusted with no
  # further Dockerfile change.
  COPY candidate-ca-roots/ /tmp/candidate-ca-roots/
  RUN set -eu; \
      mkdir -p /usr/local/share/ca-certificates; \
      for cert in /tmp/candidate-ca-roots/*.crt; do \
        [ -e "$cert" ] || continue; \
        name="$(basename "$cert")"; \
        if openssl x509 -in "$cert" -noout 2>/dev/null; then \
          cp "$cert" "/usr/local/share/ca-certificates/$name"; \
          echo "enrolling trusted CA: $name"; \
        else \
          echo "WARNING: skipping unparseable CA (not valid PEM): $name" >&2; \
        fi; \
      done; \
      rm -rf /tmp/candidate-ca-roots; \
      update-ca-certificates
  ```
- **Accompanying file move (part of this step):** `git mv` the existing
  `images/agent-runner/step-ca-root.crt` to
  `images/agent-runner/candidate-ca-roots/step-ca-root.crt` so the loop's glob finds it and
  it is no longer copied straight into the trusted dir. (The `COPY candidate-ca-roots/`
  form works whether the dir holds one file or several, satisfying the design's
  "one cert per file" intent without hardcoding the filename.)
- **Verify (local logic simulation — docker is unavailable on this host):** extract the loop
  body into a throwaway script and run it against the real placeholder plus a known-good root,
  pointing at a temp "trusted" dir:
  ```bash
  cd /workspace/cache/est1908-agentic-ops-agentops-engine/images/agent-runner
  mkdir -p /tmp/cand /tmp/trust
  cp candidate-ca-roots/step-ca-root.crt /tmp/cand/           # invalid placeholder
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
    -out /tmp/cand/valid-root.crt -days 1 -subj /CN=probe 2>/dev/null   # valid PEM
  for c in /tmp/cand/*.crt; do n=$(basename "$c"); \
    if openssl x509 -in "$c" -noout 2>/dev/null; then cp "$c" /tmp/trust/$n; \
      echo "enroll $n"; else echo "SKIP $n" >&2; fi; done
  ls /tmp/trust        # expect: valid-root.crt only; step-ca-root.crt absent
  cat /etc/ssl/certs/ca-certificates.crt /tmp/trust/*.crt > /tmp/bundle.crt
  openssl storeutl -noout -certs /tmp/bundle.crt   # expect: parses OK (no invalid block)
  ```
  This proves the placeholder is excluded, a valid root is enrolled, and the resulting bundle
  is parseable by OpenSSL 3.0 — the runtime contract, minus the container.

### Step 4 — Remove the now-false claim from the cert file's placeholder text
- **File:** `agentops-engine/images/agent-runner/candidate-ca-roots/step-ca-root.crt`
  (the moved file from Step 3).
- **What:** Rewrite the placeholder body so it no longer asserts
  `update-ca-certificates` "skips invalid entries with a warning" (that claim caused the
  outage). Keep it clearly a placeholder and clearly unparseable so the gate excludes it, but
  state the truth: it is intentionally skipped by the build's PEM-parse gate until the real
  step-ca root replaces it. Keep the "M2 sub-project 2 / agentops-platform" pointer to the
  eventual real-root source.
- **Verify:** `openssl x509 -in candidate-ca-roots/step-ca-root.crt -noout` still exits
  non-zero (placeholder remains correctly excluded); the misleading sentence is gone
  (`grep -n "skips invalid" candidate-ca-roots/step-ca-root.crt` returns nothing).

### Step 5 — Build verification via CI + on-cluster smoke (the real end-to-end gate)
- **Files:** none (validates the built image).
- **What:** Open the PR against `agentops-engine`; CI job `build-agent-runner-image`
  (`.github/workflows/ci.yaml`) builds and pushes
  `gitactions.est1908.top/agentic-ops/agent-runner:<sha>`.
- **Verify:**
  1. CI `build-agent-runner-image` succeeds, and its build log shows
     `WARNING: skipping unparseable CA (not valid PEM): step-ca-root.crt`.
  2. In a container from the new image (or `docker run` on a host that has docker):
     ```bash
     openssl storeutl -noout -certs /etc/ssl/certs/ca-certificates.crt   # parses OK
     curl -sSI https://github.com >/dev/null && echo curl-ok             # outbound TLS restored
     git ls-remote https://github.com/est1908-agentic-ops/agentops-platform.git >/dev/null 2>&1 \
       && echo git-ok
     ```
  3. `pnpm lint` (repo DoD) passes — the change is Dockerfile/data only, so lint/typecheck/test
     are unaffected, but run them to satisfy the engine repo's "green locally first" hard rule.
- **Note:** docker is **not** available on this planning host, so build/run verification (2)
  happens in CI and/or on the cluster, not locally. Local confidence comes from Steps 1 and 3,
  which reproduce both the failure and the fixed logic with the same OpenSSL 3.0 that runs in
  the image.

### Step 6 — Deployment note (no action in this repo, recorded for the operator)
- The live cluster runs whatever `agent-runner` tag `clusters/ops/engine/values.yaml`
  (`image.agentRunnerTag`) pins. That tag is bumped automatically by `agentops-engine` CI
  (`scripts/bump-platform-engine-tags.sh`) after the fix merges. No manual edit to
  `agentops-platform` is needed or wanted; per this repo's CLAUDE.md, tag fields are
  CI-managed. Recorded so nobody hand-edits the tag.

## Sequencing notes

- **Step 1 (reproduce) before any edit** — de-risks the whole plan by confirming the diagnosed
  root cause (`openssl x509 -noout` rejects the placeholder; one bad block kills the bundle)
  with the same OpenSSL major version the image uses. If Step 1 didn't reproduce, the fix would
  be aimed at the wrong thing.
- **Step 2 (install openssl) before Step 3 (the gate)** — the gate binary must exist at build
  time. Ordered first so the layer that the gate depends on is in place; it is also cheap and
  reversible.
- **Steps 3 and 4 are deliberately separate** even though both touch the cert file's world:
  Step 3 is the behavioral fix (the gate + file move) and Step 4 is a documentation-only text
  correction. They could be one commit, but keeping the false-comment removal distinct makes the
  behavioral change reviewable on its own and the text fix trivially verifiable.
- **Step 5 (CI/cluster build) last** — it exercises the real artifact and can only run after all
  source edits land; it is the authoritative end-to-end check, with Steps 1/3 as the local proxy
  given no local docker.
- The file move lives **inside Step 3** rather than as its own step because the `COPY`
  path change and the move are a single indivisible change — doing one without the other breaks
  the build.

## Assumptions

- **Cross-repo target, now concrete.** Design assumed the engine repo was not checked out; it
  **is**, at `/workspace/cache/est1908-agentic-ops-agentops-engine`. Resolution: the plan pins
  exact files (`images/agent-runner/Dockerfile` lines 12 and 31–32, and the `step-ca-root.crt`
  companion). The fix PR is opened against `agentops-engine`; this plan is committed in
  `agentops-platform` per the persistence instructions. Nothing changes in `agentops-platform`
  source (only the tag bump, which is CI-owned — Step 6).
- **Only agent-runner is affected.** Verified `images/engine/Dockerfile` installs
  `ca-certificates` with no custom root and no `update-ca-certificates` of an extra cert, so it
  cannot hit this bug. Assumption: no other image or build stage enrolls a custom root; the
  repo-wide grep for `usr/local/share/ca-certificates` and `step-ca` returned only the
  agent-runner references, supporting this.
- **`openssl` availability.** Rather than assume the CLI is transitively present (the design's
  open risk), Step 2 installs it explicitly. Assumption: adding `openssl` to
  `--no-install-recommends` is acceptable image-size-wise (a few MB) and preferable to a build
  that fails if the binary is absent.
- **Placeholder is kept, not deleted.** The placeholder still documents where the real step-ca
  root will go. Assumption: keeping it (moved under `candidate-ca-roots/`, still unparseable so
  the gate excludes it) is preferred over deleting it; when the real PEM replaces its contents
  it is enrolled automatically with no Dockerfile change. This matches design assumption 4.
- **No local docker.** The planning/implementation host has no docker daemon. Assumption: build
  verification is delegated to CI (`build-agent-runner-image`) and/or the cluster, and local
  verification uses the host's OpenSSL 3.0.20 to simulate the gate and bundle-parse contract
  (Steps 1, 3). This is sufficient to validate the *logic*; the image build itself is validated
  by CI before any tag bump reaches the cluster.
- **Multi-file candidate dir vs. single file.** The design says "one cert per `.crt` file".
  Assumption: staging a `candidate-ca-roots/` directory and globbing `*.crt` satisfies this and
  generalizes to future roots, at the cost of moving one file — an acceptable, minimal
  generalization over hardcoding the single filename.
