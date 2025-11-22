variable "pkp_smtp_user" {
  description = "SMTP username for PKP OJS email configuration"
  type        = string
  sensitive   = true
}

variable "pkp_smtp_pass" {
  description = "SMTP password for PKP OJS email configuration"
  type        = string
  sensitive   = true
}
