data "archive_file" "lambda_file" {
  count       = var.source_file != "" ? 1 : 0
  type        = "zip"
  source_file = "${var.source_dir}/${var.source_file}"
  output_path = "/tmp/${var.name}.zip"
}

data "archive_file" "lambda_dir" {
  count       = var.source_file == "" ? 1 : 0
  type        = "zip"
  source_dir  = var.source_dir
  excludes    = var.excludes
  output_path = "/tmp/${var.name}.zip"
}

resource "aws_s3_object" "lambda" {
  count                  = var.s3_bucket == "" ? 0 : 1
  bucket                 = var.s3_bucket
  key                    = "unsigned/${var.name}-${var.source_file != "" ? data.archive_file.lambda_file[0].output_md5 : data.archive_file.lambda_dir[0].output_md5}.zip"
  source                 = var.source_file != "" ? data.archive_file.lambda_file[0].output_path : data.archive_file.lambda_dir[0].output_path
  server_side_encryption = "AES256"
  depends_on             = [
    data.archive_file.lambda_file, data.archive_file.lambda_dir
  ]
}

resource "aws_signer_signing_job" "lambda" {
  profile_name = var.signer_profile_name

  source {
    s3 {
      bucket  = var.s3_bucket
      key     = aws_s3_object.lambda[0].id
      version = "null"
    }
  }

  destination {
    s3 {
      bucket = var.s3_bucket
      prefix = "signed/${var.name}-"
    }
  }

  ignore_signing_job_failure = false
  depends_on                 = [
    aws_s3_object.lambda
  ]
}

resource "aws_lambda_function" "lambda" {
  depends_on = [
    aws_signer_signing_job.lambda
  ]
  function_name                  = var.name
  description                    = local.description
  s3_bucket                      = var.s3_bucket
  s3_key                         = aws_signer_signing_job.lambda.signed_object[0]["s3"][0]["key"]
  role                           = aws_iam_role.lambda.arn
  handler                        = var.handler
  layers                         = var.layers
  runtime                        = var.runtime
  architectures                  = [lower(var.architecture)]
  memory_size                    = var.memory
  reserved_concurrent_executions = var.reserved_concurrency
  timeout                        = var.timeout
  publish                        = true

  code_signing_config_arn = var.code_signing_config_arn

  dynamic "dead_letter_config" {
    for_each = var.edge ? [] : [
      1
    ]
    content {
      target_arn = var.dead_letter_arn
    }
  }

  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = var.security_group_ids
  }

  dynamic "environment" {
    for_each = var.edge ? [] : [
      1
    ]
    content {
      variables = local.env
    }
  }

  lifecycle {
    ignore_changes = [
      code_signing_config_arn
    ]
  }
}


//resource "aws_lambda_alias" "lambda" {
//  name             = "latest"
//  description      = "points to the latest version"
//  function_name    = aws_lambda_function.lambda.function_name
//  function_version = aws_lambda_function.lambda.version
//}

//resource "aws_lambda_provisioned_concurrency_config" "lambda" {
//  count                             = (var.provisioned_concurrecy == 0) ? 0 : 1
//  function_name                     = aws_lambda_function.lambda.function_name
//  provisioned_concurrent_executions = var.provisioned_concurrecy
//  qualifier                         = aws_lambda_alias.lambda.name
//}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.edge ? "us-east-1." : ""}${var.name}"
  retention_in_days = var.retention_in_days == 0 ? (terraform.workspace == "production" ? 365 : 7) : var.retention_in_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda-role"
  assume_role_policy = var.edge ? data.aws_iam_policy_document.edge-lambda.json : data.aws_iam_policy_document.lambda.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = [
        "lambda.amazonaws.com"
      ]
    }

  }
}

data "aws_iam_policy_document" "edge-lambda" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = [
        "lambda.amazonaws.com",
        "edgelambda.amazonaws.com",
      ]
    }

  }
}

/*
condition {
  test     = "StringEquals"
  values   = [local.account_id]
  variable = "AWS:SourceAccount"
}
*/

# Adds CloudWatch
resource "aws_iam_role_policy_attachment" "cloud-watch" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Add X-Ray
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

# Add NetworkInterface
resource "aws_iam_role_policy_attachment" "vpc" {
  count      = length(var.private_subnet_ids) == 0 ? 0 : 1
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaENIManagementAccess"
}
