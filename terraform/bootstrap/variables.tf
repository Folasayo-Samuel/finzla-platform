variable "aws_region" {
  description = "Region hosting the state bucket and lock table."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Project slug used to name shared resources."
  type        = string
  default     = "finzla"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-21 chars."
  }
}
