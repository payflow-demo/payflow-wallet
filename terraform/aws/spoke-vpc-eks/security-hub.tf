# AWS Security Hub - Centralized Security Findings
# Aggregates findings from GuardDuty, Config, Inspector, etc.

resource "aws_securityhub_account" "payflow" {
  enable_default_standards = true  # Enables default standards; explicit subscriptions below can conflict if already enabled
}

# Optional: explicit standards subscriptions (disable if enable_default_standards already enabled or you get InvalidInputException)
variable "enable_security_hub_standards_subscriptions" {
  description = "Set true to create explicit CIS/Foundational standards subscriptions. Leave false if enable_default_standards on the account is enough."
  type        = bool
  default     = false
}

resource "aws_securityhub_standards_subscription" "cis" {
  count = var.enable_security_hub_standards_subscriptions ? 1 : 0

  standards_arn = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [aws_securityhub_account.payflow]
}

resource "aws_securityhub_standards_subscription" "aws_foundational" {
  count = var.enable_security_hub_standards_subscriptions ? 1 : 0

  standards_arn = "arn:aws:securityhub:::ruleset/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.payflow]
}

# Security Hub Findings SNS Topic
resource "aws_sns_topic" "security_hub_findings" {
  name              = "payflow-security-hub-findings"
  kms_master_key_id = aws_kms_key.security_findings.id

  tags = {
    Name        = "payflow-security-hub-findings"
    Environment = var.environment
  }
}

# EventBridge Rule for Security Hub Findings
resource "aws_cloudwatch_event_rule" "security_hub_findings" {
  name        = "payflow-security-hub-findings-rule"
  description = "Capture Security Hub findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
  })

  tags = {
    Name = "payflow-security-hub-findings-rule"
  }
}

resource "aws_cloudwatch_event_target" "security_hub_findings" {
  rule      = aws_cloudwatch_event_rule.security_hub_findings.name
  target_id = "SecurityHubFindingsTarget"
  arn       = aws_sns_topic.security_hub_findings.arn
}

# SNS Topic Policy
resource "aws_sns_topic_policy" "security_hub_findings" {
  arn = aws_sns_topic.security_hub_findings.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.security_hub_findings.arn
      }
    ]
  })
}

