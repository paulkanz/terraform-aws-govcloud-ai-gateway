# ai-platform Runbooks (Enterprise-AI-Platform)

**Date:** 2026-09-16
**Author:** Paul Kanz
**Scope:** Operational runbooks for the `ai-platform` shared AI platform (LiteLLM
gateway + Phoenix + Bedrock egress). Each `aws_cloudwatch_metric_alarm` in
`ai-platform/observability.tf` links to a section here via `runbook_base_url`.
**Account / Region:** 123456789012 / `us-gov-west-1`.

Naming: `ai-platform-<env>` (poc/test/staging/prod). Cluster `ai-platform-<env>`,
services `litellm` and `phoenix`, internal ALB `ai-platform-<env>-litellm`.

## Invariants (never violate while remediating)

1. The AI tier is never a hard dependency for the application. Disabling the
   gateway must not block case-note creation (the app degrades to manual).
2. Phoenix being down is a no-op for users — never page-worthy beyond an export-
   failure notice.
3. Never open general egress from the AI subnets or `sg-litellm` to "fix" a
   connectivity issue — that breaks the egress lock. Use the endpoints.
4. Never enable Bedrock model-invocation body logging in prod, and never turn on
   LiteLLM `store_prompts_in_spend_logs` — both create a content archive.

## litellm-errors (alarm: litellm-5xx-high)

Symptom: gateway returning 5xx above threshold.

1. Check service health: `aws ecs describe-services --cluster ai-platform-<env>
   --services litellm` — running vs desired, recent events.
2. Pull logs: `/ecs/ai-platform-<env>/litellm` — look for Bedrock errors, DB/cache
   connection failures, config parse errors.
3. If Bedrock-side: see bedrock-throttle. If DB/cache-side: see litellm-db /
   litellm-cache.
4. If a bad config deploy: roll the ECS service back to the previous task-def
   revision (`aws ecs update-service --task-definition <prev-revision>`).
5. Containment: if one tenant is the source, that tenant's LiteLLM team budget /
   rate limit can be tightened, or the app-side feature flag disabled for them —
   the gateway does not need to go down for one tenant.

## litellm-health (alarm: litellm-unhealthy-targets)

Symptom: ALB reports unhealthy targets / no healthy targets.

1. Distinguish "gateway down" from "Swarm->ECS path down": the ALB target-health
   metric + `describe-target-health` on the `ai-platform-<env>-litellm` target
   group. Healthy targets present but clients can't reach = a networking/peering
   problem, not the gateway.
2. Gateway down: check task health, `/health/liveliness` (200 expected), logs.
3. Path down: verify the client peering + route (see the peering ids output;
   the client-side return route lives in terraform-system/preprod-legacy). Confirm
   the client VPC CIDR is in `allowed_client_cidrs` on the ALB SG.
4. Users are unaffected if the app degrades to manual — confirm the app's
   circuit breaker engaged.

## litellm-latency (alarm: litellm-latency-high, p95)

1. p95 approaching 55s means requests are nearing the 60s gateway timeout (and
   the app's 75s). Check Bedrock latency (dashboard) and cache/DB latency.
2. If Bedrock is slow, confirm the fallback alias is configured and engaging.
3. Not user-fatal — the app times out gracefully and offers save-as-manual.

## bedrock-throttle (alarm: bedrock-throttled)

1. Confirm the throttle on the dashboard (Bedrock InvocationThrottles).
2. Verify quota headroom: check the account's Bedrock model TPM/RPM quotas. If
   near the limit, raise a quota-increase request — GovCloud lead time is
   non-trivial, so do this early and proactively, not reactively.
3. Confirm the fallback alias engaged (LiteLLM router). If not, check the alias
   config in the mounted `config.yaml`.
4. Short term: the per-tenant/per-feature rate limits contain a runaway caller.

## litellm-db (alarm: litellm-db-cpu-high)

1. Aurora Serverless v2 should scale; if pinned at max ACU, a query storm or a
   loop. Check LiteLLM logs for retry loops.
2. This DB holds keys/teams/usage only — no content. It is control-plane; if it
   is unavailable, `allow_requests_on_db_unavailable=false` means the gateway
   fails closed (correct — better to fail than mis-authorize).
3. Restore: see CP-9 in the key-rotation/backup runbook. RDS backup retention
   14d; restore to a new cluster and repoint DATABASE_URL in SSM.

## litellm-cache (alarm: litellm-cache-ecpu-high)

1. The cache holds rate-limit counters only. A sustained-high (3x5min) ECPU is
   either legitimate high request volume or a runaway. Cross-check with the ALB
   request count.
2. Threshold is tuned to the counter workload (do not re-alarm on normal bursts —
   the tooling BullMQ lesson). If it is normal new baseline, raise
   `alarm_cache_ecpu_threshold`, do not silence.

## bedrock-egress-regression (no alarm — caught by the assurance test)

If `tests/egress-negative.sh` reports REACHED (an app host can reach a provider):
this is a **security incident**, not a reliability one.

1. Do not wait — an open egress path means participant content could leave via a
   re-added direct SDK call.
2. Check for: a new NAT/route on the AI subnets, a widened `sg-litellm` egress, a
   changed Bedrock endpoint policy, or an app-host egress rule that now permits
   the provider. `git log` the ai-platform tree + the client VPC route tables.
3. Revert the change; re-run the test to confirm BLOCKED.

## phoenix-outage (no page — informational)

Phoenix down must never affect users or the gateway. Telemetry export is fire-
and-forget with a circuit breaker on the app side.

1. Confirm no user impact (there should be none).
2. Restart the phoenix service; check `/ecs/ai-platform-<env>/phoenix` logs and
   its Aurora health.
3. The only alarm-worthy signal is a sustained export-failure rate on the app
   side (App-Integration-Epic owns that metric).
