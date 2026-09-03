###############################################################################
# ALB module
#
# The only internet-facing component. Terminates TLS, then forwards to task
# ENIs in private subnets over the VPC's internal network.
#
# Security group design is the crux of the "container not exposed" control:
#   ALB SG   ingress 443 from 0.0.0.0/0
#   Task SG  ingress 8000 from ALB SG ONLY (source is the SG id, not a CIDR)
# Because the task rule references the ALB's security group rather than an
# IP range, there is no way to reach the container except through the ALB —
# even from inside the VPC.
###############################################################################

locals {
  name = "${var.project}-${var.environment}"
}

# --- Security groups -------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public HTTPS ingress to the load balancer"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Port 80 is accepted only to issue a 301 to HTTPS. No application traffic
# is ever served over it.
resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Egress restricted to the task port within the VPC — not the default
# allow-all. An ALB has no business initiating traffic anywhere else.
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id = aws_security_group.alb.id
  description       = "To application tasks"
  cidr_ipv4         = var.vpc_cidr
  from_port         = var.container_port
  to_port           = var.container_port
  ip_protocol       = "tcp"
}

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Application tasks — ingress only from the ALB"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-tasks-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# THE control that satisfies "must not be directly exposed to the internet".
resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "App port from the ALB security group only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# Tasks need outbound 443 to pull images, ship logs, and read secrets.
# Everything else is denied.
resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS egress for ECR, CloudWatch Logs, Secrets Manager"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- Access log bucket -----------------------------------------------------
# ALB access logs are the only place you can see client IP, response code
# and target processing time per request. Essential for the 503 exercise.
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name}-alb-logs-${var.account_id}"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB log delivery does not support KMS CMKs — SSE-S3 is the only option.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid    = "AllowALBLogDelivery"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/${local.name}/AWSLogs/${var.account_id}/*"]
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# --- Load balancer ---------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod"
  drop_invalid_header_fields = true
  idle_timeout               = 60

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = local.name
    enabled = true
  }

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # required for Fargate awsvpc networking

  # Deregistration delay: how long the ALB keeps draining a task after it is
  # removed. Too long and deploys crawl; too short and in-flight requests
  # are cut off. 30s suits a service with sub-second responses.
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Prevents a gap where the old group is destroyed before the new one is
  # attached to the listener.
  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name}-tg" }
}

# --- Listeners -------------------------------------------------------------
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS 1.2 minimum. The -TLS13- policy also enables 1.3 where the client
  # supports it. Never use the older ELBSecurityPolicy-2016-08 default,
  # which permits TLS 1.0.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
