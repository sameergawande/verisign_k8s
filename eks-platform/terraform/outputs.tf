output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "flux_repo_url" {
  value = "https://github.com/${var.github_owner}/${var.flux_repository_name}"
}

output "irsa_roles" {
  value = var.enable_dns ? {
    cert_manager = module.irsa.cert_manager_role_arn
    external_dns = module.irsa.external_dns_role_arn
    } : {
    cert_manager = "DNS disabled — set enable_dns = true with route53_zone_id and domain"
    external_dns = "DNS disabled — set enable_dns = true with route53_zone_id and domain"
  }
}

output "irsa_demo_bucket" {
  description = "S3 bucket name for IRSA lab demo"
  value       = module.irsa.demo_bucket_name
}

output "dns_enabled" {
  value = var.enable_dns
}

output "access_info" {
  value = var.enable_dns ? "Services accessible via ${var.domain}" : join("\n", [
    "DNS disabled — access services via port-forward or ELB hostname:",
    "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring",
    "  kubectl port-forward svc/vault 8200:8200 -n vault",
    "  kubectl port-forward svc/splunk 8000:8000 -n splunk",
    "  kubectl get svc -n envoy-gateway-system  # ELB hostname for Gateway",
  ])
}

output "vault_address" {
  value = "http://vault.vault.svc.cluster.local:8200"
}

output "ebs_kms_key_arn" {
  value = module.eks.ebs_kms_key_arn
}

output "storage_classes" {
  value = module.eks.storage_classes
}

output "student_role_arn" {
  description = "IAM role ARN for student access"
  value       = module.eks.student_role_arn
}

output "student_role_name" {
  description = "IAM role name — students select this when attaching to Cloud9 EC2 instances"
  value       = module.eks.student_role_name
}

output "student_instance_profile" {
  description = "Instance profile name for Cloud9 EC2 instances"
  value       = module.eks.student_instance_profile_name
}
