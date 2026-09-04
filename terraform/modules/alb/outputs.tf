output "alb_arn" { value = aws_lb.main.arn }
output "alb_arn_suffix" {
  description = "Needed for CloudWatch metric dimensions."
  value       = aws_lb.main.arn_suffix
}
output "alb_dns_name" {
  description = "Public DNS name - point your Route 53 alias here."
  value       = aws_lb.main.dns_name
}
output "alb_zone_id" { value = aws_lb.main.zone_id }

output "target_group_arn" { value = aws_lb_target_group.app.arn }
output "target_group_arn_suffix" {
  description = "Needed for CloudWatch metric dimensions."
  value       = aws_lb_target_group.app.arn_suffix
}

output "alb_security_group_id" { value = aws_security_group.alb.id }
output "task_security_group_id" {
  description = "Attach this to the ECS service - ingress from the ALB only."
  value       = aws_security_group.tasks.id
}

output "access_log_bucket" { value = aws_s3_bucket.logs.id }
