variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }

variable "github_org" {
  type        = string
  description = "GitHub organisation or user that owns the repository."
}

variable "github_repo" {
  type        = string
  description = "Repository name. Combined with github_org to scope the OIDC sub claim."
}

variable "create_oidc_provider" {
  type        = bool
  description = <<-EOT
    Create the account-level OIDC provider. Only ONE environment should set
    this to true, since the provider is a single account-wide resource.
    Set true in dev (applied first), false in prod.
  EOT
  default     = false
}

variable "create_apply_role" {
  type        = bool
  description = "Create the infrastructure-mutating Terraform apply role."
  default     = true
}

variable "state_bucket" { type = string }
variable "state_kms_key_arn" { type = string }

variable "ecr_repository_arn" { type = string }
variable "ecs_cluster_name" { type = string }
variable "ecs_service_name" { type = string }
variable "task_execution_role_arn" { type = string }
variable "task_role_arn" { type = string }
