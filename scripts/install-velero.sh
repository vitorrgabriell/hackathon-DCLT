#!/usr/bin/env bash
# Instala o Velero no cluster EKS pro DR do estado do k8s (ver docs/dr/pcn.md).
# Reproduzível/idempotente — pode rodar depois de recriar o cluster.
#
# Backend de storage: bucket S3 provisionado pelo Terraform (modules/backup),
# lido via `terraform output`. Autenticação: IAM role do node (LabRole) via
# --no-secret (o hop-limit 2 do IMDS deixa o pod do Velero pegar as credenciais
# do node — sem secret estático no cluster).
#
# Pré-requisitos: kubeconfig apontado pro cluster, credenciais AWS válidas no
# ambiente, velero CLI no PATH (https://github.com/vmware-tanzu/velero/releases).
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
VELERO_PLUGIN_AWS="${VELERO_PLUGIN_AWS:-velero/velero-plugin-for-aws:v1.10.1}"

command -v velero >/dev/null || { echo "ERRO: velero CLI não encontrado no PATH."; exit 1; }

BUCKET="$(cd "$INFRA_DIR" && terraform output -raw velero_bucket_name)"
echo "==> Bucket de backup: $BUCKET"

echo "==> Instalando Velero (provider aws, sem secret / IAM do node)..."
velero install \
  --provider aws \
  --plugins "$VELERO_PLUGIN_AWS" \
  --bucket "$BUCKET" \
  --backup-location-config "region=${AWS_REGION}" \
  --use-volume-snapshots=false \
  --no-secret \
  --wait

echo "==> Validando acesso ao S3 (BackupStorageLocation deve ficar Available)..."
velero backup-location get

echo "==> Criando Schedule de backup da namespace solidarytech (6/6h, TTL 7d)..."
velero schedule create solidarytech-6h \
  --schedule="0 */6 * * *" \
  --include-namespaces solidarytech \
  --ttl 168h0m0s

echo ""
echo "==> Pronto. Backup manual sob demanda:"
echo "    velero backup create solidarytech-manual --include-namespaces solidarytech --wait"
echo "==> Drill de restore (namespace mapeado, não toca no ambiente vivo):"
echo "    velero restore create --from-backup <backup> --namespace-mappings solidarytech:solidarytech-dr --wait"
