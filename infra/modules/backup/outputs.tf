output "velero_bucket_name" {
  description = "Nome do bucket S3 usado pelo Velero pros backups de DR"
  value       = aws_s3_bucket.velero.id
}
