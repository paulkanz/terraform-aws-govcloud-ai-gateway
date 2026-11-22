# ai-platform (Enterprise-AI-Platform) — NIST 800-53 Rev. 5 Control Coverage

**Date:** 2026-09-16
**Author:** Paul Kanz
**Scope:** The `ai-platform/` Terraform root as committed on
`feature/Enterprise-AI-Platform-ai-platform-poc` (network + Bedrock egress lock, LiteLLM gateway
+ policy config, Phoenix). NOT the application/retention layers (App-Integration-Epic).
**Baseline:** NIST SP 800-53 Rev. 5, Moderate.
**Account / Region:** 123456789012 / `us-gov-west-1` (GovCloud).
**Reference:** docs/sdd-it-2962-ai-platform-foundation.md; canonical design
Confluence 3630825474 §31.

## Purpose and honesty note

Maps the controls the **committed Terraform actually enforces** to the specific
resources, then lists the controls that are **designed but not yet coded**, and
gives a straight posture read. A control appears in §1 only if a resource in the
tree enforces it today; aspirational coverage is in §2. "It runs in GovCloud"
is not claimed as coverage for anything — each row names what this code configures
on top of the inherited AWS control.

## 1. Controls the committed Terraform enforces

| Control | Name | Where enforced (verified resource) |
|---|---|---|
| AC-3 | Access Enforcement | Scoped IAM role policies: `iam.tf` litellm_task (Bedrock InvokeModel on approved ARNs only), litellm_ssm (SSM path-prefix scoped); `phoenix.tf` phoenix_task (SSM prefix + KMS only). |
| AC-4 | Information Flow Enforcement | `network.tf`: private-only subnets, **no NAT / no internet route** for the AI subnets; `aws_vpc_endpoint.bedrock_runtime` endpoint policy admits only the litellm_task role on approved model ARNs; `sg-litellm` egress restricted to the endpoint SG (no `0.0.0.0/0`); interface/gateway endpoints keep AWS traffic on PrivateLink. This is the egress lock. |
| AC-6 | Least Privilege | `iam.tf`: separate task vs execution roles; Bedrock resource list is explicit ARNs, **never `*`**; per-service task roles (litellm, phoenix) scoped to only their SSM paths and KMS keys. **All IAM policies are customer-managed (`aws_iam_policy` + `aws_iam_role_policy_attachment`), NOT inline `aws_iam_role_policy`** — so this stack is clean against the `iam-no-inline-policy-check` conformance rule (unlike the Data-Platform precedent, which regressed it 127->185). Zero inline role policies. |
| AU-2 / AU-3 | Event Logging / Content | `litellm-service.tf` + `phoenix.tf` awslogs to KMS-encrypted CloudWatch log groups (`litellm-datastores.tf`, `phoenix.tf`); Aurora `postgresql` log export implicit via cluster. |
| AU-9 | Protection of Audit Information | Log groups are KMS-encrypted (`kms_key_id = aws_kms_key.platform.arn`). |
| CM-6 / CM-7 | Configuration Settings / Least Functionality | LiteLLM config (`litellm-config.tf`) sets `disable_admin_ui=true`, `store_prompts_in_spend_logs=false`, `STORE_MODEL_IN_DB=false`; only mapped aliases resolve (model allow-list); only the two Bedrock InvokeModel actions granted; support-endpoint list is explicit. |
| CM-8 / SR-4 | Component Inventory / Provenance | `litellm-service.tf` + `phoenix.tf` images referenced by **digest** (`@sha256:...`), pulled from `aws_ecr_repository` with `image_tag_mutability = "IMMUTABLE"` and `scan_on_push = true`. No floating tags, no public pulls. |
| IA-5 | Authenticator Management | No model API key exists — Bedrock via SigV4 under the task role (`iam.tf`, no credentials block in the LiteLLM model config). Gateway master/salt/feature keys are generated (`random_password`) and stored as SSM SecureString, KMS-encrypted; never in code or env. |
| SC-7 | Boundary Protection | `network.tf`: dedicated VPC, private subnets, internal ALB (`internal=true`, `assign_public_ip=false`), SG-enforced single egress path, PrivateLink endpoints, cross-VPC access via explicit peering + CIDR-scoped ALB ingress only. |
| SC-8 | Transmission Confidentiality | `litellm-service.tf` HTTPS listener, `ssl_policy = ELBSecurityPolicy-TLS-1-2-2017-01`, `drop_invalid_header_fields = true`; SigV4/TLS to Bedrock over the endpoint; DB/cache reached over TLS (`rediss://`). |
| SC-12 / SC-13 | Key Management / Cryptography | `aws_kms_key.platform` with `enable_key_rotation = true`; used for logs, RDS (`storage_encrypted`, `kms_key_id`), ElastiCache (`kms_key_id`), ECR, and SSM SecureStrings. |
| SC-28 | Protection at Rest | RDS `storage_encrypted=true`; ElastiCache `kms_key_id`; ECR `encryption_type=KMS`; every SSM param is SecureString with `key_id`; CloudWatch log groups KMS-encrypted. |
| SC-5 (partial) | Denial of Service Protection | LiteLLM `router_settings` retry policy retries only 429/5xx (never a 400), `num_retries=2`, cooldown/allowed_fails set (`litellm-config.tf`). Per-key/per-tenant rate limits are runtime LiteLLM config, seeded but enforced by the proxy. |
| AU-6 / SI-4 | Audit Review / Monitoring | `observability.tf`: SNS topic + 6 CloudWatch alarms (gateway 5xx / unhealthy / p95 latency, Bedrock throttle, RDS CPU, cache ECPU), each with a runbook ref and SNS action; CloudWatch dashboard. VPC flow logs to a KMS-encrypted group. |
| AU-2 (edge) | ALB access logging | `alb-logs.tf`: SSE-S3 log bucket (TLS-only, versioned, lifecycle) wired into the internal ALB. |
| CM-2 / SI-4 | Baseline / drift detection | `config-rules.tf`: AWS Config rules (rules only — account recorder pre-exists) asserting no-open-ingress/ssh, ALB logging, RDS encryption. |
| CM-3 / AC-6 (deploy) | Change Control / scoped deploy identity | `oidc-deploy.tf`: GitHub Actions OIDC role bound to the `ai-platform-<env>` GitHub Environment via the `sub` claim; explicitly **denies `bedrock:*`** (only litellm_task reaches Bedrock). No long-lived keys. |

