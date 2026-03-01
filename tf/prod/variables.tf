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

variable "email_relay_test_sender" {
  description = "Sender address for the email relay integration test"
  type        = string
  default     = null
}

variable "email_relay_test_recipient" {
  description = "Recipient address for the email relay integration test"
  type        = string
  default     = null
}
