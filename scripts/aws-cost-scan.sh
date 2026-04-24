#!/usr/bin/env bash
# Discover common AWS cost sinks across all regions (read-only scan).
set -euo pipefail
REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text | tr '\t' '\n' | sort)

echo "=== Account ==="
aws sts get-caller-identity --output table
echo ""

echo "=== Unassociated Elastic IPs (billable) ==="
for r in $REGIONS; do
  addrs=$(aws ec2 describe-addresses --region "$r" --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output text 2>/dev/null || true)
  if [[ -n "${addrs// }" ]]; then
    echo "-- $r --"
    echo "$addrs"
  fi
done
echo ""

echo "=== Unattached EBS volumes (storage billed while unattached) ==="
for r in $REGIONS; do
  vols=$(aws ec2 describe-volumes --region "$r" --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,VolumeType]' --output text 2>/dev/null || true)
  if [[ -n "${vols// }" ]]; then
    echo "-- $r --"
    echo "$vols"
  fi
done

echo '=== NAT Gateways (~32 USD/mo each, varies by region) ==='
for r in $REGIONS; do
  nats=$(aws ec2 describe-nat-gateways --region "$r" --filter Name=state,Values=available,pending \
    --query 'NatGateways[].[NatGatewayId,SubnetId,State]' --output text 2>/dev/null || true)
  if [[ -n "${nats// }" ]]; then
    echo "-- $r --"
    echo "$nats"
  fi
done

echo "=== Application / Network Load Balancers ==="
for r in $REGIONS; do
  lbs=$(aws elbv2 describe-load-balancers --region "$r" \
    --query 'LoadBalancers[].[LoadBalancerName,LoadBalancerArn,Type,State.Code]' --output text 2>/dev/null || true)
  if [[ -n "${lbs// }" ]]; then
    echo "-- $r --"
    echo "$lbs"
  fi
done

echo "=== Classic ELB ==="
for r in $REGIONS; do
  elb=$(aws elb describe-load-balancers --region "$r" \
    --query 'LoadBalancerDescriptions[].[LoadBalancerName,DNSName]' --output text 2>/dev/null || true)
  if [[ -n "${elb// }" ]]; then
    echo "-- $r --"
    echo "$elb"
  fi
done

echo "=== EC2 instances (all states, summary) ==="
for r in $REGIONS; do
  cnt=$(aws ec2 describe-instances --region "$r" --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
  if [[ "${cnt:-0}" != "0" ]]; then
    echo "-- $r: $cnt instance(s) --"
    aws ec2 describe-instances --region "$r" \
      --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Tags[?Key==`Name`].Value|[0]]' --output table 2>/dev/null || true
  fi
done

echo "=== RDS clusters / instances (summary) ==="
for r in $REGIONS; do
  rds=$(aws rds describe-db-instances --region "$r" --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,Engine,AllocatedStorage]' --output text 2>/dev/null || true)
  if [[ -n "${rds// }" ]]; then
    echo "-- $r --"
    echo "$rds"
  fi
done

echo "=== Elastic IPs total (any association) ==="
for r in $REGIONS; do
  n=$(aws ec2 describe-addresses --region "$r" --query 'length(Addresses)' --output text 2>/dev/null || echo 0)
  if [[ "${n:-0}" != "0" ]]; then
    echo "$r: $n EIP allocation(s)"
  fi
done

echo "=== Done ==="
