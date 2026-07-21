#!/usr/bin/env bash
#
# Static validation of the GitOps manifests. Runs in CI (.github/workflows/lint.yaml)
# on every PR and locally via `./scripts/validate-manifests.sh`.
#
# Catches the classes of mistake that have broken the live cluster on merge to main,
# WITHOUT needing the SOPS age key (so it runs with zero secrets configured):
#
#   1. An ArgoCD Application repoURL pointing at GitHub over SSH. The repo is
#      private and ArgoCD has a token-based (HTTPS) credential only, so an SSH
#      repoURL fails with "authentication required: Repository not found" and the
#      app silently stops reconciling. See CLAUDE.md.
#   2. A KSOPS secret-generator referencing an encrypted secret file that was never
#      committed -- ArgoCD manifest generation then fails with
#      "no such file or directory" and the app goes Sync: Unknown.
#
# Runtime-only problems (e.g. a Helm value that's valid YAML but wrong, or a sync-wave
# ordering deadlock) are out of scope here -- the optional `render` job in the lint
# workflow does a full `kustomize build --enable-helm` when an age key is available.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

echo "== check 1: ArgoCD Application repoURLs use the HTTPS URL =="
if matches=$(grep -rnE "repoURL:[[:space:]]*[\"']?git@github\.com:est1908-agentic-ops" \
      --include="*.yaml" clusters/ bootstrap/); then
  {
    echo "ERROR: SSH GitHub repoURL(s) found (repo is private, token-based HTTPS credential only):"
    echo "$matches"
    echo "  -> use https://github.com/est1908-agentic-ops/agentops-platform.git"
  } >&2
  fail=1
else
  echo "OK: no SSH GitHub repoURLs"
fi

echo
echo "== check 2: KSOPS-referenced secret files exist =="
while IFS= read -r gen; do
  dir=$(dirname "$gen")
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -f "$dir/$rel" ]; then
      echo "OK: $gen -> $rel"
    else
      echo "ERROR: $gen references a missing secret file: $rel" >&2
      fail=1
    fi
  done < <(grep -oE '\.\.(/[^[:space:]"'\'']+)+\.(enc\.)?ya?ml' "$gen" || true)
done < <(find clusters -name secret-generator.yaml | sort)

echo
echo "== check 3: retired model gateway is absent from deployable manifests =="
if matches=$(rg -n -i 'lite[ -]?llm|litellm' clusters/ops secrets -g '!**/.git/**'); then
  echo "ERROR: retired model gateway reference(s) found:" >&2
  echo "$matches" >&2
  fail=1
else
  echo "OK: no retired model gateway references"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All manifest checks passed."
else
  echo "Manifest validation FAILED -- see errors above." >&2
fi
exit "$fail"
