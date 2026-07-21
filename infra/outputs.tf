output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "eks_cluster_name" {
  description = "Nome do cluster EKS"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint da API do cluster EKS"
  value       = module.eks.cluster_endpoint
}

output "eks_update_kubeconfig" {
  description = "Comando para configurar o kubeconfig local"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "rds_endpoints" {
  description = "Mapa serviço -> endpoint RDS (host:porta)"
  value       = module.rds.endpoints
}

output "rds_database_urls" {
  description = "DATABASE_URL pronta (sem senha) para cada serviço — a senha vem de var.db_password"
  value = {
    for name, endpoint in module.rds.endpoints :
    name => "postgres://${var.db_username}:<DB_PASSWORD>@${endpoint}/${name}_db"
  }
}

output "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB do volunteer-service"
  value       = module.dynamodb.table_name
}

output "sqs_queue_url" {
  description = "URL da fila SQS de eventos de doação"
  value       = module.sqs.queue_url
}

output "ecr_repository_urls" {
  description = "Mapa serviço -> URL do repositório ECR"
  value       = module.ecr.repository_urls
}

output "aws_account_id" {
  description = "Account ID atual (útil para montar URIs de imagem ECR nos manifests k8s)"
  value       = data.aws_caller_identity.current.account_id
}

output "velero_bucket_name" {
  description = "Bucket S3 dos backups de DR do Velero"
  value       = module.backup.velero_bucket_name
}
