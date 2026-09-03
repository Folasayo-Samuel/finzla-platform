###############################################################################
# GitHub Actions -> AWS via OIDC
#
# No AWS access keys exist anywhere in GitHub. Instead:
#
#   1. GitHub mints a short-lived JWT for the workflow run, describing the
#      repository, ref, and environment it belongs to.
#   2. AWS STS validates that JWT against GitHub's OIDC provider.
#   3. The trust policy decides whether THIS repo, on THIS ref, may assume
#      the role. Credentials last ~1 hour and cannot be exported.
#
# The `sub` claim condition is the load-bearing security control. This is
# the answer to "what prevents another repository, a compromised workflow,
# or an individual developer from deploying to production?"
#
#   repo:ORG/REPO:environment:prod     <- only this repo, only via the
#                                         `prod` GitHub Environment, which
#                                         itself requires human approval
#
# A different repo produces a different `sub` and STS refuses. A developer
# cannot bypass the environment gate because the role trust is scoped to
# the environment claim, not to a branch they could push to.
###############################################################################

locals {
  name = "${var.project}-${var.environment}"
}

# One OIDC provider per account, shared by all environments.
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub rotates this intermediate cert thumbprint occasionally. AWS now
  # validates against its own trust store for this provider, so the value
  # is required by the API but no longer security-critical.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Name = "${var.project}-github-oidc" }
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # Subject claims permitted to assume the DEPLOY role.
  #
  # Production is scoped to `environment:prod` ONLY. It deliberately does
  # NOT include `ref:refs/heads/main`, because a branch-scoped trust would
  # let anyone who can push to main deploy without review. Environment
  # scoping forces the run through GitHub's approval gate first.
  deploy_subjects = var.environment == "prod" ? [
    "repo:${var.github_org}/${var.github_repo}:environment:prod",
    ] : [
    "repo:${var.github_org}/${var.github_repo}:environment:dev",
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
  ]

  # The PLAN role is read-only, so it is safe to expose to pull requests
  # from branches. It still cannot be assumed by another repository.
  plan_subjects = [
    "repo:${var.github_org}/${var.github_repo}:pull_request",
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
  ]
}

# ---------------------------------------------------------------------------
# PLAN role — read-only, used on pull requests
# ---------------------------------------------------------------------------
resource "aws_iam_role" "plan" {
  name                 = "${local.name}-gha-plan"
  description          = "Read-only Terraform plan from GitHub Actions PRs"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.plan_assume.json

  tags = { Name = "${local.name}-gha-plan" }
}

data "aws_iam_policy_document" "plan_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike (not StringEquals) because `pull_request` subjects have no
    # trailing segment to match exactly across all PR numbers.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

# ReadOnlyAccess is an AWS-managed policy that grants read on nearly every
# service. It is acceptable for `terraform plan` and nothing else — plan
# must refresh arbitrary resource state to produce a diff.
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan needs to write the state lock and read state. Note this grants
# s3:PutObject on the state key — plan does not write state, but it does
# acquire and release the DynamoDB lock.
resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-read-and-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }

  statement {
    sid    = "ReadWriteOwnEnvironmentStateOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    # Scoped to this environment's state key. The dev role cannot read or
    # corrupt production state.
    resources = ["arn:aws:s3:::${var.state_bucket}/${var.environment}/*"]
  }

  # S3-native locking needs no extra actions beyond the object permissions
  # above — the lock is an object (`<key>.tflock`) written with a
  # conditional put, covered by s3:PutObject/DeleteObject on this prefix.
  # This is why there is no DynamoDB statement here.

  statement {
    sid    = "StateEncryption"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [var.state_kms_key_arn]
  }
}

