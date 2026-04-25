resource "aws_s3_bucket" "images" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "images_block" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = true
  block_public_policy     = true
  restrict_public_buckets = true
  ignore_public_acls      = true
}

resource "aws_iam_role" "lambda_role" {
  name = "rendorix-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "lambda_s3_policy" {
  name = "rendorix-lambda-s3-read"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:GetObject"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.images.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "image_processor" {
  function_name = "rendorix-image-processor"

  runtime = "nodejs20.x"
  handler = "index.handler"

  role = aws_iam_role.lambda_role.arn

  filename         = "${path.module}/../lambda/function.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda/function.zip")

  memory_size = 512
  timeout     = 10

  environment {
    variables = {
      BUCKET = aws_s3_bucket.images.id
    }
  }
}

resource "aws_lambda_function_url" "url" {
  function_name      = aws_lambda_function.image_processor.function_name
  authorization_type = "NONE"
}

# ---------------------------------------------------------------------------
# CloudFront Function — viewer-request HMAC validation
# ---------------------------------------------------------------------------

resource "aws_cloudfront_function" "signer" {
  name    = "rendorix-signer"
  runtime = "cloudfront-js-2.0"
  publish = true

  code = templatefile("${path.module}/../cloudfront-function/signer.js.tpl", {
    signing_secret          = var.signing_secret
    signing_secret_previous = var.signing_secret_previous
  })
}

# ---------------------------------------------------------------------------
# CloudFront distribution
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "cdn" {
  enabled = true
  price_class = "PriceClass_100"

  origin {
    domain_name = trimsuffix(replace(aws_lambda_function_url.url.function_url, "https://", ""), "/")
    origin_id   = "lambda-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "lambda-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      # After edge auth strips s+exp, only w/h/f/q reach the cache key
      query_string = true
      cookies {
        forward = "none"
      }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.signer.arn
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}
