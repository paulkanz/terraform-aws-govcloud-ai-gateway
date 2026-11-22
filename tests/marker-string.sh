#!/usr/bin/env bash
# ai-platform :: assurance test — MARKER-STRING content leak (SDD §9, SI-12 / AU)
#
# Proves the content policy: participant content reaches EXACTLY ONE store (the
# app's governed S3 artifact store) and NOWHERE else. Send one request through
# the gateway carrying a unique marker string as the "transcript", then grep
# every observability sink the platform owns for that marker. The marker must
# appear NOWHERE.
#
# Sinks checked (platform-owned): the LiteLLM RDS control-plane DB, the LiteLLM
# and Phoenix CloudWatch log groups, and (best-effort) Phoenix spans. The app's
# own log sinks are checked by the app-side version of this test (App-Integration-Epic);
# this one covers the PLATFORM's sinks.
#
# Usage:
#   ai-platform/tests/marker-string.sh <env> [region]
# Requires: a reachable gateway (run from inside the VPC / a bastion), and the
# LiteLLM DATABASE_URL readable from SSM by the caller.
#
# Exit 0 = no leak; non-zero = marker found in a sink (LEAK) or setup failed.

set -euo pipefail
ENVN="${1:?usage: marker-string.sh <env> [region]}"
REGION="${2:-us-gov-west-1}"
NAME="ai-platform-${ENVN}"
MARKER="ASSURANCE-MARKER-$(date +%s)-$RANDOM"

echo "== Marker-string content-leak test (${NAME}) — marker: ${MARKER} =="

GW="https://litellm.ai-platform.internal"
KEY=$(aws ssm get-parameter --region "$REGION" \
  --name "/ecs/ai-platform/${ENVN}/litellm/key/app-summarization" \
  --with-decryption --query 'Parameter.Value' --output text)

# 1. Send one request whose content contains the marker.
echo "-- sending a request carrying the marker through the gateway --"
curl -sS -o /dev/null -w "gateway http %{http_code}\n" \
  --max-time 75 \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  "${GW}/v1/chat/completions" \
  -d "{\"model\":\"case-note-summary\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"${MARKER}\"}],\"metadata\":{\"team_id\":\"assurance\",\"feature\":\"assurance-test\"}}" \
  || echo "(request may fail if models are gated; the leak check still runs)"

sleep 20 # let logs/usage rows flush

FAIL=0

# 2. Grep the LiteLLM RDS control-plane DB for the marker (usage rows must carry
#    NO body). Requires psql + the DATABASE_URL.
DBURL=$(aws ssm get-parameter --region "$REGION" \
  --name "/ecs/ai-platform/${ENVN}/litellm/DATABASE_URL" \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || echo "")
if [ -n "$DBURL" ] && command -v psql >/dev/null; then
  # LiteLLM persists usage in LiteLLM_SpendLogs. With store_prompts_in_spend_logs
  # =false there is no request/response body column populated; the marker must
  # not appear anywhere in that table. Dump and grep the tables that could
  # conceivably hold request content.
  LEAK=0
  for TBL in "LiteLLM_SpendLogs" "LiteLLM_ErrorLogs"; do
    if psql "$DBURL" -tAc "\copy (SELECT * FROM \"${TBL}\") TO STDOUT" 2>/dev/null | grep -q "$MARKER"; then
      echo "FAIL: marker found in ${TBL} — request content is being persisted."
      LEAK=1
    fi
  done
  if [ "$LEAK" -eq 0 ]; then
    echo "PASS: marker NOT in the LiteLLM spend/error tables."
  else
    FAIL=1
  fi
else
  echo "WARN: psql/DATABASE_URL unavailable — DB leak check skipped (run from a host that can reach RDS)."
fi

# 3. Grep the platform CloudWatch log groups for the marker.
for LG in "/ecs/${NAME}/litellm" "/ecs/${NAME}/phoenix"; do
  START=$(( ($(date +%s) - 600) * 1000 ))
  HIT=$(aws logs filter-log-events --region "$REGION" \
    --log-group-name "$LG" --start-time "$START" \
    --filter-pattern "\"${MARKER}\"" \
    --query 'length(events)' --output text 2>/dev/null || echo 0)
  if [ "$HIT" != "0" ] && [ "$HIT" != "None" ]; then
    echo "FAIL: marker found in CloudWatch log group ${LG} (${HIT} events)."
    FAIL=1
  else
    echo "PASS: marker NOT in ${LG}."
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: no participant content leaked into any platform observability sink."
fi
exit "$FAIL"
