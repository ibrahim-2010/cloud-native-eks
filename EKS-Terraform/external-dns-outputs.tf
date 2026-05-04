# ──────────────────────────────────────────────
#  ExternalDNS + Route 53 Outputs
# ──────────────────────────────────────────────

output "route53_zone_id" {
  description = "Route 53 hosted zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "route53_nameservers" {
  description = "Route 53 nameservers — update these at your domain registrar"
  value       = aws_route53_zone.main.name_servers
}

output "external_dns_role_arn" {
  description = "IAM role ARN for ExternalDNS"
  value       = aws_iam_role.external_dns.arn
}

output "domain_name" {
  description = "Domain name"
  value       = var.domain_name
}
