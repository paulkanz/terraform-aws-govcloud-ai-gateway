# ai-platform Interface Contracts (Enterprise-AI-Platform <-> App-Integration-Epic)

**Date:** 2026-09-16
**Author:** Paul Kanz
**Purpose:** The two contracts the SDD §10 says to "agree first". These unblock
the application (`ai-gateway` library, summarization) and retention teams to build
against stubs/seeds before the platform is applied. Agreeing them costs an hour;
not agreeing them serializes three teams.
**Status:** Draft for cross-team sign-off.

## Contract A — Gateway (what the app's ai-gateway library codes against)

### Discovery: SSM Parameter Store paths (all SecureString, KMS-encrypted)

| Value | SSM path | Who reads |
|---|---|---|
| Gateway base URL | *(not a secret)* — `https://litellm.ai-platform.internal` | app (config) |
| Feature virtual key | `/ecs/ai-platform/<env>/litellm/key/<feature>` | app (as Bearer) |

`<feature>` is one of: `app-summarization`, `app-transcribe`,
`app-extraction`, `app-ops` (extend via `var.feature_keys`). The app's
task role must be granted `ssm:GetParameter` + `kms:Decrypt` on these paths — the
app owns that grant.

The gateway URL resolves via the private hosted zone `ai-platform.internal`, which
is associated with the app's VPC (Swarm today, Enterprise-App-Fargate later). Nothing
else about the platform is exposed to the app — no Bedrock model id, no IAM role,
no VPC endpoint name.

### Request shape (OpenAI-compatible)

```
POST https://litellm.ai-platform.internal/v1/chat/completions
Authorization: Bearer <feature virtual key from SSM>
Content-Type: application/json

{
  "model": "case-note-summary",        // an ALIAS only; never a Bedrock model id
  "max_tokens": 2048,
  "temperature": 0,
  "messages": [ ... ],
  "metadata": {
    "team_id": "<tenantId>",           // SERVER-DERIVED from the JWT — never client input
    "feature": "case-note-summary",
    "request_id": "<uuid = UserContext.requestId>",
    "session_id": "<aiCaseNoteSessionId>",
    "prompt_id": "case-note-summary",
    "prompt_version": 3,
    "user_ref": "<opaque id — never an email or name>"
  }
}
```

**Model aliases the app may use** (only these resolve; anything else is rejected):

| Alias | Purpose |
|---|---|
| `case-note-summary` | case note summarization |
| `case-note-transcribe` | Claude transcription engine |
| `structured-extraction` | case-transcribe / invoice-transcribe |
| `ops-analysis` | Splunk log analysis (separate budget) |

Underlying model ids are platform config (currently Sonnet 4.5 / Fable 5.1 —
subject to the eval corpus); the app never sees or names them.

### Non-negotiable

`metadata.team_id` MUST be derived server-side from `UserContext.tenantId` (the
validated JWT), never read from a client header/body. A client-controllable tenant
id here is cross-tenant attribution forgery.

### Timeouts (nested — the app must honor its layer)

Bedrock client 45s < LiteLLM 60s < application 75s < browser 90s.

### Responses / errors the app maps to typed AI_* errors

| Gateway signal | App error |
|---|---|
| 200 + valid completion | success (app then schema-validates + sanitizes) |
| 429 | `AI_THROTTLED` |
| timeout / 504 | `AI_TIMEOUT` |
| 5xx / connection refused | `AI_UNAVAILABLE` |
| budget exceeded (configurable) | `AI_QUOTA_EXCEEDED` |
| unknown alias / rejected model | treat as `AI_UNAVAILABLE` (config error — page platform) |

The app NEVER fabricates a success on failure (SDD SI-11). Content logging is off
at the gateway; the app must not log request/response bodies either (Contract-wide
content policy — see the NIST doc and App-Integration-Epic).

## Contract B — Artifact storage / retention (platform storage <-> app+retention)

The platform owns the S3 buckets/prefixes, KMS, and the S3 lifecycle backstops.
The app writes the `AiArtifact` metadata record and the objects; the retention
worker reads/updates the record and deletes objects.

### Storage the platform provides

- Per-tenant buckets + `sts:AssumeRole` (reuses the existing tenant isolation —
  app-owned data roles, not created by ai-platform).
- Prefixes: `ai/staging/<tenantId>/<sessionId>/...` and
  `ai/retained/<tenantId>/<caseNoteId>/<artifactId>/...`.
- SSE-KMS with the per-tenant CMK, set explicitly on upload.
- S3 lifecycle **backstops** (platform-owned): staging expire 24h; retained
  `expiresAt + 7d`. **Their firing is an alarm condition, not a success** — the
  application always wins the deletion race under normal operation.

### The `AiArtifact` record (the app<->retention contract — from design §19)

Keys carry no participant identifier. `sessionId`/`artifactId` are v4 UUIDs. The
retention worker branches on nothing case-note-specific; it sees expiring objects.
Fields: `artifactId, tenantId, ownerType, ownerId, artifactClass, bucket, key,
bytes, contentType, retentionPolicy(none|temporary|caseRecord), policyVersion,
expiresAt, status(active|expired|deleteFailed), deletedAt, deletedReason,
deleteAttempts, createdAt, updatedAt`. State machine + rules per design §19 —
retention never hard-deletes the record; verifies every delete with a HeadObject
404; idempotent.

The full schema + state machine live on the canonical design page (§19); this
contract just fixes the ownership boundary: **platform = buckets/KMS/lifecycle;
app = record write + object write + immediate `none` deletion; retention worker =
expiry/delete/verify/audit + reconciliation.**

## Change control

Both contracts are versioned here. A breaking change (new required metadata field,
a renamed SSM path, an alias removal) is a coordinated change across Enterprise-AI-Platform and
App-Integration-Epic with a version bump and both teams' sign-off — not a silent edit.
