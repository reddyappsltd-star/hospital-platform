terraform {
  backend "s3" {
    bucket       = "hospital-tfstate-566188427204"
    key          = "hospital-platform/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

# Looks up your account number, used to make the bucket name unique
data "aws_caller_identity" "current" {}

# The storage bucket for the hospital reporting data
resource "aws_s3_bucket" "data" {
  bucket = "hospital-reporting-${data.aws_caller_identity.current.account_id}"
}

# Block every form of public access
resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt everything stored in the bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
# Upload the sample appointments data
resource "aws_s3_object" "appointments" {
  bucket = aws_s3_bucket.data.id
  key    = "appointments/appointments.csv"
  source = "data/appointments.csv"
  etag   = filemd5("data/appointments.csv")
}
# A catalog database to hold table definitions
resource "aws_glue_catalog_database" "reporting" {
  name = "hospital_reporting"
}

# Describes the CSV file as a table with columns
resource "aws_glue_catalog_table" "appointments" {
  name          = "appointments"
  database_name = aws_glue_catalog_database.reporting.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification           = "csv"
    "skip.header.line.count" = "1"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data.bucket}/appointments/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      parameters = {
        "field.delim" = ","
      }
    }

    columns {
      name = "appointment_id"
      type = "int"
    }
    columns {
      name = "appointment_date"
      type = "date"
    }
    columns {
      name = "department"
      type = "string"
    }
    columns {
      name = "clinic_site"
      type = "string"
    }
    columns {
      name = "wait_days"
      type = "int"
    }
    columns {
      name = "attended"
      type = "string"
    }
  }
}

# A separate private bucket where Athena saves query results
resource "aws_s3_bucket" "athena_results" {
  bucket        = "hospital-athena-results-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# A workgroup: the "room" analysts run their queries in
resource "aws_athena_workgroup" "analysts" {
  name          = "hospital-analysts"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
    }
  }
}
# The analyst role: who is allowed to "wear the badge"
resource "aws_iam_role" "analyst" {
  name = "hospital-analyst"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
    }]
  })
}

# What the badge allows: read data, run queries, nothing else
resource "aws_iam_role_policy" "analyst" {
  name = "analyst-read-only"
  role = aws_iam_role.analyst.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunQueriesInAnalystWorkgroup"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup"
        ]
        Resource = aws_athena_workgroup.analysts.arn
      },
      {
        Sid    = "ReadTableDefinitions"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions"
        ]
        Resource = [
          "arn:aws:glue:eu-west-2:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:eu-west-2:${data.aws_caller_identity.current.account_id}:database/hospital_reporting",
          "arn:aws:glue:eu-west-2:${data.aws_caller_identity.current.account_id}:table/hospital_reporting/*"
        ]
      },
      {
        Sid      = "ReadTheData"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
      },
      {
        Sid      = "SaveAndReadQueryResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.athena_results.arn}/*"
      },
      {
        Sid      = "FindTheBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.data.arn, aws_s3_bucket.athena_results.arn]
      }
    ]
  })
}
# Look up the GitHub trust provider that already exists in this account
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# The role the pipeline wears. Only this one repository may use it.
resource "aws_iam_role" "pipeline" {
  name = "hospital-pipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
           Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:reddyappsltd-star/hospital-platform:ref:refs/heads/main",
            "repo:reddyappsltd-star/hospital-platform:pull_request"
          ]
        }
      }
    }]
  })
}

# What the pipeline may do once it has the role
resource "aws_iam_role_policy_attachment" "pipeline_admin" {
  role       = aws_iam_role.pipeline.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}