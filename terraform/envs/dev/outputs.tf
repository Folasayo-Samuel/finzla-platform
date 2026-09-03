output "alb_dns_name" {
  description = "Public entry point. Health check: https://<this>/health"
  value       = module.alb.alb_dns_name
}

output "ecr_repository_url" {
  description = "docker push target."
  value       = module.ecr.repository_url
}

output "ecs_cluster_name" { value = module.ecs_service.cluster_name }
output "ecs_service_name" { value = module.ecs_service.service_name }
output "task_definition_family" { value = module.ecs_service.task_definition_family }
output "log_group_name" { value = module.ecs_service.log_group_name }

output "gha_plan_role_arn" {
  description = "GitHub repo variable AWS_PLAN_ROLE_ARN."
  value       = module.github_oidc.plan_role_arn
}

output "gha_deploy_role_arn" {
  description = "GitHub environment variable AWS_DEPLOY_ROLE_ARN."
  value       = module.github_oidc.deploy_role_arn
}

output "gha_apply_role_arn" {
  description = "GitHub environment variable AWS_APPLY_ROLE_ARN."
  value       = module.github_oidc.apply_role_arn
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.observability.dashboard_name}"
}

output "nat_egress_ips" {
  description = "Give these to any third party that allowlists by IP."
  value       = module.network.nat_public_ips
}
