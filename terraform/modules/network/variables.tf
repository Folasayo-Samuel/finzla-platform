variable "project" {
  description = "Project slug."
  type        = string
}

variable "environment" {
  description = "Environment name (dev | prod)."
  type        = string
}

variable "aws_region" {
  description = "Region, needed to build VPC endpoint service names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. Must be a /16 so the /24 subnet maths works."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid CIDR of /16 or larger."
  }
}

variable "nat_gateway_count" {
  description = <<-EOT
    Number of NAT gateways. 1 is cheaper but a single point of failure;
    2 gives per-AZ egress. Use 1 in dev, 2 in prod.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.nat_gateway_count >= 1 && var.nat_gateway_count <= 2
    error_message = "nat_gateway_count must be 1 or 2 (this module creates 2 AZs)."
  }
}

variable "enable_vpc_endpoints" {
  description = "Create interface endpoints for ECR/Logs/Secrets and the S3 gateway endpoint."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs."
  type        = number
  default     = 30
}

variable "logs_kms_key_arn" {
  description = "CMK used to encrypt the flow log group."
  type        = string
}
