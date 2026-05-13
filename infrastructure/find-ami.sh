#!/bin/bash
# Resolves the latest Amazon Linux 2 (x86_64, gp2) AMI ID for a given region.
# Usage: ./find-ami.sh [region]
# Example: ./find-ami.sh us-east-1

REGION="${1:-$(aws configure get region)}"

AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 \
  --region "${REGION}" \
  --query 'Parameter.Value' \
  --output text)

echo "Region : ${REGION}"
echo "AMI ID : ${AMI_ID}"
echo ""
echo "Use this AMI ID when launching Web Tier and App Tier EC2 instances."
echo "Database Tier uses Amazon Aurora MySQL (RDS) — no AMI needed."
