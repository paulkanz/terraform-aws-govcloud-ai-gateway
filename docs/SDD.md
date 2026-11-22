# SDD: Enterprise-AI-Platform — Shared AI Platform Foundation (LiteLLM Gateway, Bedrock GovCloud, Phoenix)

**Date:** 2026-09-16
**Author:** Paul Kanz
**Status:** Draft for review
**Epic:** Enterprise-AI-Platform (Platform / DevOps) — the infrastructure half of the AI Case Note
Summaries initiative (`ai-case-note-summaries`), paired with App-Integration-Epic (application).
**Canonical design:** Confluence "AI Supported Case Note Summaries — Functional and
Technical Architecture" (page 3630825474) + three child pages. This SDD does NOT
restate that design; it is the buildable platform-layer spec that realizes the
Enterprise-AI-Platform slice of it.
**Account / Region:** 123456789012 / `us-gov-west-1` (GovCloud)
**Baseline:** NIST SP 800-53 Rev. 5, Moderate

---

## 1. Purpose and scope

Stand up the shared AI platform every Enterprise App AI capability will use: a LiteLLM
proxy on ECS Fargate as the single, network-enforced egress to Amazon Bedrock;
self-hosted Phoenix for metadata-only observability; the Bedrock and Transcribe
private-network access; and the IAM, KMS, S3 and networking that carry them. The
first feature (AI case notes) pays the whole platform cost; later features are
incremental.

**In scope (Enterprise-AI-Platform, Platform/DevOps):**

- LiteLLM proxy: ECS Fargate service, internal ALB, RDS PostgreSQL, ElastiCache,
  config, virtual keys.
- The Bedrock egress lock: VPC endpoint + endpoint policy + `sg-litellm` + SCP.
- Bedrock IAM (task role, model-ARN-scoped, no wildcards).
- Phoenix: ECS Fargate service, PostgreSQL, internal ALB, OIDC.
- Amazon Transcribe access (endpoint + IAM) for the app's transcription engine.
- KMS CMKs and S3 configuration the app/retention layers depend on.
- Networking: VPC placement, internal ALB, private Route 53, Swarm->ECS path.
- ECR repositories (immutable, digest-pinned) + image/secret scanning.
- Dashboards, alarms, runbooks, key-rotation.
- The two interface contracts that unblock the app/retention teams.

**Out of scope (owned by App-Integration-Epic):** the `ai-gateway` client library, prompt
catalog, `ai-case-note` services, artifact store *application* logic, retention
worker logic, all frontend, route authorization. This SDD defines the *contracts*
those consume, not their implementation.

## 2. Verified vs. unverified (read before designing)

**Verified (2026-09-16, acct 123456789012 / us-gov-west-1):**

- **Bedrock runtime endpoint exists.** `com.amazonaws.us-gov-west-1.bedrock-runtime`
  and `...bedrock-runtime-fips` are both offered as interface VPC endpoint services.
  The egress-lock design (PrivateLink to Bedrock, no NAT) is buildable as specified.
- **Amazon Transcribe endpoints exist.** `com.amazonaws.us-gov-west-1.transcribe`,
  `...transcribe-fips`, and `...transcribestreaming` (+fips) are all offered. The
  Transcribe engine option is architecturally available in-region — it is a
  cost/quality optimization vs. the Claude engine, not a availability gate.
