################################################################################
# Shared variables — used by dev / staging / prod env roots
################################################################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}
