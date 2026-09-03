###############################################################################
# Remote state bootstrap
#
# Chicken-and-egg: the S3 bucket that holds Terraform state cannot itself be
# stored in that bucket. This stack therefore uses LOCAL state, is applied
# once by hand, and is then left alone. Commit its state file to a private
# location or re-import if lost — it creates only two long-lived resources.
#
#   cd terraform/bootstrap
#   terraform init && terraform apply
#
# Then every other stack uses the S3 backend it produced.
###############################################################################

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.63"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

# --- KMS key encrypting state at rest -------------------------------------
# State contains resource metadata and can contain sensitive values, so it
# gets a customer-managed key rather than SSE-S3. A CMK gives us an audit
# trail in CloudTrail and the ability to revoke access independently of the
# bucket policy.
resource "aws_kms_key" "tfstate" {
  description             = "${var.project} terraform state encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

# --- State bucket ----------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # State is the source of truth for the whole platform. Losing it is worse
  # than almost any other failure here, so deletion protection stays on.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_caller_identity" "current" {}

# Versioning is what makes state recoverable after a bad apply or a
# corrupted write. Non-negotiable.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.tfstate.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Reject any unencrypted-in-transit request. Without this, a misconfigured
# client could send state over plain HTTP.
resource "aws_s3_bucket_policy" "tfstate_tls_only" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json
}

data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Expire old state versions so the bucket does not grow without bound,
# but keep enough history to recover from a bad apply.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- State locking ---------------------------------------------------------
# Terraform 1.11 made S3-native state locking generally available and
# DEPRECATED the DynamoDB arguments. Locking now uses a conditional-write
# lock file (`<key>.tflock`) in this same bucket, enabled per-backend with
# `use_lockfile = true`.
#
# So there is deliberately no DynamoDB table here: one fewer resource, one
# fewer IAM surface, and no second service to pay for. The bucket policy
# and versioning above already protect the lock object.
#
# The bucket needs no extra configuration for this — S3 conditional writes
# are a bucket-level capability, not something to switch on.
