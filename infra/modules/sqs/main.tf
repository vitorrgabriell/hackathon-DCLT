resource "aws_sqs_queue" "donations" {
  name = "solidary-donations"

  tags = {
    Name        = "${var.project_name}-donations"
    Environment = var.environment
    Service     = "donation-service"
  }
}
