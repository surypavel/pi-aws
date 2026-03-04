data "aws_caller_identity" "current" {}

# --- S3 Bucket (private, serves frontend via CloudFront) ---

resource "aws_s3_bucket" "frontend" {
  bucket = "pi-agent-frontend-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- CloudFront Origin Access Control ---

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "pi-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- CloudFront Function: HTTP Basic Auth ---

resource "aws_cloudfront_function" "basic_auth" {
  name    = "pi-basic-auth"
  runtime = "cloudfront-js-2.0"
  publish = true

  # Username is fixed as "pi". Password comes from var.ui_password.
  # The expected header value is pre-computed by Terraform so the secret
  # never appears in CloudWatch logs or Lambda code.
  code = <<-EOF
    function handler(event) {
      var auth = event.request.headers.authorization;
      var expected = "Basic ${base64encode("pi:${var.ui_password}")}";
      if (!auth || auth.value !== expected) {
        return {
          statusCode: 401,
          statusDescription: "Unauthorized",
          headers: { "www-authenticate": { value: 'Basic realm="pi-aws"' } }
        };
      }
      return event.request;
    }
  EOF
}

# --- CloudFront Distribution ---

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # API Gateway origin — hostname only, no path prefix.
  # Stage is "api" so /api/start is routed correctly without URL rewriting.
  origin {
    domain_name = replace(aws_apigatewayv2_api.pi.api_endpoint, "https://", "")
    origin_id   = "APIGWOrigin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # /api/* behaviour — no caching, forwards query string (for ?nextToken),
  # applies the same Basic Auth function so one password covers everything.
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "APIGWOrigin"

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    forwarded_values {
      query_string = true
      cookies { forward = "none" }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.basic_auth.arn
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"

    # No caching — always serve the latest index.html
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.basic_auth.arn
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# --- S3 Bucket Policy (allow CloudFront OAC) ---

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFront"
      Effect = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}

# --- Upload index.html ---

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  source       = "${path.module}/frontend/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/frontend/index.html")
}

# --- Output ---

output "frontend_url" {
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
  description = "URL of the pi-aws frontend"
}
