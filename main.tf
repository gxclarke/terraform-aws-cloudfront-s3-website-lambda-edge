provider "aws" {
  region = "us-east-1"
  alias  = "aws_cloudfront"
}

data "aws_acm_certificate" "acm_cert" {
  domain   = "*.${var.hosted_zone}"
  provider = aws.aws_cloudfront

  //CloudFront uses certificates from US-EAST-1 region only

  statuses = [
    "ISSUED",
  ]
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  statement {
    sid = "1"

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::${var.domain_name}/*",
    ]

    principals {
      type = "AWS"

      identifiers = [
        aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn,
      ]
    }
  }
}

resource "aws_s3_bucket" "s3_bucket" {
  bucket = var.domain_name

  tags = var.tags
}

resource "aws_s3_bucket_acl" "s3_bucket" {
  bucket = aws_s3_bucket.s3_bucket.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "s3_bucket" {
  bucket = aws_s3_bucket.s3_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "s3_bucket_policy" {
  bucket = aws_s3_bucket.s3_bucket.id
  policy = data.aws_iam_policy_document.s3_bucket_policy.json
}

data "aws_route53_zone" "domain_name" {
  name         = var.hosted_zone
  private_zone = false
}

resource "aws_route53_record" "route53_record" {
  depends_on = [
    aws_cloudfront_distribution.s3_distribution,
  ]

  zone_id = data.aws_route53_zone.domain_name.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name    = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id = aws_cloudfront_distribution.s3_distribution.hosted_zone_id

    //HardCoded value for CloudFront
    evaluate_target_health = false
  }
}

// Cloudfront Distro with lambda@Edge integration
resource "aws_cloudfront_distribution" "s3_distribution" {
  depends_on = [aws_s3_bucket.s3_bucket]

  origin {
    domain_name = "${var.domain_name}.s3.amazonaws.com"
    origin_id   = "s3-cloudfront"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = [
    var.domain_name,
    "www.${var.domain_name}"
  ]

  default_cache_behavior {
    allowed_methods = [
      "GET",
      "HEAD",
    ]

    cached_methods = [
      "GET",
      "HEAD",
    ]

    lambda_function_association {
      event_type   = "origin-request"
      lambda_arn   = aws_lambda_function.folder_index_redirect.qualified_arn
      include_body = false
    }

    target_origin_id = "s3-cloudfront"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  price_class = "PriceClass_100"

  //Only US,Canada,Europe

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }
  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.acm_cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  custom_error_response {
    error_code            = 400
    response_code         = 400
    error_caching_min_ttl = 10
    response_page_path    = "/4xx.html"
  }
  custom_error_response {
    error_code            = 403
    response_code         = 403
    error_caching_min_ttl = 10
    response_page_path    = "/4xx.html"
  }
  custom_error_response {
    error_code            = 404
    response_code         = 204
    error_caching_min_ttl = 10
    response_page_path    = "/4xx.html"
  }
  tags = var.tags
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "access-identity-${var.domain_name}.s3.amazonaws.com"
}
