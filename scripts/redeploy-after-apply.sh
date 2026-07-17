#!/usr/bin/env bash
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
REPO_ROOT="$(cd "$INFRA_DIR/.." && pwd)"
GITOPS_DIR="${GITOPS_DIR:-$REPO_ROOT/../solidarytech-gitops}"
AWS_REGION="us-east-1"

if [[ ! -d "$GITOPS_DIR" ]]; then
  echo "ERRO: solidarytech-gitops não encontrado em $GITOPS_DIR"
  echo "Defina GITOPS_DIR=/caminho/pro/solidarytech-gitops antes de rodar."
  exit 1
fi

command -v jq >/dev/null || { echo "ERRO: jq não encontrado."; exit 1; }
command -v docker >/dev/null || { echo "ERRO: docker não encontrado."; exit 1; }

echo "==> [1/7] Lendo outputs do Terraform..."
cd "$INFRA_DIR"
ACCOUNT_ID=$(terraform output -raw aws_account_id)
CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
NGO_ENDPOINT=$(terraform output -json rds_endpoints | jq -r '.ngo')
DONATION_ENDPOINT=$(terraform output -json rds_endpoints | jq -r '.donation')
SQS_URL=$(terraform output -raw sqs_queue_url)
DB_PASSWORD=$(grep '^db_password' terraform.tfvars | sed -E 's/db_password[[:space:]]*=[[:space:]]*"(.*)"/\1/')

echo "==> [2/7] Configurando kubeconfig (cluster: $CLUSTER_NAME)..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo "==> [3/7] Aplicando namespace solidarytech e schema SQL nos RDS..."
kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml"
kubectl run psql-init-ngo --rm -i --restart=Never --image=postgres:16-alpine -n solidarytech -- \
  psql "postgres://app:${DB_PASSWORD}@${NGO_ENDPOINT}/ngo_db" < "$REPO_ROOT/ngo-service/db/init.sql"
kubectl run psql-init-donation --rm -i --restart=Never --image=postgres:16-alpine -n solidarytech -- \
  psql "postgres://app:${DB_PASSWORD}@${DONATION_ENDPOINT}/donation_db" < "$REPO_ROOT/donation-service/db/init.sql"

echo "==> [4/7] Build + push das 3 imagens pro ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
for svc in ngo-service donation-service volunteer-service; do
  docker build -t "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/solidarytech/${svc}:latest" "$REPO_ROOT/$svc"
  docker push "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/solidarytech/${svc}:latest"
done

echo "==> [5/7] Gerando base/secrets/.env no gitops e substituindo AWS_ACCOUNT_ID..."
cat > "$GITOPS_DIR/base/secrets/.env" <<EOF
NGO_RDS_ENDPOINT=${NGO_ENDPOINT}
NGO_DB_PASSWORD=${DB_PASSWORD}
DONATION_RDS_ENDPOINT=${DONATION_ENDPOINT}
DONATION_DB_PASSWORD=${DB_PASSWORD}
AWS_SQS_URL=${SQS_URL}
DATADOG_API_KEY=${DATADOG_API_KEY:-placeholder-preencher-depois}
EOF
chmod 600 "$GITOPS_DIR/base/secrets/.env"

if grep -rq "<AWS_ACCOUNT_ID>" "$GITOPS_DIR"/apps/*/deployment*.yaml 2>/dev/null; then
  sed -i "s/<AWS_ACCOUNT_ID>/${ACCOUNT_ID}/" "$GITOPS_DIR"/apps/*/deployment*.yaml
  (cd "$GITOPS_DIR" && git add apps/*/deployment*.yaml && git commit -m "chore: set AWS account id nas imagens ECR" && git push)
else
  echo "    (account id já estava preenchido nos deployments, pulando commit)"
fi

echo "==> [6/7] Rodando bootstrap.sh (ArgoCD + secrets + Applications)..."
kubectl apply -f "$GITOPS_DIR/monitoring/namespace.yaml"
bash "$GITOPS_DIR/bootstrap.sh"

echo "==> [7/7] Aplicando stack de monitoring (Datadog fica com placeholder, configure depois manualmente)..."
kubectl apply -f "$GITOPS_DIR/monitoring/otel-collector.yaml"
kubectl apply -f "$GITOPS_DIR/monitoring/kube-prometheus-stack.yaml"
kubectl apply -f "$GITOPS_DIR/monitoring/loki-stack.yaml"
kubectl apply -f "$GITOPS_DIR/monitoring/dashboards-app.yaml"

echo ""
echo "==> Concluído! Acompanhe com: kubectl get pods -A -w"
echo "==> Se algum DaemonSet (node-exporter/promtail) ficar Pending por 'Too many pods',"
echo "    é o limite de pods/node do t3.medium (ENI/IP, não CPU/memória) — bump eks_node_desired"
echo "    em terraform.tfvars, rode terraform apply de novo, ou libere espaço deletando uma"
echo "    réplica de app no node cheio (ela reagenda sozinha em outro node)."
