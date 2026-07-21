variable "project_name" {
  type = string
}

variable "services" {
  description = "Lista de microsserviços — 1 repositório ECR por serviço"
  type        = list(string)
}
