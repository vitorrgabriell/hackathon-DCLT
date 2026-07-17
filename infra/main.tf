module "networking" {
  source = "./modules/networking"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "eks" {
  source = "./modules/eks"

  project_name       = var.project_name
  environment        = var.environment
  cluster_version    = var.eks_cluster_version
  lab_role_arn       = data.aws_iam_role.lab_role.arn
  subnet_ids         = module.networking.private_subnet_ids
  vpc_id             = module.networking.vpc_id
  node_instance_type = var.eks_node_instance_type
  node_desired       = var.eks_node_desired
  node_min           = var.eks_node_min
  node_max           = var.eks_node_max
}

module "rds" {
  source = "./modules/rds"

  project_name   = var.project_name
  environment    = var.environment
  db_names       = ["ngo", "donation"]
  instance_class = var.db_instance_class
  username       = var.db_username
  password       = var.db_password
  subnet_ids     = module.networking.private_subnet_ids
  vpc_id         = module.networking.vpc_id
  allowed_sg_id  = module.eks.cluster_security_group_id
}

module "dynamodb" {
  source = "./modules/dynamodb"

  project_name = var.project_name
  environment  = var.environment
}

module "sqs" {
  source = "./modules/sqs"

  project_name = var.project_name
  environment  = var.environment
}

module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  services     = var.services
}