## 2. Designed but NOT yet coded (remaining gaps)

Updated 2026-09-16 after the assurance layer landed (`observability.tf`,
`alb-logs.tf`, `config-rules.tf`, `oidc-deploy.tf`). What remains:

| Control | Name | Gap — what is still missing |
|---|---|---|
| **AC-4 (rule 3)** | Information Flow — SCP | The org SCP/permission-boundary denying `bedrock:*` to every principal except litellm_task is **documented but not created** — it is an org-management-account resource, outside this account-local root. The deploy role now self-denies bedrock:*, but a global SCP is still the belt-and-suspenders. Own card. |
| **AU-12** | Audit Generation | **No CloudTrail resource** in this tree for `InvokeModel` / S3 data events — assumed inherited from an org trail. Must be CONFIRMED to cover this account/VPC/endpoint (verification task, not necessarily new code). |
| **RA-5 / SA-11** | Vuln Monitoring / Dev Testing | ECR `scan_on_push` on + a Config drift rule now exist, but the **four platform tests** (egress-negative, content-logging, marker-string, IAM-scope) are **CI/test code, not TF** — still unwritten. No image-scan-finding alarm yet. |
| **IA-2 / IA-5 (svc-to-svc)** | Auth | Phase-1 static gateway key: **rotation runbook** (AD-10) still a doc task; OIDC in front of Phoenix still a CONFIRM (ALB authenticate-oidc action not coded — needs the IdP client). |
| **SC-13 (FIPS)** | Cryptography | Endpoints default to `-fips`; the FIPS obligation is still a **CONFIRM**. |
| **CP-9 / CP-10** | Backup / Recovery | RDS backup retention set, but no documented restore runbook and no config/SSM backup story. |
| **SI-12** | Retention | Owned by the app/retention layer (App-Integration-Epic), not this tree. |

## 3. Additional controls worth implementing that the design under-specifies

Beyond the design's own gap list, a few Moderate controls the platform layer
should own and neither the code nor the SDD fully nails:

- **CP-9 / CP-10 (Backup / Recovery).** RDS has `backup_retention_period` (14d
  litellm, 7d phoenix) — good — but there is no documented restore procedure and
  no ElastiCache/SSM-config backup story. The LiteLLM virtual-key DB is
  operationally load-bearing; a restore runbook is a real Moderate expectation.
