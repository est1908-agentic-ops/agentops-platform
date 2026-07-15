# Platform simplification audit

This is a static dependency audit of `agentops-platform` and the sibling
`agentops-engine` repository. Live-use conclusions require cluster access; this
environment does not have `kubectl`.

| Candidate | Evidence | Recommendation |
| --- | --- | --- |
| LiteLLM deployment, secrets, and engine backend | No remaining engine runtime path; dedicated Argo CD app and secrets are removed in this change | Remove now |
| Mailpit | It has its own Application and ingress, but no engine or platform manifest references it as a dependency | Remove after confirming no operator/non-prod email workflow needs it |
| Postgres exporter | Dedicated Application; exporter is referenced only for database-size monitoring in the runbook | Remove after confirming dashboards/alerts do not query its metrics |
| Technitium | Dedicated DNS deployment; bootstrap/runbook and internal names depend on cluster DNS | Retain |
| Step-CA and cert-manager/Let's Encrypt | Issuers and certificate resources depend on them for internal and public ingress | Retain |
| LGTM observability stack (Alloy, Loki, Tempo, Prometheus, Grafana) | Engine values export OTLP to Alloy; Grafana is the documented operator surface | Retain |
| Temporal and PostgreSQL | Engine workflows and run-stat/project data depend on them | Retain |
| Project-workers ApplicationSet and generators | Engine gateway consumes its plugin route and workers are the execution model | Retain |
| Engine-secrets and project-workers-secret | Applications mount generated credentials and webhook/plugin tokens | Retain |

The two low-risk follow-ups are Mailpit and postgres-exporter, but both require
live configuration/metrics evidence before deletion. No additional component is
removed in this PR.
