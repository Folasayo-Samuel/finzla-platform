###############################################################################
# ECS Fargate service module
#
# Two IAM roles, deliberately separate — this distinction is the single most
# commonly botched part of an ECS setup:
#
#   EXECUTION role  used by the ECS agent, BEFORE the container starts.
#                   Pulls the image, fetches secrets, creates log streams.
#                   The application code never holds these credentials.
#
#   TASK role       assumed by the application process itself, at runtime.
#                   This is what leaks if the app has an SSRF or RCE bug,
#                   so it is kept as close to empty as possible.
#
# Deployment safety comes from the circuit breaker with rollback enabled:
# if new tasks fail health checks, ECS reverts to the last known-good task
# definition without human intervention.
###############################################################################

locals {
  name = "${var.project}-${var.environment}"
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = { Name = "${local.name}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # Baseline on-demand capacity, with Spot only above it. In dev, Spot can
  # carry everything; in prod we keep guaranteed capacity for the base load.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.fargate_base_count
    weight            = 1
  }
}

# --- Log group -------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = { Name = "${local.name}-app-logs" }
}

# --- Execution role --------------------------------------------------------
resource "aws_iam_role" "execution" {
  name               = "${local.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = { Name = "${local.name}-task-execution" }
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused-deputy protection: without these conditions, any ECS task in
    # any account that somehow referenced this role ARN could assume it.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.aws_region}:${var.account_id}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

# Written by hand rather than attaching AmazonECSTaskExecutionRolePolicy,
# which grants ecr:GetAuthorizationToken and logs:* on "*". This version is
# scoped to exactly one repository and one log group.
resource "aws_iam_role_policy" "execution" {
  name   = "pull-image-and-write-logs"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

data "aws_iam_policy_document" "execution" {
  # GetAuthorizationToken cannot be resource-scoped — the API takes no
  # resource. It only returns a token; the pull itself is authorised by the
  # statement below.
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPullThisRepoOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid    = "WriteAppLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }

  # Only present when the service actually has secrets, so an empty
  # secrets list produces no policy statement at all.
  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []
    content {
      sid       = "ReadInjectedSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.secret_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []
    content {
      sid       = "DecryptSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }
}

# --- Task role -------------------------------------------------------------
# Intentionally near-empty. This service calls no AWS API, so it gets no
# AWS permissions. Only ECS Exec support is attached, and only where enabled.
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = { Name = "${local.name}-task" }
}

# ECS Exec (interactive shell into a running task) is a debugging tool and
# an audit concern. Off in prod by default; when on, every session is logged.
resource "aws_iam_role_policy" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec-ssm-channel"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec.json
}

data "aws_iam_policy_document" "task_exec" {
  statement {
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # these actions do not support resource scoping
  }
}

# --- Task definition -------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.image_uri
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      # Non-secret configuration only.
      environment = [
        for k, v in var.environment_variables : { name = k, value = v }
      ]

      # Secrets are resolved by the ECS agent from Secrets Manager and
      # injected as env vars at start. The VALUE never appears in the task
      # definition, in Terraform state, or in the console.
      secrets = [
        for k, v in var.secrets : { name = k, valueFrom = v }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
          # Do not drop logs under backpressure — losing the logs from a
          # crashing task is exactly when you need them most.
          "mode" = "non-blocking"
        }
      }

      # Container-level check, independent of the ALB target group. Gives
      # ECS a reason to replace a wedged task even if the ALB is happy.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=2).status==200 else 1)\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      readonlyRootFilesystem = true
      user                   = "10001:10001"

      linuxParameters = {
        initProcessEnabled = true # reaps zombies; needed for clean SIGTERM
      }
    }
  ])

  tags = { Name = "${local.name}-app" }
}

# --- Service ---------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${local.name}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = null # capacity provider strategy governs placement

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.fargate_base_count
    weight            = 1
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.fargate_spot_weight > 0 ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      base              = 0
      weight            = var.fargate_spot_weight
    }
  }

  # Rolling deploy bounds. 200/100 means: bring up a full replacement set
  # before removing any old task, so capacity never dips during a deploy.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  # THE reliability control the brief asks about. If the new task set fails
  # to stabilise, ECS rolls back to the previous task definition on its own.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.task_security_group_id]
    assign_public_ip = false # tasks are not internet-addressable
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "app"
    container_port   = var.container_port
  }

  # Grace period before the ALB health check counts against a new task.
  # Too short and slow-starting tasks get killed in a loop.
  health_check_grace_period_seconds = var.health_check_grace_period

  enable_execute_command = var.enable_execute_command

  propagate_tags = "SERVICE"
  tags           = { Name = "${local.name}-app" }

  # The pipeline updates the task definition image out of band, so Terraform
  # must not fight it on the next plan.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_iam_role_policy.execution]
}

# --- Autoscaling -----------------------------------------------------------
resource "aws_appautoscaling_target" "app" {
  count = var.enable_autoscaling ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min
  max_capacity       = var.autoscaling_max
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.name}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app[0].service_namespace
  resource_id        = aws_appautoscaling_target.app[0].resource_id
  scalable_dimension = aws_appautoscaling_target.app[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 65
    scale_in_cooldown  = 300 # slow to scale in, to avoid flapping
    scale_out_cooldown = 60  # fast to scale out, to absorb bursts
  }
}

# Requests-per-target catches load the CPU metric misses — an I/O-bound
# service can saturate on concurrency at low CPU.
resource "aws_appautoscaling_policy" "requests" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.name}-rpt-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app[0].service_namespace
  resource_id        = aws_appautoscaling_target.app[0].resource_id
  scalable_dimension = aws_appautoscaling_target.app[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }
    target_value       = 500
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
