variable "project" {
  type        = string
  description = "Project slug."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "kms_key_arn" {
  type        = string
  description = "CMK encrypting image layers at rest."
}

variable "retain_image_count" {
  type        = number
  description = "How many tagged images to keep before expiring the oldest."
  default     = 20
}
