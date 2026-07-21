variable "aws_region" {
  description = "AWS region (AWS Academy Learner Lab só libera us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome do projeto, usado como prefixo dos recursos"
  type        = string
  default     = "solidarytech"
}

variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones usadas (Learner Lab: us-east-1)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "eks_cluster_version" {
  description = "Versão do Kubernetes no EKS"
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_type" {
  description = "Tipo de instância EC2 dos worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "eks_node_desired" {
  description = "Número desejado de worker nodes"
  type        = number
  default     = 2
}

variable "eks_node_min" {
  description = "Número mínimo de worker nodes"
  type        = number
  default     = 1
}

variable "eks_node_max" {
  description = "Número máximo de worker nodes"
  type        = number
  default     = 4
}

variable "db_instance_class" {
  description = "Classe da instância RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_username" {
  description = "Usuário master das instâncias RDS"
  type        = string
  default     = "app"
}

variable "db_password" {
  description = "Senha master das instâncias RDS"
  type        = string
  sensitive   = true
}

variable "services" {
  description = "Lista de microsserviços — usada para criar 1 repositório ECR por serviço"
  type        = list(string)
  default     = ["ngo", "donation", "volunteer"]
}
