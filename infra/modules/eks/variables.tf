variable "project_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "lab_role_arn" {
  description = "ARN da LabRole (AWS Academy)"
  type        = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "vpc_id" {
  type = string
}

variable "node_instance_type" {
  type = string
}

variable "node_desired" {
  type = number
}

variable "node_min" {
  type = number
}

variable "node_max" {
  type = number
}
