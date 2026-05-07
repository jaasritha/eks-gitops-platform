variable "cluster_name" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }

variable "irsa_roles" {
  description = "Map of custom IRSA roles to create"
  type = map(object({
    namespace        = string
    service_account  = string
    inline_policy    = optional(string)
    managed_policy_arns = optional(list(string), [])
  }))
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
