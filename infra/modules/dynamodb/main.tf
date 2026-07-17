resource "aws_dynamodb_table" "volunteers" {
  name         = "SolidaryTechVolunteers"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "volunteer_id"

  attribute {
    name = "volunteer_id"
    type = "S"
  }

  tags = {
    Name        = "${var.project_name}-volunteers"
    Environment = var.environment
    Service     = "volunteer-service"
  }
}
