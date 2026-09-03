variable "project" { type = string }
variable "environment" { type = string }

variable "account_id" {
  type        = string
  description = "AWS account id, used for globally-unique bucket naming."
}

variable "vpc_id" { type = string }

variable "vpc_cidr" {
  type        = string
  description = "Used to scope ALB egress to inside the VPC."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for ALB placement (>= 2 AZs)."

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB requires subnets in at least two availability zones."
  }
}

variable "container_port" {
  type        = number
  description = "Port the application listens on."
  default     = 8000
}

variable "health_check_path" {
  type        = string
  description = "Target group health check path."
  default     = "/health"
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the HTTPS listener."
}

variable "access_log_retention_days" {
  type        = number
  description = "Days to retain ALB access logs in S3."
  default     = 90
}
