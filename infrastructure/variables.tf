variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "ecomm-analytics"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "redshift_admin_username" {
  description = "Admin username for Redshift Serverless"
  type        = string
  default     = "admin"
}

variable "redshift_admin_password" {
  description = "Admin password for Redshift Serverless"
  type        = string
  sensitive   = true
}

variable "your_ip_cidr" {
  description = "Your local IP in CIDR notation for Redshift access (e.g. 102.89.x.x/32)"
  type        = string
}
