variable "project_name" {
  type = string
}

variable "account_id" {
  description = "AWS account ID — usado pra tornar o nome do bucket globalmente único"
  type        = string
}

variable "backup_expiration_days" {
  description = "Dias até expirar objetos de backup do Velero no S3 (FinOps)"
  type        = number
  default     = 30
}
