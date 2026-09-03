output "state_bucket" {
  description = "Value for `bucket` in each environment's backend block."
  value       = aws_s3_bucket.tfstate.id
}

output "kms_key_arn" {
  description = "Value for `kms_key_id` in each environment's backend block."
  value       = aws_kms_key.tfstate.arn
}