- **CM-2 baseline drift (AWS Config).** No AWS Config rules asserting the
  egress-lock invariants (e.g. "no `0.0.0.0/0` egress on sg-litellm", "no public
  ALB in this VPC"). Config rules would catch a drift the tests only catch at
  deploy time.
- **AC-2 (account/session lifecycle).** Not applicable to the platform layer
  directly, but the LiteLLM feature-key lifecycle (issue/rotate/revoke) needs an
  owner — currently keys are generated once and never rotated by code.
- **SI-7 (integrity) for the config.** The `config.yaml` is rendered and pushed to
  SSM, but nothing verifies at runtime that the running config matches the
  intended one (a drift between an out-of-band SSM edit and the IaC). A
  periodic config-integrity check would close this.
- **SC-5 hard budget stop.** The design calls for a configurable hard budget stop;
  the code seeds budgets but does not encode the hard-stop threshold as enforced
  infrastructure.

## 4. Current security posture

**Strong where it matters most — the data-egress boundary — and thin on the
detective/monitoring half. This is a preventive-controls-first posture with the
audit/response controls still to come.**

**What is genuinely strong (verified in code):**

- The **egress lock is real, not a diagram.** Private subnets, no NAT, endpoint
  policy + `sg-litellm`-only, model-ARN-scoped IAM with no wildcards, no
  `0.0.0.0/0`. A re-added direct provider SDK call fails at connect. This is the
  single most important control in the whole design and it is implemented.
- **No credentials to leak** — SigV4 under a role; the class of defect that put an
  Anthropic key in git cannot recur here.
- **Encryption is comprehensive** — KMS at rest on every store (RDS, cache, ECR,
  logs, SSM), TLS 1.2 in transit, rotation on.
- **Least privilege is honest** — separate task/exec roles, explicit ARNs, no
  wildcard resources except one documented Transcribe case.
- **Supply chain** — digest-pinned, immutable, scan-on-push ECR; no public pulls.
- **No content persistence** — `store_prompts_in_spend_logs=false`, admin UI off,
  metadata-only Phoenix posture.
- **Everything private** — internal ALB, no public IPs, no public listener.

**What is missing / weak (honest gaps):**

- **The SCP deny (egress-lock rule 3) is still not enforced** at the org level —
  the endpoint/SG layers plus the deploy role's self-deny cover it locally, but a
  global org SCP is still owed (org-management account, not this root).
- **The four assurance tests are unwritten** (egress-negative, content-logging,
  marker-string, IAM-scope) — CI/test code, not TF; they are the evidence the
  preventive controls actually hold. Now the top gap.
- **CloudTrail + FIPS coverage assumed, not verified.**
- **Static Phase-1 gateway key with no rotation code**; Phoenix OIDC front not
  coded (needs the IdP client).

**One-line read (updated 2026-09-16, post-assurance-layer):** the detective/
monitoring gap is now largely closed — SNS-routed alarms with runbooks (AU-6),
VPC flow logs, ALB access logs, Config drift rules (CM-2), and a scoped OIDC
deploy identity that self-denies `bedrock:*` (CM-3/AC-6), on top of the already
production-grade SC-7/AC-4 preventive core. The platform-layer control set is now
**substantially complete**; the remaining Moderate gaps — the **org-level SCP**,
the **four CI tests** (evidence), and **CloudTrail/FIPS confirmation** — are org-
scope config or test code, none of them account-local Terraform in this root.

## 5. Priority order to close the gaps

1. **The four platform tests** (egress negative, content-logging, marker-string,
   IAM-scope) — they are the evidence that the strong preventive controls actually
   hold, and they are cheap. (RA-5/SA-11/AC-4/SI-12 evidence.)
2. **Alarms + SNS + dashboards** with runbooks and named responders — closes the
   AU-6/SI-4 gap, the single largest hole.
3. **VPC flow logs + confirm CloudTrail** covers this account/VPC + Bedrock.
4. **The OIDC deploy role** for the `ai-platform` system (CM-2/CM-3).
5. **The SCP deny** `bedrock:*` (org-account change — its own card).
6. **Confirm FIPS**; add ALB access logs; add the key-rotation runbook + Config
   drift rules for the egress-lock invariants.
