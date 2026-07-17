data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

data "aws_caller_identity" "current" {}
