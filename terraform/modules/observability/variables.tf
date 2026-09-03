variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }

variable "alb_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "ecs_cluster_name" { type = string }
variable "ecs_service_name" { type = string }
variable "log_group_name" { type = string }

variable "kms_key_arn" {
  type        = string
  description = "CMK encrypting SNS topics."
}

variable "critical_alert_emails" {
  type        = list(string)
  description = "Recipients paged for critical alarms (on-call rotation address)."
  default     = []
}

variable "warning_alert_emails" {
  type        = list(string)
  description = "Recipients ticketed for warning alarms (team channel address)."
  default     = []
}

variable "error_5xx_threshold" {
  type        = number
  description = "5xx responses per minute that trigger the critical alarm."
  default     = 5
}

variable "latency_p99_threshold_seconds" {
  type    = number
  default = 1.5
}

variable "error_log_threshold" {
  type        = number
  description = "ERROR log lines per 5 minutes before warning."
  default     = 10
}
