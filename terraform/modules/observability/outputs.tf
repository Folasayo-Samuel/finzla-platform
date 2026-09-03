output "critical_topic_arn" { value = aws_sns_topic.critical.arn }
output "warning_topic_arn" { value = aws_sns_topic.warning.arn }
output "dashboard_name" { value = aws_cloudwatch_dashboard.main.dashboard_name }

output "alarm_names" {
  description = "All alarm names, for wiring into a deployment gate or status page."
  value = [
    aws_cloudwatch_metric_alarm.app_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.no_healthy_targets.alarm_name,
    aws_cloudwatch_metric_alarm.latency_p99.alarm_name,
    aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.memory_high.alarm_name,
    aws_cloudwatch_metric_alarm.app_error_spike.alarm_name,
  ]
}
