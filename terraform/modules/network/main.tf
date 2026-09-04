###############################################################################
# Network module
#
# Three-tier layout across two AZs:
#   public  — ALB only. Has a route to the internet gateway.
#   private — ECS tasks. No inbound route from the internet. Egress via NAT.
#
# Two AZs is the minimum for ALB (it requires subnets in >= 2 AZs) and gives
# us survival of a single-AZ failure.
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project}-${var.environment}"

  # Take the first two AZs deterministically so a change in AWS's ordering
  # does not shuffle subnets between applies.
  azs = slice(sort(data.aws_availability_zones.available.names), 0, 2)

  # /24 per subnet out of a /16 — 251 usable addresses each, ample for
  # Fargate task ENIs while leaving room to add tiers later.
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name}-vpc" }
}

# --- Public tier -----------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_subnets[count.index]
  availability_zone = local.azs[count.index]

  # The ALB needs a public IP; nothing else is placed here.
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private tier ----------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  # Explicitly false — this is the control that keeps tasks off the public
  # internet, as required by the brief.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# NAT gateway count is a variable, not a constant, because it is the single
# biggest lever on both cost and resilience in this design:
#   dev  -> 1 NAT  (~$32/mo, single point of failure, acceptable)
#   prod -> 2 NAT  (~$64/mo, survives an AZ loss)
resource "aws_eip" "nat" {
  count  = var.nat_gateway_count
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip-${count.index}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = var.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name}-nat-${count.index}" }

  depends_on = [aws_internet_gateway.main]
}

# One route table per private subnet so each AZ can egress through its own
# NAT when we run two. With a single NAT they all point at the same one.
resource "aws_route_table" "private" {
  count = length(local.azs)

  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private-rt-${count.index}" }
}

resource "aws_route" "private_nat" {
  count = length(local.azs)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  # min() keeps this valid when nat_gateway_count (1) is less than the
  # subnet count (2): both private subnets then share NAT 0.
  nat_gateway_id = aws_nat_gateway.main[min(count.index, var.nat_gateway_count - 1)].id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- VPC flow logs ---------------------------------------------------------
# Required for any credible incident investigation: without flow logs you
# cannot answer "did this task talk to that address" after the fact.
resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  tags = { Name = "${local.name}-flow-logs" }
}

resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/vpc/${local.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    # Scoped to this log group only, not logs:* on all groups.
    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

# --- Interface endpoints ---------------------------------------------------
# ECR, CloudWatch Logs and Secrets Manager traffic would otherwise leave the
# VPC through NAT and be billed per GB. Endpoints keep it on the AWS network:
# cheaper at image-pull volume, and it removes a NAT dependency from the
# task startup path.
resource "aws_security_group" "endpoints" {
  name        = "${local.name}-vpce"
  description = "HTTPS from private subnets to VPC interface endpoints"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-vpce-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = length(local.azs)

  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from ${local.private_subnets[count.index]}"
  cidr_ipv4         = local.private_subnets[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

locals {
  interface_endpoints = var.enable_vpc_endpoints ? {
    ecr_api        = "com.amazonaws.${var.aws_region}.ecr.api"
    ecr_dkr        = "com.amazonaws.${var.aws_region}.ecr.dkr"
    logs           = "com.amazonaws.${var.aws_region}.logs"
    secretsmanager = "com.amazonaws.${var.aws_region}.secretsmanager"
    ssm            = "com.amazonaws.${var.aws_region}.ssm"
  } : {}
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-vpce-${each.key}" }
}

# S3 is a gateway endpoint (free) — ECR stores layers in S3, so image pulls
# need it alongside the ECR endpoints.
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${local.name}-vpce-s3" }
}
