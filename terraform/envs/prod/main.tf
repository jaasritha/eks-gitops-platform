################################################################################
# Prod Environment — Terraform root module
################################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.0" }
    tls        = { source = "hashicorp/tls",         version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "eks-gitops-tfstate-prod"
    key            = "prod/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "eks-gitops-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
    command     = "aws"
  }
}

locals {
  env          = "prod"
  cluster_name = "eks-gitops-${local.env}"

  common_tags = {
    Environment = local.env
    Project     = "eks-gitops-platform"
    Owner       = "platform-team"
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source             = "../../modules/vpc"
  cluster_name       = local.cluster_name
  vpc_cidr           = "10.30.0.0/16"
  single_nat_gateway = false   # HA: one NAT per AZ
  tags               = local.common_tags
}

module "eks" {
  source             = "../../modules/eks"
  cluster_name       = local.cluster_name
  kubernetes_version = "1.30"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids

  node_groups = {
    system = {
      instance_types = ["m5.large"]
      capacity_type  = "ON_DEMAND"
      desired_size   = 3
      min_size       = 3
      max_size       = 6
      labels         = { role = "system" }
      taints         = []
    }
    workloads = {
      instance_types = ["m5.xlarge", "m5a.xlarge"]
      capacity_type  = "ON_DEMAND"
      desired_size   = 3
      min_size       = 3
      max_size       = 20
      labels         = { role = "workload" }
      taints         = []
    }
    spot = {
      instance_types = ["m5.large", "m5a.large", "m4.large"]
      capacity_type  = "SPOT"
      desired_size   = 2
      min_size       = 0
      max_size       = 20
      labels         = { role = "spot" }
      taints = [{
        key    = "spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  log_retention_days = 90
  tags               = local.common_tags
}

module "iam" {
  source            = "../../modules/iam"
  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.common_tags
}

output "cluster_name"              { value = module.eks.cluster_name }
output "cluster_endpoint"          { value = module.eks.cluster_endpoint }
output "alb_controller_role_arn"   { value = module.iam.alb_controller_role_arn }
output "external_dns_role_arn"     { value = module.iam.external_dns_role_arn }
output "cluster_autoscaler_role_arn" { value = module.iam.cluster_autoscaler_role_arn }
