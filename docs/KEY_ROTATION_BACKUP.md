# ai-platform Key Rotation and Backup/Restore (Enterprise-AI-Platform)

**Date:** 2026-09-16
**Author:** Paul Kanz
**Controls:** IA-5 (Authenticator Management), CP-9/CP-10 (Backup/Recovery),
SC-12 (Key Management). Addresses AD-10 / central GitOps pipeline finding H-7 — a static shared
secret must have a key id and a documented rotation path from day one.
**Account / Region:** 123456789012 / `us-gov-west-1`.

## What secrets/keys exist

| Secret | Where | Rotation model |
|---|---|---|
| LiteLLM feature virtual keys | SSM `/ecs/ai-platform/<env>/litellm/key/<feature>` (SecureString) | Manual, documented below (Phase 1). Phase 2: replace with SigV4/mTLS (identity-based, no static secret). |
| LiteLLM master key | SSM `.../litellm/MASTER_KEY` | Rotated with a gateway restart. |
| LiteLLM salt key | SSM `.../litellm/SALT_KEY` | **Do NOT rotate casually** — the salt encrypts stored keys; changing it invalidates existing virtual keys. Rotate only with a full key re-issue. |
| RDS master (litellm, phoenix) | Secrets Manager (RDS-managed) | AWS-managed rotation; the DATABASE_URL SSM param is derived. |
| Platform KMS CMK | `alias/ai-platform-<env>-platform` | `enable_key_rotation = true` (annual automatic). |

## Feature virtual key rotation (Phase 1)

Rotation must not drop requests: LiteLLM supports multiple valid keys during a
window.

1. **Generate + register the new key** alongside the old one (both valid):
   - Update `random_password.feature_key[<feature>]` is not the path (it would
     also change on every apply). Instead, mint a new key via the LiteLLM admin
     API (bootstrap job) OR bump a `keepers` on the random resource to force a new
     value, apply, which writes the new value to the SSM param.
2. **Roll the consumer:** the app reads the key from SSM at task start; restart /
   redeploy the app tasks so they pick up the new key. Both old and new are valid
   during this window.
3. **Revoke the old key** in LiteLLM (admin API / DB) once no caller uses it.
4. **Audit:** record the rotation (who, when, which feature) — the key id, never
   the value.

Trigger rotation on: suspected compromise, an operator offboarding who had access,
or on the scheduled cadence (recommend quarterly until Phase 2 SigV4 lands).

## Master key rotation

1. Bump the `MASTER_KEY` SSM param value; restart the LiteLLM service.
2. The master key authenticates admin operations; rotating it does not invalidate
   feature keys (those are salted separately).

## RDS master credential

AWS-managed via `manage_master_user_password`. To force rotation:
`aws secretsmanager rotate-secret --secret-id <the cluster's managed secret>`.
After rotation, re-apply so the derived `DATABASE_URL` SSM param picks up the new
password (the param is assembled from the managed secret at apply).

## CP-9 / CP-10 — Backup and restore

**Backups (automatic):**
- LiteLLM Aurora: `backup_retention_period = 14`.
- Phoenix Aurora: `backup_retention_period = 7`.
- SSM parameters + KMS keys: covered by account-level backup/versioning; the
  config is reproducible from IaC (`terraform apply` rewrites config.yaml + the
  derived URL params).

**Restore — LiteLLM control-plane DB (the operationally load-bearing store):**
1. Restore to a new cluster from the latest automated snapshot:
   `aws rds restore-db-cluster-to-point-in-time` (or from-snapshot).
2. Repoint `DATABASE_URL` in SSM to the restored endpoint (or re-apply after
   updating the cluster identifier).
3. Restart the LiteLLM service; verify `/health/readiness` and that virtual keys
   resolve (the DB holds them).
4. If the salt key was lost, virtual keys cannot be decrypted — re-issue all
   feature keys (see rotation) and roll consumers. This is why the salt key is a
   protected secret.

**Restore — Phoenix DB:** lower stakes (metadata-only, not user-facing). Restore
or rebuild; Phoenix loss never affects the gateway or the app.

**Reproducibility test:** the whole platform is IaC — a `terraform apply` into a
clean account (with the CONFIRM inputs supplied) reconstructs everything except
the RDS *data* (keys/usage), which is what the backups cover. Validate the restore
path in a lower environment before relying on it (an untested restore is not a
restore).

## Phase 2 (removes this whole class of secret)

Replace the static feature virtual key with SigV4 or mTLS between the app and the
gateway, so authentication is identity-based. The network egress lock is the
primary control throughout; the key only identifies the caller. When Phase 2
lands, the feature-key rotation section becomes moot and this runbook shrinks to
the RDS/KMS items.
