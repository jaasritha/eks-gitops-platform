output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  value = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

output "node_group_role_arn" {
  value = aws_iam_role.node_group.arn
}

output "cluster_security_group_id" {
  value = aws_security_group.cluster.id
}
