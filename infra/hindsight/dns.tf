# ACM certificate for the Hindsight domain (public_endpoint only)
resource "aws_acm_certificate" "hindsight" {
  count                     = var.public_endpoint ? 1 : 0
  domain_name               = var.hindsight_domain
  subject_alternative_names = ["cp.${var.hindsight_domain}"]
  validation_method         = "DNS"

  tags = merge(local.tags, {
    Name = "${var.project_name}-cert"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Route 53 hosted zone data source
data "aws_route53_zone" "main" {
  count   = var.public_endpoint ? 1 : 0
  zone_id = var.hosted_zone_id
}

# DNS validation records for ACM
resource "aws_route53_record" "cert_validation" {
  for_each = var.public_endpoint ? {
    for dvo in aws_acm_certificate.hindsight[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main[0].zone_id
}

# Wait for certificate validation
resource "aws_acm_certificate_validation" "hindsight" {
  count                   = var.public_endpoint ? 1 : 0
  certificate_arn         = aws_acm_certificate.hindsight[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# A record pointing the domain to the ALB
resource "aws_route53_record" "hindsight" {
  count   = var.public_endpoint ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.hindsight_domain
  type    = "A"

  alias {
    name                   = data.kubernetes_ingress_v1.hindsight.status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_lb.hindsight[0].zone_id
    evaluate_target_health = true
  }
}

# A record for Control Plane subdomain -> same ALB
resource "aws_route53_record" "control_plane" {
  count   = var.public_endpoint ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "cp.${var.hindsight_domain}"
  type    = "A"

  alias {
    name                   = data.kubernetes_ingress_v1.hindsight.status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_lb.hindsight[0].zone_id
    evaluate_target_health = true
  }
}

# Look up the ALB to get the zone_id for the alias record
# The AWS Load Balancer Controller tags ALBs with these tags
data "aws_lb" "hindsight" {
  count = var.public_endpoint ? 1 : 0
  tags = {
    "elbv2.k8s.aws/cluster"    = module.eks.cluster_name
    "ingress.k8s.aws/resource" = "LoadBalancer"
    "ingress.k8s.aws/stack"    = "hindsight"
  }

  depends_on = [helm_release.hindsight]
}
