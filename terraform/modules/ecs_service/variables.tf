variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }

variable "image_uri" {
  type        = string
  description = "Fully qualified image reference, digest-pinned where possible."
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "task_cpu" {
  type        = string
  description = "Fargate CPU units (256 = 0.25 vCPU)."
  default     = "256"
}

variable "task_memory" {
  type        = string
  description = "Fargate memory in MiB. Must be a valid pair with task_cpu."
  default     = "512"
}

variable "cpu_architecture" {
  type        = string
  description = "X86_64 or ARM64. ARM64 (Graviton) is ~20% cheaper per vCPU."
  default     = "ARM64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "desired_count" {
  type        = number
  description = "Baseline task count. Keep >= 2 in prod for AZ redundancy."
  default     = 2
}

variable "private_subnet_ids" { type = list(string) }
variable "task_security_group_id" { type = string }
variable "target_group_arn" { type = string }
variable "alb_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "ecr_repository_arn" { type = string }

variable "kms_key_arn" {
  type        = string
  description = "CMK for log encryption and secret decryption."
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "environment_variables" {
  type        = map(string)
  description = "Non-sensitive configuration injected as env vars."
  default     = {}
}

variable "secrets" {
  type        = map(string)
  description = <<-EOT
    Map of ENV_VAR_NAME => Secrets Manager ARN. Values are resolved by the
    ECS agent at task start; they never enter Terraform state.
  EOT
  default     = {}
}

variable "secret_arns" {
  type        = list(string)
  description = "ARNs the execution role may read. Should match values in `secrets`."
  default     = []
}

variable "health_check_grace_period" {
  type        = number
  description = "Seconds before ALB health checks count against a new task."
  default     = 60
}

variable "enable_container_insights" {
  type    = bool
  default = true
}

variable "enable_execute_command" {
  type        = bool
  description = "Allow interactive shell into tasks. Keep false in prod."
  default     = false
}

variable "enable_autoscaling" {
  type    = bool
  default = true
}

variable "autoscaling_min" {
  type    = number
  default = 2
}

variable "autoscaling_max" {
  type    = number
  default = 6
}

variable "fargate_base_count" {
  type        = number
  description = "Guaranteed on-demand tasks before Spot is used."
  default     = 1
}

variable "fargate_spot_weight" {
  type        = number
  description = "Spot weight above the on-demand base. 0 disables Spot."
  default     = 0
}
