#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../infra"

if ! kubectl get namespace solidarytech >/dev/null 2>&1; then
    kubectl apply -f ../k8s/namespace.yaml
fi

: "${TF_VAR_db_password:?defina TF_VAR_db_password com a senha do RDS (mesma do terraform.tfvars)}"

NGO_ENDPOINT=$(terraform output -json rds_endpoints | jq -r '.ngo')
DONATION_ENDPOINT=$(terraform output -json rds_endpoints | jq -r '.donation')
SQS_URL=$(terraform output -raw sqs_queue_url)
ACCOUNT_ID=$(terraform output -raw aws_account_id)

kubectl create secret generic ngo-service-secret -n solidarytech \
    --from-literal=DATABASE_URL="postgres://app:${TF_VAR_db_password}@${NGO_ENDPOINT}/ngo_db" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic donation-service-secret -n solidarytech \
    --from-literal=DATABASE_URL="postgres://app:${TF_VAR_db_password}@${DONATION_ENDPOINT}/donation_db" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap donation-service-config -n solidarytech \
    --from-literal=PORT=8082 \
    --from-literal=AWS_REGION=us-east-1 \
    --from-literal=AWS_SQS_URL="${SQS_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets/ConfigMaps aplicados. Imagens (ECR) na conta ${ACCOUNT_ID}:"
terraform output -json ecr_repository_urls
