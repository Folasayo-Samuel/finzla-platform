###############################################################################
# Observability module
#
# Metrics chosen so that between them they answer "is the service broken,
# and is it our fault?":
#
#   1. HTTP 5xx rate (target-generated)  — the app is returning errors
#   2. Target response time p99          — the app is slow before it errors
#   3. Unhealthy target count            — capacity is being removed
#   4. CPU / memory utilisation          — resource saturation
#   5. Running task count                — desired vs actual divergence
#
# Alerts are deliberately few. Two paging alerts and a handful of ticketing
# ones. An alert nobody acts on trains people to ignore the channel.
###############################################################################

locals {
  name = "${var.project}-${var.environment}"
}

# --- Notification topics ---------------------------------------------------
# Two topics, because severity should route differently: critical pages
# on-call, warning opens a ticket.
resource "aws_sns_topic" "critical" {
  name              = "${local.name}-alerts-critical"
  kms_master_key_id = var.kms_key_arn
  tags              = { Name = "${local.name}-alerts-critical", Severity = "critical" }
}

resource "aws_sns_topic" "warning" {
  name              = "${local.name}-alerts-warning"
  kms_master_key_id = var.kms_key_arn
  tags              = { Name = "${local.name}-alerts-warning", Severity = "warning" }
}

resource "aws_sns_topic_subscription" "critical_email" {
  for_each = toset(var.critical_alert_emails)

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "warning_email" {
  for_each = toset(var.warning_alert_emails)

  topic_arn = aws_sns_topic.warning.arn
  protocol  = "email"
  endpoint  = each.value
}

###############################################################################
# ALERT 1 (CRITICAL) — elevated 5xx rate from the application
#
# trigger    >= 5 target-generated 5xx responses per minute, 2 consecutive
#            minutes. Uses HTTPCode_Target_5XX (the app), not
#            HTTPCode_ELB_5XX (the load balancer) — different causes.
# why        Every one of these is a customer seeing a failure. This is the
#            closest available proxy for "we are breaking promises".
# who        On-call platform engineer, paged.
# first step Open the ECS log group, filter ERROR in the last 15 minutes,
#            and check whether errors correlate with a deployment event.
###############################################################################
resource "aws_cloudwatch_metric_alarm" "app_5xx" {
  alarm_name        = "${local.name}-app-5xx-rate"
  alarm_description = <<-EOT
    Application is returning 5xx responses to customers.
    Runbook: docs/incident-response.md#elevated-5xx
    First step: check ECS task logs for stack traces, and correlate the
    onset time against the most recent deployment.
  EOT

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"
  period      = 60

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.error_5xx_threshold
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  # Absent data means zero requests, not zero errors. Treating it as
  # notBreaching stops a quiet night from paging someone.
  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]

  tags = { Severity = "critical" }
}

###############################################################################
# ALERT 2 (CRITICAL) — no healthy targets behind the load balancer
#
# trigger    HealthyHostCount < 1 for 2 consecutive minutes.
# why        This is a hard outage: the ALB has nowhere to send traffic and
#            every request becomes a 503. It is the exact condition in the
#            troubleshooting scenario.
# who        On-call platform engineer, paged immediately.
# first step `aws ecs describe-services` — compare runningCount to
#            desiredCount, then read stoppedReason on the most recent
#            stopped tasks.
###############################################################################
resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  alarm_name        = "${local.name}-no-healthy-targets"
  alarm_description = <<-EOT
    Fewer than one healthy target behind the ALB — customer-facing outage.
    Runbook: docs/incident-response.md#unhealthy-targets
    First step: aws ecs describe-services --cluster ${var.ecs_cluster_name}
    --services ${var.ecs_service_name} and read the events array.
  EOT

  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  statistic   = "Minimum"
  period      = 60

  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  # Missing data here is genuinely bad — it can mean the target group has
  # no registered targets at all.
  treat_missing_data = "breaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]

  tags = { Severity = "critical" }
}

###############################################################################
# WARNING alerts — ticket, do not page
###############################################################################

# Latency degradation usually precedes errors. p99 rather than average,
# because an average hides the tail that customers actually notice.
resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name        = "${local.name}-latency-p99"
  alarm_description = <<-EOT
    p99 response time above ${var.latency_p99_threshold_seconds}s.
    Often the early warning for an outage that has not happened yet.
    First step: check CPU/memory saturation and any downstream dependency.
  EOT

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p99"
  period             = 300

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p99_threshold_seconds
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  tags          = { Severity = "warning" }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name        = "${local.name}-cpu-high"
  alarm_description = "Service CPU above 80% for 10 minutes — check whether autoscaling is keeping up."

  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  tags          = { Severity = "warning" }
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name        = "${local.name}-memory-high"
  alarm_description = "Service memory above 80% for 10 minutes — possible leak, or task_memory set too low."

  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.warning.arn]
  tags          = { Severity = "warning" }
}

# --- Log-derived error metric ---------------------------------------------
# The ALB tells you a request failed; only the logs tell you why. This
# metric filter turns ERROR lines into a graphable, alarmable series.
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${local.name}-app-error-count"
  log_group_name = var.log_group_name
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = "ApplicationErrorCount"
    namespace     = "Finzla/${var.environment}"
    value         = "1"
    default_value = 0
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_error_spike" {
  alarm_name        = "${local.name}-app-error-spike"
  alarm_description = "Application ERROR log volume spiked — inspect the log group for stack traces."

  namespace           = "Finzla/${var.environment}"
  metric_name         = "ApplicationErrorCount"
  statistic           = "Sum"
  period              = 300
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_log_threshold
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.warning.arn]
  tags          = { Severity = "warning" }
}

# --- Dashboard -------------------------------------------------------------
# One screen an on-call engineer can open during an incident without
# assembling queries by hand.
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-service"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Request rate and 5xx"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "requests" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { stat = "Sum", label = "target 5xx", color = "#d62728" }],
            [".", "HTTPCode_ELB_5XX_Count", ".", ".", { stat = "Sum", label = "ELB 5xx", color = "#ff7f0e" }],
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Response time"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Target health"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Minimum", label = "healthy" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { stat = "Maximum", label = "unhealthy", color = "#d62728" }],
          ]
          period = 60
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Task resource utilisation and count"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { stat = "Average", label = "cpu %" }],
            [".", "MemoryUtilization", ".", ".", ".", ".", { stat = "Average", label = "memory %" }],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { stat = "Average", label = "running tasks" }],
          ]
          period = 60
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Recent application errors"
          region = var.aws_region
          query  = "SOURCE '${var.log_group_name}' | fields @timestamp, level, msg | filter level = 'ERROR' | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}
