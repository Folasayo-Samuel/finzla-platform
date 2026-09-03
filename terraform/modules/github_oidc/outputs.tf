output "plan_role_arn" {
  description = "Set as AWS_PLAN_ROLE_ARN in GitHub repo variables."
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "Set as AWS_DEPLOY_ROLE_ARN in the GitHub environment."
  value       = aws_iam_role.deploy.arn
}

output "apply_role_arn" {
  description = "Set as AWS_APPLY_ROLE_ARN in the GitHub environment."
  value       = var.create_apply_role ? aws_iam_role.apply[0].arn : null
}

output "oidc_provider_arn" {
  description = "Account-level GitHub OIDC provider."
  value       = local.oidc_provider_arn
}
