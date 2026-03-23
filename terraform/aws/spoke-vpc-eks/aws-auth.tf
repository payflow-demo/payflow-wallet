# EKS Access: allow node IAM role to join cluster.
# Cluster must have access_config.authentication_mode = "API_AND_CONFIG_MAP".
# If you get ResourceInUseException (409): the entry already exists (e.g. EKS created it). Import it:
#   terraform import aws_eks_access_entry.node_role <cluster-name>:<principal-arn>
#   e.g. terraform import aws_eks_access_entry.node_role payflow-eks-cluster:arn:aws:iam::ACCOUNT_ID:role/payflow-eks-node-role
resource "aws_eks_access_entry" "node_role" {
  cluster_name  = aws_eks_cluster.payflow.name
  principal_arn = aws_iam_role.eks_node.arn
  type          = "EC2_LINUX"
}

# aws-auth ConfigMap is applied by bootstrap-node user_data (runs inside VPC). No kubernetes provider.
data "aws_caller_identity" "current" {}

