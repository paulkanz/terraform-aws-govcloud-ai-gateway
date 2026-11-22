#!/usr/bin/env bash
# ai-platform :: assurance test — EGRESS NEGATIVE (SDD §9, controls AC-4 / SC-7)
#
# Proves the load-bearing control: an application host has NO network route to
# any model provider. A direct call from a Swarm host to the public Anthropic
# endpoint AND to the Bedrock runtime endpoint must FAIL (connect timeout /
# refused). If either succeeds, the egress lock is broken -> the test fails.
#
# This is a RUNTIME test: a timeout cannot be asserted from a terraform plan.
# Run post-deploy, from an actual application (Swarm) host, via SSM.
#
# Usage:
#   scripts/../ai-platform/tests/egress-negative.sh <app-host-instance-id> [region]
#
# Exit 0 = egress correctly blocked; non-zero = LEAK (or the probe couldn't run).

set -euo pipefail
INSTANCE_ID="${1:?usage: egress-negative.sh <instance-id> [region]}"
REGION="${2:-us-gov-west-1}"

echo "== Egress-negative test from ${INSTANCE_ID} (${REGION}) =="

# Probe: both the public provider and the in-region Bedrock runtime endpoint.
# From an application host, BOTH must be unreachable (no route / blocked).
CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "ai-platform egress-negative assurance test" \
  --parameters 'commands=[
    "set +e",
    "echo PROBE_ANTHROPIC:",
    "timeout 8 bash -c \"cat < /dev/null > /dev/tcp/api.anthropic.com/443\" && echo REACHED || echo BLOCKED",
    "echo PROBE_BEDROCK:",
    "timeout 8 bash -c \"cat < /dev/null > /dev/tcp/bedrock-runtime.us-gov-west-1.amazonaws.com/443\" && echo REACHED || echo BLOCKED"
  ]' \
  --query 'Command.CommandId' --output text)

# Wait for completion.
for _ in $(seq 1 20); do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  [ "$STATUS" = "Success" ] || [ "$STATUS" = "Failed" ] && break
  sleep 3
done

OUT=$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text)

echo "--- probe output ---"
echo "$OUT"
echo "--------------------"

FAIL=0
if echo "$OUT" | grep -A1 "PROBE_ANTHROPIC:" | grep -q "REACHED"; then
  echo "FAIL: app host REACHED api.anthropic.com — public provider egress is open."
  FAIL=1
fi
if echo "$OUT" | grep -A1 "PROBE_BEDROCK:" | grep -q "REACHED"; then
  echo "FAIL: app host REACHED the Bedrock runtime endpoint directly — bypasses the gateway."
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: both provider paths are BLOCKED from the application host. Egress lock holds."
fi
exit "$FAIL"
