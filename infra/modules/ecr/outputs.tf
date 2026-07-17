output "repository_urls" {
  description = "Mapa nome-do-serviço -> URL do repositório ECR"
  value = {
    for service, repo in aws_ecr_repository.services :
    service => repo.repository_url
  }
}
