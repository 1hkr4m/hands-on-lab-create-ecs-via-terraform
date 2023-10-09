################################################################
# VPC
################################################################
resource "aws_vpc" "ecs_vpc" {
  cidr_block = var.vpc_cidr_block
  tags       = var.tags
}

resource "aws_subnet" "ecs_subnet_a" {
  vpc_id            = aws_vpc.ecs_vpc.id
  cidr_block        = var.subnet_a_cidr_block
  availability_zone = var.availability_zone
  tags              = var.tags
}

resource "aws_subnet" "ecs_subnet_b" {
  vpc_id            = aws_vpc.ecs_vpc.id
  cidr_block        = var.subnet_b_cidr_block
  availability_zone = var.availability_zone
  tags              = var.tags
}
################################################################
# ECS cluster
################################################################

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

# Create ECS IAM Instance Role and Policy
resource "random_id" "code" {
  byte_length = 4
}

resource "aws_iam_role" "ecsInstanceRole" {
  name               = "ecsInstanceRole-${random_id.code.hex}"
  assume_role_policy = var.ecsInstanceRoleAssumeRolePolicy
}

resource "aws_iam_role_policy" "ecsInstanceRolePolicy" {
  name   = "ecsInstanceRolePolicy-${random_id.code.hex}"
  role   = aws_iam_role.ecsInstanceRole.id
  policy = var.ecsInstanceRolePolicy
}

# Create ECS IAM Service Role and Policy
resource "aws_iam_role" "ecsServiceRole" {
  name               = "ecsServiceRole-${random_id.code.hex}"
  assume_role_policy = var.ecsServiceRoleAssumeRolePolicy
}

resource "aws_iam_role_policy" "ecsServiceRolePolicy" {
  name   = "ecsServiceRolePolicy-${random_id.code.hex}"
  role   = aws_iam_role.ecsServiceRole.id
  policy = var.ecsServiceRolePolicy
}

resource "aws_iam_instance_profile" "ecsInstanceProfile" {
  name = "ecsInstanceProfile-${random_id.code.hex}"
  role = aws_iam_role.ecsInstanceRole.name
}
################################################################
# ASG
################################################################

# Generate user_data from template file
locals {
  user_data = templatefile("${path.module}/default-user-data.sh", {
    ecs_cluster_name = var.cluster_name
  })
}

# Create Launch Template
resource "aws_launch_template" "lt" {
  ebs_optimized          = false
  name                   = "lt-${var.cluster_name}"
  image_id               = data.aws_ami.ecs_ami.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.asg.id]
  user_data              = base64encode(var.user_data != "false" ? var.user_data : local.user_data)

  iam_instance_profile {
    name = aws_iam_instance_profile.ecsInstanceProfile.id
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = var.tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = var.tags
  }
}
# Create Secutiy Group for ASG
resource "aws_security_group" "asg" {
  name        = "${var.cluster_name}-asg"
  description = "Security group for ECS cluster ASG"
  vpc_id      = aws_vpc.ecs_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create Auto-Scaling Group
resource "aws_autoscaling_group" "asg" {
  name                      = var.cluster_name
  vpc_zone_identifier       = [aws_subnet.ecs_subnet_a.id, aws_subnet.ecs_subnet_b.id]
  min_size                  = var.min_size
  max_size                  = var.max_size
  health_check_type         = var.health_check_type
  health_check_grace_period = var.health_check_grace_period
  default_cooldown          = var.default_cooldown
  termination_policies      = var.termination_policies

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  tag {
    key                 = "ecs_cluster"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  protect_from_scale_in = var.protect_from_scale_in

  lifecycle {
    create_before_destroy = true
  }
}

# Create autoscaling policies
resource "aws_autoscaling_policy" "up" {
  name                   = "${var.cluster_name}-scaleUp"
  scaling_adjustment     = var.scaling_adjustment_up
  adjustment_type        = var.adjustment_type
  cooldown               = var.policy_cooldown
  policy_type            = "SimpleScaling"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  count                  = var.alarm_actions_enabled ? 1 : 0
}

resource "aws_autoscaling_policy" "down" {
  name                   = "${var.cluster_name}-scaleDown"
  scaling_adjustment     = var.scaling_adjustment_down
  adjustment_type        = var.adjustment_type
  cooldown               = var.policy_cooldown
  policy_type            = "SimpleScaling"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  count                  = var.alarm_actions_enabled ? 1 : 0
}

/*
 * Create CloudWatch alarms to trigger scaling of ASG
 */
resource "aws_cloudwatch_metric_alarm" "scaleUp" {
  alarm_name          = "${var.cluster_name}-scaleUp"
  alarm_description   = "ECS cluster scaling metric above threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = var.scaling_metric_name
  namespace           = "AWS/ECS"
  statistic           = "Average"
  period              = var.alarm_period
  threshold           = var.alarm_threshold_up
  actions_enabled     = var.alarm_actions_enabled
  count               = var.alarm_actions_enabled ? 1 : 0
  alarm_actions       = [aws_autoscaling_policy.up[0].arn]

  dimensions = {
    ClusterName = var.cluster_name
  }
}

resource "aws_cloudwatch_metric_alarm" "scaleDown" {
  alarm_name          = "${var.cluster_name}-scaleDown"
  alarm_description   = "ECS cluster scaling metric under threshold"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = var.scaling_metric_name
  namespace           = "AWS/ECS"
  statistic           = "Average"
  period              = var.alarm_period
  threshold           = var.alarm_threshold_down
  actions_enabled     = var.alarm_actions_enabled
  count               = var.alarm_actions_enabled ? 1 : 0
  alarm_actions       = [aws_autoscaling_policy.down[0].arn]

  dimensions = {
    ClusterName = var.cluster_name
  }
}

################################################################
# ECS Service
################################################################
resource "aws_ecs_task_definition" "mytask" {
  family = "${var.cluster_name}-task"
  container_definitions = jsonencode([{
    name  = "nginx-container"
    image = "nginx:latest"
    portMappings = [{
      containerPort = 80
      hostPort      = 80
    }]
  }])
  requires_compatibilities = ["EC2"]
  cpu                      = "256"
  memory                   = "512"
}

resource "aws_ecs_service" "ecs_service" {
  name            = "${var.cluster_name}-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.mytask.arn
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.ecs_subnet_a.id, aws_subnet.ecs_subnet_b.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ecs.arn
    container_name   = "nginx-container"
    container_port   = 80
  }
}

resource "aws_lb_target_group" "ecs" {
  name     = "${var.cluster_name}-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.ecs_vpc.id
}

resource "aws_security_group" "ecs_sg" {
  name_prefix = "ecs-sg"
  vpc_id      = aws_vpc.ecs_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "ecs_lb" {
  name               = "${var.cluster_name}-lb"
  internal           = false
  load_balancer_type = "application"

  subnets = [aws_subnet.ecs_subnet_a.id, aws_subnet.ecs_subnet_b.id]

  security_groups = [aws_security_group.ecs_sg.id]

  tags = {
    Name = "${var.cluster_name}-lb"
  }
}
