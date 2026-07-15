# Remove LiteLLM from Agentic Ops

## Goal

Eliminate LiteLLM from both `agentops-engine` and `agentops-platform`. No shipped
engine code, deployment manifest, secret, test, or current operational document
will reference or depend on LiteLLM.

## Sequencing

The work is split into two pull requests and merged in order:

1. **Engine PR** removes the LiteLLM backend and all of its engine-facing wiring.
   The resulting image cannot route work to LiteLLM.
2. **Platform PR** pins that engine image, then removes the LiteLLM ArgoCD
   application and all associated configuration, encrypted secrets, database
   bootstrap, and operational documentation. The Application deletion must use
   ArgoCD's cascading resources finalizer so its live resources are pruned rather
   than orphaned.

This ordering keeps the proxy available until every deployed worker has been
replaced by code that no longer uses it.

## Engine PR

Remove the `litellm` model-backend enum value, `LiteLlmBackend` implementation,
worker construction and environment validation, Helm secret injection/defaults,
and LiteLLM-specific error handling. Remove its E2E/unit tests and update
allow-lists in Control/UI so persisted or newly submitted tier data cannot select
it. Update non-historical operational docs and diagrams to describe the remaining
direct CLI/provider backends.

Existing tier records containing `litellm` will be invalid under the updated
schema and therefore cannot run; operators must replace those entries with a
supported backend before using that tier.

## Platform PR

First update the engine chart revision and all image tags to the engine PR's
merge commit. Then remove the LiteLLM child Application with an ArgoCD
`resources-finalizer.argocd.argoproj.io` deletion path, the component directory,
the three encrypted LiteLLM secret files, and the engine-secrets copy. Remove all
current documentation references and update component listings.

The LiteLLM PostgreSQL role/database is an unused credential store after the
Application is gone. The PR will supply an idempotent ArgoCD cleanup Job that
drops the `litellm` database and role only after the engine image has removed all
LiteLLM usage; the Job removes itself after completion.

## Verification

Each repository will run its focused tests and type/chart/manifests validation.
Before each PR is opened, a case-insensitive tracked-file search (excluding only
historical change records) must return no LiteLLM implementation or deployment
references. The platform rendered manifests will be checked to confirm no
LiteLLM Application, Secret, Service, Deployment, Job, database role, or database
is retained.
