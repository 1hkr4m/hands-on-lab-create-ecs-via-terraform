variable "use_amazon_linux2" {
  default     = false
  description = "Use Amazon Linux 2 instead of Amazon Linux AMI"
}

variable "cluster_name" {
  default     = "my-ecs-cluster"
  description = "Name of the ECS cluster"
}
