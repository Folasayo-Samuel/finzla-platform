output "repository_url" {
  description = "Registry URL used by docker push / the task definition."
  value       = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  description = "ARN - used to scope the CI push policy and the task execution pull policy."
  value       = aws_ecr_repository.app.arn
}

output "repository_name" {
  description = "Repository name."
  value       = aws_ecr_repository.app.name
}
