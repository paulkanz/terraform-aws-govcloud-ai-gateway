# ai-platform :: observability — SNS, VPC flow logs, alarms (AU-6 / SI-4 / AC-4)
# Closes the largest posture gap: detective controls. AU-6 at Moderate requires
# review AND response, so every alarm routes to an SNS topic a named responder
# subscribes to (subscription is operational, not coded here) and carries a
# runbook reference in its description.

# --- SNS alert topic ---------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = aws_kms_key.platform.id
  tags              = { Name = "${local.name}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_email_subscribers)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- VPC Flow Logs (AC-4 / SI-4 boundary monitoring) -------------------------
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/vpc/${local.name}/flow"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
  tags              = { Name = "${local.name}-flow-logs" }
}

resource "aws_iam_role" "flow" {
  name = "${local.name}-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
  tags = { Name = "${local.name}-flow-logs" }
}

resource "aws_iam_policy" "flow" {
  name        = "${local.name}-flow-logs"
  description = "VPC flow logs delivery to CloudWatch"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "flow" {
  role       = aws_iam_role.flow.name
  policy_arn = aws_iam_policy.flow.arn
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow.arn
  iam_role_arn             = aws_iam_role.flow.arn
  max_aggregation_interval = 60
  tags                     = { Name = "${local.name}-flow" }
}

# --- Alarms (the designed AU-6/SI-4 set, scoped to what this tree can measure) -
# Runbook base — each alarm names its runbook so a page is actionable, not noise.
locals {
  runbook = var.runbook_base_url
}

# LiteLLM error rate (5xx from the gateway target group at the ALB).
resource "aws_cloudwatch_metric_alarm" "gateway_5xx" {
  alarm_name          = "${local.name}-litellm-5xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.alarm_gateway_5xx_threshold
  alarm_description   = "LiteLLM 5xx elevated. Check LiteLLM/Bedrock health; consider per-tenant disable. Runbook: ${local.runbook}/litellm-errors"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  dimensions = {
    TargetGroup  = aws_lb_target_group.litellm.arn_suffix
    LoadBalancer = aws_lb.litellm.arn_suffix
  }
  tags = { Name = "${local.name}-litellm-5xx-high" }
}

resource "aws_cloudwatch_metric_alarm" "gateway_unhealthy" {
  alarm_name          = "${local.name}-litellm-unhealthy-targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "LiteLLM has unhealthy targets (gateway down or Swarm->ECS path). Runbook: ${local.runbook}/litellm-health"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "breaching"
  dimensions = {
    TargetGroup  = aws_lb_target_group.litellm.arn_suffix
    LoadBalancer = aws_lb.litellm.arn_suffix
  }
  tags = { Name = "${local.name}-litellm-unhealthy-targets" }
}

resource "aws_cloudwatch_metric_alarm" "gateway_latency" {
  alarm_name          = "${local.name}-litellm-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  extended_statistic  = "p95"
  threshold           = var.alarm_gateway_latency_p95_seconds
  alarm_description   = "LiteLLM p95 latency high (approaching the 60s gateway budget). Runbook: ${local.runbook}/litellm-latency"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  dimensions = {
    TargetGroup  = aws_lb_target_group.litellm.arn_suffix
    LoadBalancer = aws_lb.litellm.arn_suffix
  }
  tags = { Name = "${local.name}-litellm-latency-high" }
}

# Bedrock throttling — sustained 429 from the model.
resource "aws_cloudwatch_metric_alarm" "bedrock_throttle" {
  alarm_name          = "${local.name}-bedrock-throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "InvocationThrottles"
  namespace           = "AWS/Bedrock"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Bedrock throttling. Verify quota headroom; confirm fallback alias engaged. Runbook: ${local.runbook}/bedrock-throttle"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  tags                = { Name = "${local.name}-bedrock-throttled" }
}

# RDS (LiteLLM control-plane DB) — a store failure fails the gateway.
resource "aws_cloudwatch_metric_alarm" "litellm_db_cpu" {
  alarm_name          = "${local.name}-litellm-db-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "LiteLLM Aurora CPU high. Runbook: ${local.runbook}/litellm-db"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  dimensions          = { DBClusterIdentifier = module.litellm_db.cluster_id }
  tags                = { Name = "${local.name}-litellm-db-cpu-high" }
}

# ElastiCache ECPU — tuned high for a rate-limit-counter workload (lesson from
# the tooling BullMQ false-alarm: threshold reflects the real workload profile).
resource "aws_cloudwatch_metric_alarm" "litellm_cache_ecpu" {
  alarm_name          = "${local.name}-litellm-cache-ecpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ElastiCacheProcessingUnits"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_cache_ecpu_threshold
  alarm_description   = "LiteLLM cache ECPU sustained-high (3x5min). Runbook: ${local.runbook}/litellm-cache"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
  dimensions          = { clusterId = module.litellm_cache.cache_name }
  tags                = { Name = "${local.name}-litellm-cache-ecpu-high" }
}

# --- Dashboard ---------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "LiteLLM ALB — requests / 5xx / p95"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.litellm.arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "TargetResponseTime", ".", ".", { stat = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Bedrock invocations / throttles / latency"
          region  = var.aws_region
          metrics = [["AWS/Bedrock", "Invocations"], [".", "InvocationThrottles"], [".", "InvocationLatency"]]
        }
      },
    ]
  })
}