- **The OIDC deploy identity pattern already exists.**
  `terraform-system/environments/central-ci-cd/oidc-github-actions.tf` provisions the
  GitHub Actions OIDC provider plus **one IAM role per (system, environment)**
  pair, scoped by the GitHub Environment `sub` claim (a data-platform-test run cannot assume
  data-platform-prod, nor another system's role). State at `terraform-state-west`,
  key `central-ci-cd/terraform.tfstate`. This is the same mechanism the AI platform's
  `tofu apply` should use — the AI platform is a new "system" in that model.
- **Bedrock model availability (per approved design, §14):** Claude Sonnet and Opus
  enabled in Bedrock `us-gov-west-1`; Haiku being enabled; direct transcription via
  Haiku/Sonnet tested. No model-availability risk; no spike needed.

**Unverified / confirm before build:**

- **[Q1 — the one true blocker] VPC placement.** Which VPC do the Docker Swarm
  hosts occupy per environment, and can ECS tasks be placed in that VPC (or a peered
  VPC with routing established) so the app can reach the internal ALB privately?
  Everything in the application track ultimately depends on this. Confirm in week
  one. (This SDD's §7 gives the two acceptable topologies; the choice needs the
  actual Swarm VPC ids.)
- **FIPS posture.** Both `-fips` and non-fips endpoints exist. Confirm whether the
  Moderate baseline / SC-13 obligation here requires the FIPS endpoints
  (`bedrock-runtime-fips`, `transcribe-fips`) and FIPS TLS. Default to FIPS unless
  told otherwise. *Verify.*
- **Where the AI platform state/repo lives (Q6).** Likely a new "system" under the
  `opentofu-ecs-services` / `central-ci-cd` model, or a new `terraform-system`
  environment. Decide before writing modules so state keys and OIDC roles are named
  right.
- **LiteLLM `store_prompts_in_spend_logs=false` actually suppresses bodies in this
  version.** Design-critical (§5). Verify empirically against the pinned image by
  inspecting the RDS tables after a test call; make it a recurring test.
- **Transcribe custom-vocabulary + KMS-in/KMS-out** for the async job path in
  GovCloud. *Verify when the Transcribe engine is chosen.*

## 3. Component: LiteLLM gateway (ECS Fargate)

| Aspect | Decision |
| --- | --- |
| Form | `litellm-proxy` container, pinned by **digest**, mirrored to a GovCloud ECR repo with `image_tag_mutability = "IMMUTABLE"`. Never pulled from a public registry at task start. |
| Runtime | ECS Fargate, private subnets, no public IP, **min 2 tasks across 2 AZs**, behind an internal ALB. |
| State | RDS PostgreSQL (Multi-AZ in prod) for virtual keys, teams, budgets, usage rows. ElastiCache for rate-limit counters. Both hold **no prompt/response content**. |
| Config | `config.yaml` version-controlled in the IaC repo, mounted from Parameter Store. Model list, aliases, routing are reviewed changes, not runtime admin actions. |
| Admin UI | **Disabled in staging and production.** |
| Environments | One deployment per environment; separate DBs and keys; no shared instance across env boundaries. |
| Scope | One shared instance per env serves all tenants; tenant attribution rides in request metadata (`team_id`), never in separate deployments. |

**The content-logging setting is the single most important LiteLLM config in the
whole design:** `store_prompts_in_spend_logs: false` (request/response bodies not
persisted). Verify by inspecting the DB after a test call and make that a recurring
test (§9), not a one-off.

**Model aliases** (app never names a model id): `case-note-summary` (Sonnet,
fallback smaller Claude on throttle), `case-note-transcribe` (Haiku/Sonnet),
`structured-extraction` (Sonnet, low temp, no fallback), `ops-analysis` (small
Claude, own budget). Unknown model names are rejected by the allow-list.

**Keys/attribution (AD-6):** one virtual key per *(service, feature)* — a small
stable set — with the **tenant carried as the LiteLLM team** (`metadata.team_id`),
so budgets/rate-limits/usage partition per agency without multiplying secrets.
`team_id` is derived server-side by the app from the validated JWT; the platform's
job is to enforce budgets/limits keyed on it, and to reject requests whose key is
unknown.

## 4. Component: the Bedrock egress lock (the load-bearing control)

This is what makes the whole thing an architecture rather than a diagram. Two rules,
both required:

1. **Endpoint-side (primary):** `com.amazonaws.us-gov-west-1.bedrock-runtime`
   interface VPC endpoint in the AI subnets, with an **endpoint policy** allowing
   only `bedrock:InvokeModel` / `InvokeModelWithResponseStream` on the approved
   model ARNs, and the endpoint's security group admitting **only `sg-litellm`**.
2. **Task role:** the LiteLLM ECS task role holds only those two Bedrock actions,
   `Resource` restricted to the specific approved model/inference-profile ARNs — **no
   wildcards**. Adding a model is an IaC change under review.
3. **SCP / permission boundary:** deny `bedrock:*` to every principal except the
   LiteLLM task role — no app role, CI role, or developer role can reach Bedrock
   directly.
4. **Host-side (defense in depth):** Swarm host egress rules deny the public provider
   endpoints (`api.anthropic.com`, etc.). Coarser than per-task on Swarm — treat the
   endpoint-side rule as primary.

**Enforcement evidence (SC-7 / AC-4):** a negative integration test asserting a
direct provider call from an application host times out at connect. If a future dev
re-adds `new Anthropic({apiKey})`, it must fail at connect time in every deployed
environment. Delivered in the OpenTofu module + the test.

No NAT route from the AI subnets. TLS 1.2+ (FIPS — verify §2) to the endpoint;
traffic never traverses the public internet. **Do not enable Bedrock model-invocation
body logging in prod** — it would create an S3 archive of participant prompts;
metadata-level only.

## 5. Component: Phoenix (ECS Fargate, metadata-only)

Two separable decisions (AD-2): **run Phoenix** (platform deliverable) and **what the
app sends it** (app decision — metadata only). Enterprise-AI-Platform owns the former.

| Requirement | Implementation |
| --- | --- |
| Residency | ECS Fargate, private subnets, no internet egress, `us-gov-west-1`. |
| Persistence | PostgreSQL (not SQLite), encryption at rest, automated backup, documented retention. |
| Access | Behind the internal ALB, OIDC against the same IdP, never public. |
| Content suppression | Enforced app-side (instrumentor suppresses span input/output), but the platform posture assumes it and the marker-string test (§9) asserts it continuously. |
| Retention | Span retention <= 30 days, enforced, documented purge job. |
| Hard dependency | **Never.** Telemetry export is fire-and-forget; Phoenix down must not fail anything. Alarm on export-failure rate only. |
| SSP | Treated as in-boundary (processes data derived from participant records), with its own control-inheritance statement. |

## 6. Component: Amazon Transcribe access

The app's `TranscriptionService` picks an engine behind one interface; the platform
provides the Transcribe path so the choice is measurement, not availability:

- `com.amazonaws.us-gov-west-1.transcribe` interface VPC endpoint (FIPS variant per
  §2), IAM for `StartTranscriptionJob` / `GetTranscriptionJob` scoped to the app's
  role, KMS on the S3 input/output prefixes both ways.
- The Claude-via-Bedrock transcription path needs no new platform work beyond the
  gateway (it is the `case-note-transcribe` alias). So Transcribe is provisioned as
  an option, not a prerequisite — the app is never blocked on it.

## 7. Networking — the Swarm->ECS path (Q1)

The AI ECS services live where the Swarm hosts can reach them **privately**. Two
acceptable topologies; the choice needs the actual per-env Swarm VPC ids (Q1):

- **(A) Same VPC.** AI ECS tasks in private subnets of the Swarm hosts' VPC.
  Simplest routing.
- **(B) Peered VPC.** AI ECS in a dedicated VPC peered to the Swarm VPC with routes
  already established both directions. More isolation; matches the Data-Platform peering
  pattern already in use.

Either way:

- Enterprise App reaches LiteLLM/Phoenix via an **internal ALB** in private subnets,
  resolved by a **private Route 53 record** — not through Traefik, not a public
  listener. The ALB security group admits **only the Swarm hosts' security group**.
- Auth across the boundary: LiteLLM virtual key from Parameter Store over in-VPC TLS.
  The **network rule is primary**; the key identifies the caller. Key gets a key id
  and rotation runbook from day one (AD-10 / Finding H-7).
- When Enterprise App later migrates to ECS, nothing in the app changes — the service URL
  stays; the app-side egress rule just becomes per-task instead of per-host.

**Anything that forces traffic over the public internet defeats the whole design.**
Confirm VPC placement in week one; the app team builds against a gateway stub until
the path exists, so a delay affects integration, not development.

## 8. IaC, deploy identity, and repository placement

- Modules in OpenTofu (matches the org's `opentofu-ecs-services`/`central-ci-cd`
  direction and the Data-Platform/terraform-fargate ecosystem). Lock file pinned to
  `registry.terraform.io` — do NOT let an init flip it to `registry.opentofu.org`
  (see `docs/provider-registry-mismatch.md`; that mismatch already broke uat/tooling).
- **Deploy identity:** reuse the `central-ci-cd` OIDC pattern — one IAM role per
  (system, environment), GitHub-Environment-scoped by `sub`. The AI platform is a new
  *system* (e.g. `ai-platform`) with `test`/`staging`/`prod` roles. No long-lived
  keys.
- **State backend:** the existing `terraform-state-west` bucket /
  `terraform-state-lock-west` table under an `ai-platform/...` (or agreed) key prefix.
- **ECR:** per-service repos (`litellm-proxy`, `phoenix`) with
  `image_tag_mutability = "IMMUTABLE"`, digest-pinned, image scanning on push with a
  documented severity threshold. Mirror upstream images in; never pull public at task
  start.
- **No new application repository** is created by this epic; infra lands in the
  Platform team's existing IaC repo.

## 9. Platform-owned tests (evidence, not vibes)

| Test | Asserts | Control |
| --- | --- | --- |
| **Egress negative test** | A direct provider/Bedrock call from an application host **times out at connect**. | SC-7, AC-4 |
| **Content-logging test** | After a test completion, the LiteLLM RDS tables contain **no request/response body**. Runs every deploy. | AC-4, SI-12 |
| **Marker-string log-inspection** | Run a full flow with a unique marker in the "transcript"; grep every log sink, the LiteLLM DB, Phoenix spans, CloudWatch — marker appears **nowhere**. | AU-2, SI-12 |
| **IAM scope test** | The LiteLLM task role can invoke only the approved model ARNs; a non-approved model ARN is denied; no other principal can reach Bedrock. | AC-6 |
| **KMS test** | Objects on the AI prefixes are KMS-encrypted with the expected per-tenant CMK. | SC-12/SC-28 |
| **Key-rotation runbook walkthrough** | The LiteLLM virtual key can be rotated end-to-end in a lower env with no outage. | IA-5 |

## 10. Interface contracts (unblock app + retention — agree these first)

Two documents, not code. Agreeing them costs an hour and unblocks the application and
retention teams to build against stubs/seeds before the platform lands.

**(a) Gateway contract (Parameter Store + request shape):**

- Parameter Store paths for the gateway URL and per-feature virtual keys
  (e.g. `/ecs/enterprise-app/<env>/ai/litellm/url`, `/ecs/enterprise-app/<env>/ai/litellm/key/<feature>`).
- Request: OpenAI-compatible `POST /v1/chat/completions`; `Authorization: Bearer
  <feature virtual key>`; `metadata.team_id = <tenant>` (server-derived only);
  `model = <alias>`; `metadata.{feature, request_id, session_id, prompt_id,
  prompt_version, user_ref}`.
- Timeouts nested: Bedrock 45s, LiteLLM 60s, app 75s, browser 90s.
- Response includes usage + a call id; unknown alias / over-budget / rate-limited
  return typed, documented statuses the app maps to `AI_*` errors.

**(b) `AiArtifact` metadata schema** — the contract between the app (writer) and the
retention worker (reader/updater). The platform owns the S3 buckets/prefixes, KMS,
and the S3 lifecycle backstop (`staging` 24h; `retained` = `expiresAt + 7d`, firing
= alarm). The schema itself (fields, state machine) is defined in the approved design
§19 and is reproduced in the retention card; Enterprise-AI-Platform provides the storage + lifecycle
that back it.

## 11. NIST mapping (platform-owned slice)

Per the design's layered-ownership model, these are the **platform** and **AI-platform**
control layers (the app/process layers are App-Integration-Epic):

| Control | Platform implementation | Evidence |
| --- | --- | --- |
| AC-4 Information Flow | No NAT from AI subnets; endpoint policy + `sg-litellm` single egress; PrivateLink | Route tables, SG rules, egress negative test |
| AC-6 Least Privilege | Bedrock task role scoped to model ARNs; SCP denies `bedrock:*` elsewhere | IAM docs, IAM scope test |
| AU-2/AU-12 | CloudTrail on `InvokeModel` + S3 data events (no payload) | CloudTrail queries |
| AU-6/SI-4 | CloudWatch alarms (error rate, throttle, schema violations, delete failures, orphans, budget, prompt/policy change) each with runbook + named responder | Alarm IaC, runbooks |
| CM-6/CM-7 | LiteLLM admin UI off in stage/prod; only needed Bedrock actions; unused aliases removed | Config baselines |
| CM-8/SR-3/SR-4 | SBOM per image; digest-pinned immutable ECR; no floating public pulls | SBOM, ECR digests |
| IA-5 | No model API key exists (SigV4/role); any Phase-1 virtual key in Parameter Store with key id + rotation runbook | Secrets inventory, rotation record |
| SC-7 Boundary | Private subnets, single SG-enforced egress, PrivateLink, WAF at edge | Plans, SG/route exports, boundary test |
| SC-8/SC-13 | TLS 1.2+ (FIPS — verify) everywhere incl. in-VPC; SigV4 to Bedrock | TLS config; FIPS endpoint confirmation |
| SC-12/SC-28 | Per-tenant CMK, SSE-KMS set explicitly, RDS/ElastiCache encrypted | KMS policies, KMS test |

"It runs in GovCloud" answers none of these — each is a control we configure on top
of an inherited AWS control, and the evidence column is the platform's half.

## 12. Sequencing (platform track — entirely unblocked)

Nothing in Enterprise-AI-Platform depends on an application card; the Platform team can start today.

1. **Week one:** answer Q1 (VPC placement) and the FIPS-posture question; agree repo/
   state placement (Q6) and the §10 interface contracts.
2. Network foundation + the Bedrock egress lock (endpoint, policy, `sg-litellm`, SCP)
   + the egress negative test.
3. Bedrock IAM (model-ARN-scoped) + SCP.
4. LiteLLM on ECS (RDS, ElastiCache, internal ALB, config, content-logging-off) +
   the content-logging test.
5. KMS CMKs + S3 configuration + lifecycle backstops (unblocks the app artifact store
   and the retention worker via the §10(b) contract).
6. Phoenix on ECS (metadata-only posture).
7. Transcribe provisioning (option, not a gate).
8. Dashboards + alarms (each with a runbook + named responder).
9. Secret + image scanning; SBOM.
10. Platform runbooks (LiteLLM failover, Bedrock throttling, Phoenix outage = no-op,
    key rotation).

## 13. Open questions (platform)

- **Q1:** Per-env Swarm VPC ids and whether ECS can sit in that VPC or a peered one
  (blocking; week one).
- **FIPS:** Do we use the `-fips` Bedrock/Transcribe endpoints and FIPS TLS at
  Moderate? (default yes; verify).
- **Q6:** AI platform state/repo placement and system name in the OIDC model.
- **AD-10:** Static virtual key (with rotation) in Phase 1, or SigV4/mTLS immediately?
- **Q5:** Does `SplunkLogAnalysisService` survive the CloudWatch move — does the
  `ops-analysis` alias/budget need provisioning at all?
- **LiteLLM body-suppression** verified against the pinned image version.

## 14. Shared-module reuse decisions

ai-platform reuses the repo's shared `modules/*` where they fit and hand-rolls
only where reuse would require modifying a module that enterprise-app/Data-Platform depend on.
Outcome of the reuse audit (2026-09-17):

| Module | Decision | Reason |
|---|---|---|
| `modules/database` | **REUSED** (litellm_db, phoenix_db) | Fit as-is; added a `master_user_secret_arn` output. Gains enhanced monitoring the inline version lacked. |
| `modules/cache` | **REUSED** (litellm_cache) | Fit as-is; added `redis_password_ssm_arn/_name` outputs. Gains Valkey AUTH (user + token) the inline version lacked — a security improvement, not just consistency. |
| `modules/networking` | inline | The module always creates public subnets + IGW + NAT (not gated). ai-platform is private-only, no NAT (the egress lock depends on it). Reuse would require adding create_public/create_nat/create_igw gates to a shared module — deferred as its own generalization decision, not slipped into this PR. |
| `modules/security` | inline | The module hardwires a WAF + enterprise-app-shaped SGs. ai-platform has no WAF (internal ALB) and AI-specific SGs (litellm/vpce/egress-lock). Not gate-able today. |
| `modules/monitoring` | inline | The module's alarm *set* is enterprise-app's (ALB/RDS/cache/WAF/NAT/services); ai-platform needs a different set (Bedrock throttle, gateway p95) with no variable to inject them. |
| `modules/compute` | inline | The module is the 33-service PUBLIC ALB + service map + enterprise-app DNS. ai-platform is 2 internal services on an internal ALB. Fundamentally different. |

**Honest note:** the four inline decisions are justified *for this PR*, but the
cleaner long-term answer for networking/security is to generalize those shared
modules with private-only / no-WAF gates so every platform shares them. That is a
larger refactor with blast radius on enterprise-app/Data-Platform and is degovcloud-aitely out of
scope here — tracked as a follow-up.
