# Bucket S3 externo ao cluster para os backups do Velero (estado do k8s:
# manifestos + eventuais volumes). Fica FORA do EKS de propósito: se o cluster
# for perdido por inteiro, os backups sobrevivem e podem ser restaurados num
# cluster novo. Ver docs/dr/pcn.md e docs/dr/dr-drill-evidence.md.

resource "aws_s3_bucket" "velero" {
  bucket = "${var.project_name}-velero-backups-${var.account_id}"

  tags = {
    Name = "${var.project_name}-velero-backups"
    Role = "dr-backup"
  }
}

# Versionamento: protege contra corrupção/sobrescrita de um backup e permite
# recuperar uma versão anterior de um objeto de backup.
resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FinOps: expira backups antigos automaticamente pra não acumular custo de
# storage. Alinhado com a retenção do Velero (TTL de 7 dias nas Schedules).
resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.backup_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}
