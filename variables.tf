variable "enable_budget" {
  type        = bool
  default     = false
  description = "Enable monthly budget alerts and cost anomaly detection"
}

variable "budget_limit" {
  type        = string
  default     = "10"
  description = "Monthly budget limit in USD"
}

variable "budget_alert_email" {
  type        = string
  default     = ""
  description = "Email address for budget and anomaly alert notifications"
}
