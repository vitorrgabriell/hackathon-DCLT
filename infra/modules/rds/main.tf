resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.allowed_sg_id]
    description     = "PostgreSQL a partir dos nodes EKS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  count = length(var.db_names)

  identifier     = "${var.project_name}-${var.db_names[count.index]}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"

  db_name  = "${var.db_names[count.index]}_db"
  username = var.username
  password = var.password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # --- DR / continuidade dos dados de doação ---
  # Backups automáticos habilitam Point-In-Time Recovery (PITR): o RDS passa a
  # arquivar os transaction logs continuamente, permitindo restaurar para
  # qualquer segundo dentro da janela de retenção. É isso que dá o RPO de ~5min
  # dos dados de doação (ver docs/dr/pcn.md). Com retention=0 (default anterior)
  # NÃO havia backup nenhum — RPO era infinito.
  backup_retention_period = var.backup_retention_days
  copy_tags_to_snapshot   = true
  # apply_immediately: no lab, aplica a mudança de backup na hora (breve reboot
  # do RDS ao ligar/desligar backups) em vez de esperar a janela de manutenção.
  apply_immediately = true

  skip_final_snapshot = true
  publicly_accessible = false
  multi_az            = false

  tags = {
    Name    = "${var.project_name}-${var.db_names[count.index]}-db"
    Service = "${var.db_names[count.index]}-service"
  }
}
