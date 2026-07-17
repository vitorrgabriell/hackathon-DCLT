output "table_name" {
  value = aws_dynamodb_table.volunteers.name
}

output "table_arn" {
  value = aws_dynamodb_table.volunteers.arn
}
