resource "aws_sqs_queue" "donations" {
  name = "solidary-donations"

  tags = {
    Name    = "${var.project_name}-donations"
    Service = "donation-service"
  }
}
