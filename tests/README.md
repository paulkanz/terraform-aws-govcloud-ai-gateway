# ai-platform assurance tests

The four SDD §9 assurance tests — the evidence that the strong preventive controls
actually hold. Split by what they can prove:

| Test | Type | When | Proves | Control |
|---|---|---|---|---|
| IAM scope (no wildcard Bedrock) | `terraform test` | every PR (plan) | Bedrock grant is explicit ARNs, never `*` | AC-6 |
| Content logging disabled | `terraform test` | every PR (plan) | `store_prompts_in_spend_logs=false`, admin UI off, telemetry off | SI-12 / CM-7 |
| Egress-lock structure | `terraform test` | every PR (plan) | internal ALB, no public IP, no-retry-400, timeout <= 60s | SC-7 / AC-4 |
| **Egress-negative** | shell (SSM) | post-deploy | an app host CANNOT reach Anthropic or the Bedrock endpoint directly | AC-4 / SC-7 |
| **Marker-string leak** | shell | post-deploy | a marker in a request appears in NO platform sink (RDS, logs) | SI-12 / AU |

## Run

Plan-time (no AWS, gates PRs):

```
cd ai-platform && terraform test
```

Post-deploy (against a live env):

```
# from CI/ops with SSM access; <app-host> is a Swarm host in the client VPC
ai-platform/tests/egress-negative.sh <app-host-instance-id> us-gov-west-1

# from inside the VPC / a bastion that can reach the gateway + RDS
ai-platform/tests/marker-string.sh poc us-gov-west-1
```

## CI wiring (SDD §9)

- The `terraform test` run is a **blocking PR gate** on any change under
  `ai-platform/` — scoped, fast, no AWS credentials needed.
- `marker-string.sh` runs on **every deploy** (the SDD calls this out as recurring,
  not one-off) — a content leak must fail the deploy.
- `egress-negative.sh` runs post-deploy in a lower env and on a schedule; a
  regression (egress opened) pages.

## Notes

- The app-side content sinks (application logs, Splunk, the event store, Phoenix
  spans as emitted by the app instrumentor) are covered by the app-side version of
  the marker-string test in App-Integration-Epic. These scripts cover the PLATFORM's sinks.
- The egress-negative test asserts a *timeout*, which is why it cannot be a
  `terraform test` assertion — it needs a live host with no route.
