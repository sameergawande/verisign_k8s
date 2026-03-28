variable "cluster_name" { type = string }
variable "cluster_version" { type = string }
variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "node_instance_type" { type = string }
variable "node_desired" { type = number }
variable "node_min" { type = number }
variable "node_max" { type = number }

variable "student_role_name" {
  description = "IAM role name for Cloud9 student instances"
  type        = string
  default     = "k8s-lab-role"
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "ebs_csi_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}

output "ebs_kms_key_arn" {
  value = aws_kms_key.ebs.arn
}

output "storage_classes" {
  value = {
    default     = "gp3-encrypted (Delete, WaitForFirstConsumer)"
    immediate   = "gp3-encrypted-immediate (Delete, Immediate)"
    retain      = "gp3-encrypted-retain (Retain, WaitForFirstConsumer)"
    performance = "io2-encrypted (Retain, high IOPS)"
  }
}

output "student_role_arn" {
  value = aws_iam_role.student.arn
}

output "student_role_name" {
  value = aws_iam_role.student.name
}

output "student_instance_profile_name" {
  value = aws_iam_instance_profile.student.name
}
