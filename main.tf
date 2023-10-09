data "aws_ami" "ecs_ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = var.use_amazon_linux2 ? ["amzn2-ami-ecs-hvm-*-x86_64-ebs"] : ["amzn-ami-*-amazon-ecs-optimized"]
  }
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = var.cluster_name
}

