output "hub_vpc_id" {
  description = "Hub VPC ID"
  value       = aws_vpc.hub.id
}

output "hub_public_subnet_id" {
  description = "Hub public subnet ID (for Bastion)"
  value       = aws_subnet.hub_public.id
}

output "hub_private_subnet_id" {
  description = "Hub private subnet ID"
  value       = aws_subnet.hub_private.id
}

output "transit_gateway_id" {
  description = "Transit Gateway ID"
  value       = aws_ec2_transit_gateway.hub.id
}

output "hub_private_route_table_id" {
  description = "Hub private route table ID (for Spoke route hub_to_eks)"
  value       = aws_route_table.hub_private.id
}

