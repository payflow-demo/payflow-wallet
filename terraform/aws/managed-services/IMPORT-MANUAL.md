# Manual import for managed-services

Run from: `terraform/aws/managed-services`.

**"Resource already managed by Terraform"** means that resource is **already in state**. Do not run that import again; skip it and run only imports for resources that are **not** in state.

---

## 1. Check what's in state

```bash
terraform state list
```

---

## 2. Already in state (skip these)

If you see these in `terraform state list`, do **not** import them again:

- `aws_cloudwatch_log_group.redis`
- `aws_db_parameter_group.payflow`
- `aws_db_subnet_group.payflow`
- `aws_elasticache_subnet_group.payflow`
- `aws_security_group.elasticache`
- `aws_security_group.mq`
- `aws_security_group.rds`

(Data sources and KMS keys appear in state after apply; no need to import them.)

---

## 3. Run these imports only (not in state yet)

Import the **RDS instance**, **ElastiCache replication group**, and **MQ broker**:

```bash
terraform import aws_db_instance.payflow payflow-postgres
terraform import aws_elasticache_replication_group.payflow payflow-redis
```

MQ broker uses **broker ID** (e.g. `b-xxxx`), not the name. Get it, then import:

```bash
aws mq list-brokers --region us-east-1 --query 'BrokerSummaries[?BrokerName==`payflow-rabbitmq`].BrokerId' --output text
terraform import aws_mq_broker.payflow <broker-id>
```

Then run:

```bash
terraform plan
terraform apply
```

---

## 4. Full import reference (if state is empty)

If you ever need to import **everything** from scratch (e.g. new state file), use these. Skip any resource that already appears in `terraform state list`.

| Resource | Import ID |
|----------|-----------|
| `aws_db_subnet_group.payflow` | `payflow-db-subnet-group` |
| `aws_security_group.rds` | `sg-07f760b2016d3eea1` (or lookup by name in your VPC) |
| `aws_db_parameter_group.payflow` | `payflow-postgres-params-dev` |
| `aws_elasticache_subnet_group.payflow` | `payflow-redis-subnet-group` |
| `aws_security_group.elasticache` | `sg-0844446ee14310cd6` |
| `aws_cloudwatch_log_group.redis` | `/aws/elasticache/redis/payflow` |
| `aws_security_group.mq` | `sg-032f12c523564367e` |
| `aws_db_instance.payflow` | `payflow-postgres` |
| `aws_elasticache_replication_group.payflow` | `payflow-redis` |
| `aws_mq_broker.payflow` | `<broker-id>` from `aws mq list-brokers` |