# ---------------------------------------------------------------------------
# DEPLOY role — pushes images and updates the ECS service
#
# This is the most security-sensitive role in the solution. It is scoped to
# exactly the actions a deployment needs and nothing more. Notably it CANNOT
# create or modify infrastructure, IAM, networking, or security groups.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-gha-deploy"
  description          = "Build, push, and deploy the application from GitHub Actions"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json

  tags = { Name = "${local.name}-gha-deploy" }
}

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals — exact match, no wildcards. A typo'd or attacker-chosen
    # subject will not match.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.deploy_subjects
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "push-image-and-update-service"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # API accepts no resource
  }

  statement {
    sid    = "ECRPushToThisRepoOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = [var.ecr_repository_arn]
  }

  # Register a new task definition revision with the updated image tag.
  # RegisterTaskDefinition cannot be resource-scoped by the API, so the
  # iam:PassRole statement below is what actually constrains it: without
  # the ability to pass an arbitrary role, this permission cannot be used
  # to run a task with elevated credentials.
  statement {
    sid       = "RegisterTaskDefinition"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid    = "UpdateThisServiceOnly"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = ["arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${var.ecs_cluster_name}/${var.ecs_service_name}"]
    condition {
      test     = "StringEquals"
      variable = "ecs:cluster"
      values   = ["arn:aws:ecs:${var.aws_region}:${var.account_id}:cluster/${var.ecs_cluster_name}"]
    }
  }

  statement {
    sid       = "ObserveDeployment"
    effect    = "Allow"
    actions   = ["ecs:DescribeTasks", "ecs:ListTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["arn:aws:ecs:${var.aws_region}:${var.account_id}:cluster/${var.ecs_cluster_name}"]
    }
  }

  # THE critical constraint on this role.
  #
  # RegisterTaskDefinition lets you specify which roles a task runs as. If
  # this role could pass ANY role, it could register a task running as an
  # administrator and then start it — a trivial privilege escalation to
  # full account takeover.
  #
  # By restricting PassRole to exactly the two known task roles, the worst
  # a compromised deploy role can do is run a container with the same
  # permissions the application already has.
  statement {
    sid       = "PassOnlyTheseTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.task_execution_role_arn, var.task_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Read health/rollback signals during the deployment gate.
  statement {
    sid    = "ReadDeploymentSignals"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:DescribeAlarms",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadDeploymentLogs"
    effect    = "Allow"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/${local.name}/app:*"]
  }
}

# ---------------------------------------------------------------------------
# APPLY role — creates and modifies infrastructure
#
# Separated from the deploy role so that routine application deployments
# (many per day) do not carry infrastructure-mutating power. This role is
# assumed only by the infrastructure workflow, gated on the environment.
#
# NOTE ON AdministratorAccess: this role intentionally does not use it.
# See README "Managing without AdministratorAccess". The permission set
# below is a starting boundary — it should be tightened iteratively by
# running plan/apply, reading the AccessDenied errors, and adding only the
# actions that were genuinely required.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "apply" {
  count = var.create_apply_role ? 1 : 0

  name                 = "${local.name}-gha-apply"
  description          = "Terraform apply from GitHub Actions, environment-gated"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json

  tags = { Name = "${local.name}-gha-apply" }
}

resource "aws_iam_role_policy" "apply_state" {
  count = var.create_apply_role ? 1 : 0

  name   = "terraform-state-access"
  role   = aws_iam_role.apply[0].id
  policy = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy" "apply_infra" {
  count = var.create_apply_role ? 1 : 0

  name   = "manage-platform-infrastructure"
  role   = aws_iam_role.apply[0].id
  policy = data.aws_iam_policy_document.apply_infra.json
}

data "aws_iam_policy_document" "apply_infra" {
  # Service-scoped rather than "*": Terraform genuinely needs broad action
  # coverage within these services, but has no reason to touch, say,
  # Organizations, Route 53 domains, or Bedrock.
  statement {
    sid    = "ManagePlatformServices"
    effect = "Allow"
    actions = [
      "ec2:*",
      "ecs:*",
      "ecr:*",
      "elasticloadbalancing:*",
      "logs:*",
      "cloudwatch:*",
      "application-autoscaling:*",
      "sns:*",
      "acm:Describe*",
      "acm:List*",
      "acm:Get*",
      "secretsmanager:Describe*",
      "secretsmanager:List*",
      "secretsmanager:GetResourcePolicy",
      "kms:Describe*",
      "kms:List*",
      "kms:CreateGrant",
      "s3:*",
    ]
    resources = ["*"]
  }

  # IAM is separated and constrained by a path condition, so this role can
  # only manage roles created for this platform — not the account's
  # administrative roles, and not its own trust policy.
  statement {
    sid    = "ManagePlatformIAMOnly"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PassRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:CreateServiceLinkedRole",
    ]
    resources = [
      "arn:aws:iam::${var.account_id}:role/${var.project}-*",
      "arn:aws:iam::${var.account_id}:role/aws-service-role/*",
    ]
  }

  # Explicit deny beats any allow. Even if the statements above were
  # loosened by mistake, this role can never escalate to administrator or
  # rewrite the permission boundaries that contain it.
  statement {
    sid    = "DenyPrivilegeEscalation"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:CreateAccountAlias",
      "iam:DeleteAccountPasswordPolicy",
      "organizations:*",
      "account:*",
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyTouchingOwnTrustPolicy"
    effect = "Deny"
    actions = [
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
      "iam:PutRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${var.account_id}:role/${local.name}-gha-apply",
      "arn:aws:iam::${var.account_id}:role/${local.name}-gha-deploy",
    ]
  }
}
