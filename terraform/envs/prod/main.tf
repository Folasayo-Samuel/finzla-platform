###############################################################################
# PROD environment
#
# Environment separation strategy: separate root module per environment,
# each with its own state file key. Not Terraform workspaces — workspaces
# share one backend and one set of credentials, so a mistake in a dev apply
# can reach prod state. Separate directories also let dev and prod diverge
# intentionally (1 NAT vs 2, Spot vs on-demand) without conditionals
# scattered through the modules.
#
# Ideally dev and prod live in separate AWS ACCOUNTS. This layout supports
# that with no code change: point the provider at a different account and
# the state key stays distinct.
###############################################################################

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.63"
    }
  }

  # Values come from terraform/bootstrap outputs. Filled via -backend-config
  # in CI so the bucket name is not hard-coded per environment.
  backend "s3" {
    key     = "prod/terraform.tfstate"
    encrypt = true
    # S3-native locking (GA in Terraform 1.11). Writes a conditional-write
    # lock object alongside state. Replaces the deprecated DynamoDB table.
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "${var.github_org}/${var.github_repo}"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# --- Shared encryption key -------------------------------------------------
resource "aws_kms_key" "main" {
  description             = "${var.project}-${var.environment} logs, secrets, images"
  deletion_window_in_days = 30 # full window in prod — key deletion is irreversible
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}-${var.environment}"
  target_key_id = aws_kms_key.main.key_id
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid    = "AccountRoot"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # CloudWatch Logs must be able to use the key or log group creation fails
  # with an opaque error.
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:*"]
    }
  }
}

# --- Modules ---------------------------------------------------------------
module "network" {
  source = "../../modules/network"

  project          = var.project
  environment      = var.environment
  aws_region       = var.aws_region
  vpc_cidr         = var.vpc_cidr
  logs_kms_key_arn = aws_kms_key.main.arn

  # Two NAT gateways so loss of one AZ does not sever egress for the other.
  # Roughly $64/month; the availability is worth it in prod.
  nat_gateway_count       = 2
  enable_vpc_endpoints    = true
  flow_log_retention_days = 90
}

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment
  kms_key_arn = aws_kms_key.main.arn

  retain_image_count = 30
}

module "alb" {
  source = "../../modules/alb"

  project           = var.project
  environment       = var.environment
  account_id        = local.account_id
  vpc_id            = module.network.vpc_id
  vpc_cidr          = module.network.vpc_cidr
  public_subnet_ids = module.network.public_subnet_ids
  certificate_arn   = var.certificate_arn
  container_port    = var.container_port

  access_log_retention_days = 365
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = local.account_id

  # Placeholder on first apply. The pipeline replaces this with the real
  # digest-pinned image; `ignore_changes` on the service keeps Terraform
  # from reverting it.
  image_uri = var.image_uri != "" ? var.image_uri : "${module.ecr.repository_url}:bootstrap"

  container_port          = var.container_port
  private_subnet_ids      = module.network.private_subnet_ids
  task_security_group_id  = module.alb.task_security_group_id
  target_group_arn        = module.alb.target_group_arn
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecr_repository_arn      = module.ecr.repository_arn
  kms_key_arn             = aws_kms_key.main.arn

  # Prod sizing: min 2 tasks so a single task or AZ failure is survivable.
  # No Spot for the baseline — Spot reclamation during an incident is a
  # failure mode we do not want to debug under pressure.
  task_cpu            = "512"
  task_memory         = "1024"
  cpu_architecture    = "ARM64"
  desired_count       = 2
  enable_autoscaling  = true
  autoscaling_min     = 2
  autoscaling_max     = 10
  fargate_base_count  = 2
  fargate_spot_weight = 0
  log_retention_days  = 90

  # OFF in prod. An interactive shell into a task holding customer data is
  # an unacceptable standing capability; enable temporarily and audibly if
  # an incident genuinely requires it.
  enable_execute_command = false

  environment_variables = {
    APP_ENV   = var.environment
    LOG_LEVEL = "INFO"
  }
}

module "observability" {
  source = "../../modules/observability"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  ecs_cluster_name        = module.ecs_service.cluster_name
  ecs_service_name        = module.ecs_service.service_name
  log_group_name          = module.ecs_service.log_group_name
  kms_key_arn             = aws_kms_key.main.arn

  # Tight thresholds — this is the environment customers touch.
  critical_alert_emails         = var.critical_alert_emails
  warning_alert_emails          = var.warning_alert_emails
  error_5xx_threshold           = 5
  latency_p99_threshold_seconds = 1.5
}

module "github_oidc" {
  source = "../../modules/github_oidc"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  account_id  = local.account_id

  github_org  = var.github_org
  github_repo = var.github_repo

  # The provider is account-wide and already created by the dev stack.
  # Two resources managing it would fight on every apply.
  create_oidc_provider = false

  state_bucket      = var.state_bucket
  state_kms_key_arn = var.state_kms_key_arn

  ecr_repository_arn      = module.ecr.repository_arn
  ecs_cluster_name        = module.ecs_service.cluster_name
  ecs_service_name        = module.ecs_service.service_name
  task_execution_role_arn = module.ecs_service.execution_role_arn
  task_role_arn           = module.ecs_service.task_role_arn
}
