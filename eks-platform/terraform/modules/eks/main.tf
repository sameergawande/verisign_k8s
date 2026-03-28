###############################################################################
# EKS Module — VPC + EKS Cluster + Managed Node Group
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ─── VPC ────────────────────────────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true  # cost savings for lab

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ─── EKS ────────────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  eks_managed_node_groups = {
    workers = {
      instance_types = [var.node_instance_type]
      desired_size   = var.node_desired
      min_size       = var.node_min
      max_size       = var.node_max

      labels = {
        role = "worker"
      }
    }
  }

  enable_cluster_creator_admin_permissions = false

  access_entries = {
    # Grant the Terraform executor cluster-admin so it can create
    # StorageClasses, Kubernetes resources, and bootstrap Flux/Vault.
    terraform_executor = {
      principal_arn = data.aws_caller_identity.current.arn
      type          = "STANDARD"

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    # Student role — attached to Cloud9 EC2 instances via instance profile.
    student = {
      principal_arn     = aws_iam_role.student.arn
      kubernetes_groups = ["students"]
      type              = "STANDARD"

      policy_associations = {
        student = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}

# ─── EBS CSI Driver IRSA ───────────────────────────────────────────────────

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Allow the CSI driver to use the KMS key for encrypted volumes
resource "aws_iam_role_policy" "ebs_csi_kms" {
  name = "ebs-csi-kms"
  role = aws_iam_role.ebs_csi.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ListGrants"
        ]
        Resource = aws_kms_key.ebs.arn
      }
    ]
  })
}

# ─── KMS Key for EBS Encryption ────────────────────────────────────────────

resource "aws_kms_key" "ebs" {
  description             = "KMS key for EBS volume encryption - ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name        = "${var.cluster_name}-ebs"
    Environment = "lab"
  }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.cluster_name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

# ─── StorageClasses ─────────────────────────────────────────────────────────
# gp3-encrypted:           Default, WaitForFirstConsumer, Delete
# gp3-encrypted-immediate: Immediate binding, Delete (pre-provision before pod scheduling)
# gp3-encrypted-retain:    WaitForFirstConsumer, Retain (databases, stateful apps)
# io2-encrypted:           WaitForFirstConsumer, Retain, high IOPS

resource "kubernetes_storage_class" "gp3_encrypted_immediate" {
  depends_on = [module.eks]

  metadata {
    name = "gp3-encrypted-immediate"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = aws_kms_key.ebs.arn
    fsType    = "ext4"
  }
}

resource "kubernetes_storage_class" "gp3_encrypted" {
  depends_on = [module.eks]

  metadata {
    name = "gp3-encrypted"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = aws_kms_key.ebs.arn
    fsType    = "ext4"
  }
}

resource "kubernetes_storage_class" "gp3_encrypted_retain" {
  depends_on = [module.eks]

  metadata {
    name = "gp3-encrypted-retain"
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = aws_kms_key.ebs.arn
    fsType    = "ext4"
  }
}

resource "kubernetes_storage_class" "io2_encrypted" {
  depends_on = [module.eks]

  metadata {
    name = "io2-encrypted"
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "io2"
    iopsPerGB = "50"
    encrypted = "true"
    kmsKeyId  = aws_kms_key.ebs.arn
    fsType    = "ext4"
  }
}

# Remove the default annotation from the built-in gp2 StorageClass
# so gp3-encrypted becomes the cluster default
resource "kubernetes_annotations" "remove_gp2_default" {
  depends_on = [module.eks]

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  force = true
}

# ============================================================
# Student Access Configuration
# Cloud9 instances assume this role via EC2 instance profile.
# AdministratorAccess simplifies lab exercises — scope down for
# production training environments.
# ============================================================

resource "aws_iam_role" "student" {
  name = var.student_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Purpose = "Cloud9 student access for EKS training"
  }
}

resource "aws_iam_instance_profile" "student" {
  name = var.student_role_name
  role = aws_iam_role.student.name
}

resource "aws_iam_role_policy_attachment" "student_admin" {
  role       = aws_iam_role.student.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
