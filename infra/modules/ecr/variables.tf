variable "project_name" {
  type = string
}

variable "environment" {
  type    = string
  default = "production"
}

variable "services" {
  description = "Lista de microsserviços — 1 repositório ECR por serviço"
  type        = list(string)
}
