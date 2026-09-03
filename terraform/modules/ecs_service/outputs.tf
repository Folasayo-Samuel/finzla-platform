output "cluster_name" { value = aws_ecs_cluster.main.name }
output "cluster_arn" { value = aws_ecs_cluster.main.arn }
output "service_name" { value = aws_ecs_service.app.name }

output "task_definition_family" {
  description = "Family name the pipeline registers new revisions against."
  value       = aws_ecs_task_definition.app.family
}

output "task_definition_arn" { value = aws_ecs_task_definition.app.arn }

output "log_group_name" {
  description = "Where application logs land."
  value       = aws_cloudwatch_log_group.app.name
}

output "execution_role_arn" { value = aws_iam_role.execution.arn }
output "task_role_arn" { value = aws_iam_role.task.arn }
