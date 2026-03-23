# PayFlow FinOps Report Module

This `terraform/finops` module is a **report-only** module that has no resources of its own. It reads remote state from the existing AWS and Azure infrastructure modules and surfaces a consolidated FinOps view:

- Estimated monthly cost per module (static values you can calibrate from actual bills)
- Aggregated outputs from key modules (VPC/VNet IDs, cluster names, endpoints, etc.)
- High-level tagging compliance notes
- References to budget thresholds configured in the dedicated AWS and Azure FinOps modules

## Usage

1. Ensure your infrastructure modules are already using remote state backends:
   - AWS modules (`terraform/aws/*`) use an S3 backend.
   - Azure modules (`terraform/azure/*`) use an Azurerm backend.

2. Configure this module with the same state locations, for example:

**Important — spoke state key and workspaces:** `terraform/aws/spoke-vpc-eks` uses a Terraform workspace; state is stored at `env/<workspace>/aws/eks/terraform.tfstate` (e.g. `env/dev/aws/eks/terraform.tfstate`). Hub, bastion, and managed-services use fixed keys with no workspace prefix. When calling this report module, set `aws_spoke_state_key` to the workspace-prefixed key if you use workspaces (e.g. `env/dev/aws/eks/terraform.tfstate` for workspace `dev`). Using `aws/eks/terraform.tfstate` without the prefix will fail to find state if spoke was applied with a workspace.

```hcl
module "finops_report" {
  source = "../terraform/finops"

  aws_state_bucket      = "payflow-tfstate-ACCOUNTID"
  aws_state_region      = "us-east-1"
  aws_hub_state_key     = "aws/hub-vpc/terraform.tfstate"
  aws_spoke_state_key   = "env/dev/aws/eks/terraform.tfstate"  # workspace prefix if spoke uses workspaces
  aws_bastion_state_key = "aws/bastion/terraform.tfstate"
  aws_managed_state_key = "aws/managed-services/terraform.tfstate"

  azure_resource_group_name  = "payflow-tfstate-rg"
  azure_storage_account_name = "payflowtfstate"
  azure_container_name       = "tfstate"
  azure_hub_blob_key         = "azure/hub-vnet/terraform.tfstate"
  azure_spoke_blob_key       = "azure/spoke-vnet-aks/terraform.tfstate"
  azure_bastion_blob_key     = "azure/bastion/terraform.tfstate"
  azure_managed_blob_key     = "azure/managed-services/terraform.tfstate"
}
```

3. Run:

```bash
terraform init
terraform apply
```

No resources will be created; the outputs are purely informational.

## Outputs

Key outputs:

- `estimated_monthly_cost_per_module`: static cost estimates per module (USD). Tune these numbers based on your AWS and Azure billing data.
- `*_outputs`: raw outputs from each underlying module, useful for ad‑hoc analysis.
- `tagging_compliance_notes`: summary of how tagging is enforced across AWS and Azure.
- `budget_thresholds`: a reminder of where AWS and Azure budget thresholds are configured.

## Cost Allocation Strategy (Summary)

- **Tagging**: All core modules expose a `local.common_tags` map including:
  - `environment` (`dev`, `staging`, `prod`)
  - `project` (`payflow`)
  - `team` (e.g. `engineering`)
  - `cost-center` (e.g. `ENG-001`)
  - `owner` (person or team)
  - `managed-by` (`terraform`)
  - `module` (e.g. `spoke-vpc-eks`, `hub-vpc`, `managed-services`)
- **AWS**:
  - `terraform/aws/finops` enables tag-based cost allocation via `aws_ce_cost_allocation_tag`.
  - Per-environment budgets (`aws_budgets_budget`) filtered by `environment` tag.
  - Cost Anomaly Detection monitor + subscription using your FinOps email.
  - CloudWatch dashboard for high-level EstimatedCharges visibility.
- **Azure**:
  - `terraform/azure/finops` defines an Azure Policy that audits missing mandatory tags on resource groups.
  - Per-resource-group budgets with notifications wired to an Azure Monitor Action Group.
  - Cost Management export to a storage account so you can query spend by tag.

Use this module as a central, read‑only FinOps surface that complements the enforcing FinOps modules in `terraform/aws/finops` and `terraform/azure/finops`.

