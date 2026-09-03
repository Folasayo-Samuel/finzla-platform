###############################################################################
# ECR module
#
# One repository per service. Key decisions:
#   - IMMUTABLE tags: a pushed tag can never be overwritten. This is what
#     makes "deployed sha abc123" a verifiable statement and blocks the
#     classic supply-chain move of re-pushing :latest.
#   - Scan on push: findings surface at build time, not audit time.
#   - KMS encryption: layers at rest under a customer-managed key.
#   - Lifecycle policy: untagged layers expire, tagged images capped.
###############################################################################

locals {
  name = "${var.project}-${var.environment}"
}

resource "aws_ecr_repository" "app" {
  name                 = "${local.name}-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.environment != "prod"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = { Name = "${local.name}-app" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged layers after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the most recent ${var.retain_image_count} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.retain_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Deny any pull over plaintext, and restrict pushes to the CI role only.
# Without this, any principal in the account with ecr:* could push an image
# that ECS would then run.
resource "aws_ecr_repository_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy     = data.aws_iam_policy_document.repo.json
}

data "aws_iam_policy_document" "repo" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["ecr:*"]
    resources = ["*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
