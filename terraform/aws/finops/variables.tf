variable "aws_region" {
  description = "AWS region for billing and Cost Explorer resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "cost_center" {
  description = "Cost center code for all resources (e.g. ENG-001)"
  type        = string
}

variable "team" {
  description = "Owning engineering team for all resources"
  type        = string
}

variable "owner" {
  description = "Primary owner (person or team) for all resources"
  type        = string
}

variable "budget_alert_email" {
  description = "Email address for AWS budget and anomaly alerts"
  type        = string
}

variable "monthly_budget_dev" {
  description = "Monthly AWS budget for dev environment (USD)"
  type        = number
  default     = 200
}

variable "monthly_budget_prod" {
  description = "Monthly AWS budget for prod environment (USD)"
  type        = number
  default     = 1000
}

variable "budget_alert_threshold_percent" {
  description = "Percentage of monthly budget at which to trigger alerts"
  type        = number
  default     = 80
}

variable "aws_account_id" {
  description = "AWS account ID for Cost Explorer/Anomaly resources"
  type        = string
}

variable "billing_alarm_threshold_usd" {
  description = "Account-level EstimatedCharges (USD) at which the CloudWatch billing alarm triggers. Typically set to prod budget or total expected monthly spend."
  type        = number
  default     = 1000
}

variable "enable_cost_allocation_tags" {
  description = "Activate Cost Explorer cost allocation tags. Set to true only after tag keys (project, environment, etc.) exist on resources and appear in Cost Explorer; otherwise AWS returns 'Tag keys not found'."
  type        = bool
  default     = false
}

variable "enable_anomaly_detection" {
  description = "Create Cost Anomaly Detection monitor and subscription. Set to false if account has reached the AWS limit (e.g. 'Limit exceeded on dimensional spend monitor creation')."
  type        = bool
  default     = false
}

