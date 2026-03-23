output "bootstrap_instance_id" {
  description = "Bootstrap instance ID. If Ingress stays Pending, bootstrap may have failed: check /var/log/bootstrap.log via SSM, terminate this instance, then terraform apply again. See docs/BOOTSTRAP-TROUBLESHOOTING.md"
  value       = module.bootstrap_node.instance_id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.payflow.name
}

output "eks_cluster_id" {
  description = "EKS Cluster ID"
  value       = aws_eks_cluster.payflow.id
}

output "eks_cluster_arn" {
  description = "EKS Cluster ARN"
  value       = aws_eks_cluster.payflow.arn
}

output "eks_cluster_endpoint" {
  description = "EKS Cluster API endpoint"
  value       = aws_eks_cluster.payflow.endpoint
}

output "eks_cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_eks_cluster.payflow.vpc_config[0].cluster_security_group_id
}

output "eks_node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes (pod traffic egresses with this SG)"
  value       = aws_security_group.eks_nodes.id
}

output "eks_oidc_provider_arn" {
  description = "ARN of the EKS OIDC Provider"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "eks_node_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = aws_iam_role.eks_node.arn
}

# ECR Repository Outputs
output "ecr_repository_urls" {
  description = "ECR repository URLs for all services"
  value = {
    api_gateway        = aws_ecr_repository.api_gateway.repository_url
    auth_service       = aws_ecr_repository.auth_service.repository_url
    wallet_service     = aws_ecr_repository.wallet_service.repository_url
    transaction_service = aws_ecr_repository.transaction_service.repository_url
    notification_service = aws_ecr_repository.notification_service.repository_url
    frontend           = aws_ecr_repository.frontend.repository_url
  }
}

output "ecr_repository_arns" {
  description = "ECR repository ARNs for all services"
  value = {
    api_gateway        = aws_ecr_repository.api_gateway.arn
    auth_service       = aws_ecr_repository.auth_service.arn
    wallet_service     = aws_ecr_repository.wallet_service.arn
    transaction_service = aws_ecr_repository.transaction_service.arn
    notification_service = aws_ecr_repository.notification_service.arn
    frontend           = aws_ecr_repository.frontend.arn
  }
}

# Secrets Manager Outputs
output "secrets_manager_arns" {
  description = "Secrets Manager ARNs"
  value = {
    rds      = aws_secretsmanager_secret.rds.arn
    rabbitmq = aws_secretsmanager_secret.rabbitmq.arn
    redis    = aws_secretsmanager_secret.redis.arn
    app      = aws_secretsmanager_secret.app_secrets.arn
  }
  sensitive = true
}

# WAF Outputs
output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.payflow.arn
}

# Route53 Outputs
output "route53_zone_id" {
  description = "Route53 Hosted Zone ID"
  value       = var.domain_name != "" ? aws_route53_zone.payflow[0].zone_id : null
}

output "acm_certificate_arn" {
  description = "ACM Certificate ARN"
  value       = var.domain_name != "" ? aws_acm_certificate_validation.payflow[0].certificate_arn : null
}

# GuardDuty Outputs (prod only)
output "guardduty_detector_id" {
  description = "GuardDuty Detector ID (null in dev)"
  value       = local.env == "prod" ? aws_guardduty_detector.payflow[0].id : null
}

# ALB Controller IRSA Role (for Ingress → ALB)
output "alb_controller_irsa_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (install with Helm if missing)"
  value       = aws_iam_role.alb_controller_irsa.arn
}

# External Secrets IRSA Role
output "external_secrets_irsa_arn" {
  description = "External Secrets IRSA Role ARN"
  value       = aws_iam_role.external_secrets_irsa.arn
}

# Cluster Autoscaler IRSA Role
output "cluster_autoscaler_irsa_arn" {
  description = "Cluster Autoscaler IRSA Role ARN"
  value       = aws_iam_role.cluster_autoscaler_irsa.arn
}

