variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "finzla"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type        = string
  description = "Non-overlapping with prod, so the two can be peered later."
  default     = "10.20.0.0/16"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "certificate_arn" {
  type        = string
  description = <<-EOT
    ACM certificate for the HTTPS listener. Must already exist and be
    validated in this region. Create it out of band (or in a separate DNS
    stack) so certificate validation does not block application applies.
  EOT
}

variable "image_uri" {
  type        = string
  description = "Set by CI. Empty on first apply, which uses a bootstrap tag."
  default     = ""
}

variable "github_org" { type = string }
variable "github_repo" { type = string }

variable "state_bucket" {
  type        = string
  description = "From terraform/bootstrap output `state_bucket`."
}

variable "state_kms_key_arn" {
  type        = string
  description = "From terraform/bootstrap output `kms_key_arn`."
}

variable "warning_alert_emails" {
  type        = list(string)
  description = "Team channel address for non-paging alerts."
  default     = []
}

variable "critical_alert_emails" {
  type        = list(string)
  description = "On-call rotation address. Paged for customer-facing alarms."
  default     = []
}
