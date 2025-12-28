variable "domain_name" {
  description = "The domain name for the website"
  type        = string
  default     = "webkwizards.com"
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}
