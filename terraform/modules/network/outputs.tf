output "vpc_id" {
  description = "VPC identifier."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnets - ALB placement only."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets - ECS task placement."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "AZs actually used."
  value       = local.azs
}

output "nat_public_ips" {
  description = "NAT egress addresses - give these to any third party that IP-allowlists."
  value       = aws_eip.nat[*].public_ip
}
