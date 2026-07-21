variable "project_name" {
  type = string
}

variable "db_names" {
  description = "Lista de nomes de serviço (ngo, donation) — vira db_name '<nome>_db'"
  type        = list(string)
}

variable "instance_class" {
  type = string
}

variable "username" {
  type = string
}

variable "password" {
  type      = string
  sensitive = true
}

variable "subnet_ids" {
  type = list(string)
}

variable "vpc_id" {
  type = string
}

variable "allowed_sg_id" {
  description = "Security Group ID autorizado a acessar o RDS (SG do cluster EKS)"
  type        = string
}
